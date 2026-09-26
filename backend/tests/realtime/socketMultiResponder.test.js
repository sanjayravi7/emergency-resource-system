// Load backend/.env first so a locally configured PostgreSQL test database is
// detected (same pattern as the socket integration suite).
require('dotenv').config();

const bcrypt = require('bcrypt');
const http = require('http');
const request = require('supertest');
const { io: ioClient } = require('socket.io-client');

const hasDatabase = Boolean(process.env.DATABASE_URL && process.env.JWT_SECRET);

// PHASE E - real multi-client Socket.IO integration tests for multi-responder
// dispatch. Every test uses genuine socket.io-client connections against a
// real PostgreSQL database; nothing is mocked.
//
// Covers the 20 required Phase E cases:
//  (1)  first responder assignment notification
//  (2)  second responder assignment notification
//  (3)  requester receives multi-responder assignment update
//  (4)  admin receives assignment update
//  (5)  assigned responder can join the request room
//  (6)  allocation-only responder can join the request room
//  (7)  unrelated responder denied
//  (8)  acceptedById fallback works only for legacy/no-assignment rows
//  (9)  request.updated reaches all active assigned responders
//  (10) request.updated does not leak to unrelated responders
//  (11) allocation.updated reaches the allocation owner
//  (12) location update authorized by ACTIVE assignment
//  (13) location update denied to unrelated responder
//  (14) multiple responders can publish locations independently
//  (15) requester receives all responder location updates
//  (16) terminal stop is emitted per responder
//  (17) redacted responders-room joinability handles accepted requests with
//       outstanding work
//  (18) completed request is no longer joinable
//  (19) cancelled request is no longer joinable
//  (20) reconnect restores correct request-room access
(hasDatabase ? describe : describe.skip)(
  'Multi-responder Socket.IO integration (Phase E)',
  () => {
    process.env.SOCKET_LOCATION_MAX_UPDATES_PER_WINDOW =
      process.env.SOCKET_LOCATION_MAX_UPDATES_PER_WINDOW || '2';
    process.env.SOCKET_LOCATION_RATE_WINDOW_MS =
      process.env.SOCKET_LOCATION_RATE_WINDOW_MS || '1000';
    process.env.SOCKET_LOCATION_PERSIST_INTERVAL_MS =
      process.env.SOCKET_LOCATION_PERSIST_INTERVAL_MS || '2000';

    const app = require('../../src/app');
    const prisma = require('../../src/config/prisma');
    const { createSocketServer } = require('../../src/realtime/socketServer');
    const { closeSocketServer } = require('../../src/realtime/socketEvents');

    const password = 'PhaseESocket123!';
    const runId = `phasee-${Date.now()}`;

    let httpServer;
    let serverUrl;
    let users;
    let tokens;
    let resources;
    let capabilities;
    let sockets;

    function wait(ms) {
      return new Promise((resolve) => setTimeout(resolve, ms));
    }

    function waitForEvent(socket, eventName, predicate = () => true, timeoutMs = 2000) {
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          socket.off(eventName, handler);
          reject(new Error(`Timed out waiting for ${eventName}`));
        }, timeoutMs);

        function handler(payload) {
          try {
            if (!predicate(payload || {})) return;
            clearTimeout(timer);
            socket.off(eventName, handler);
            resolve(payload || {});
          } catch (error) {
            clearTimeout(timer);
            socket.off(eventName, handler);
            reject(error);
          }
        }

        socket.on(eventName, handler);
      });
    }

    function expectNoEvent(socket, eventName, predicate = () => true, durationMs = 350) {
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          socket.off(eventName, handler);
          resolve();
        }, durationMs);

        function handler(payload) {
          if (!predicate(payload || {})) return;
          clearTimeout(timer);
          socket.off(eventName, handler);
          reject(new Error(`Unexpected ${eventName}`));
        }

        socket.on(eventName, handler);
      });
    }

    function emitAck(socket, eventName, payload, timeoutMs = 1000) {
      return new Promise((resolve, reject) => {
        socket.timeout(timeoutMs).emit(eventName, payload, (error, response) => {
          if (error) return reject(error);
          return resolve(response);
        });
      });
    }

    async function connectSocket(token) {
      const socket = ioClient(serverUrl, {
        auth: { token },
        transports: ['websocket'],
        reconnection: false,
        forceNew: true,
        autoConnect: false,
      });

      const authenticated = waitForEvent(socket, 'socket.authenticated');
      socket.connect();
      await authenticated;
      return socket;
    }

    function disconnectAllSockets() {
      if (!sockets) return;
      for (const socket of Object.values(sockets)) {
        socket.removeAllListeners();
        socket.disconnect();
      }
      sockets = null;
    }

    // ------------------------------------------------------------------
    // REST helpers (the HTTP API remains the only persistence path)
    // ------------------------------------------------------------------
    async function createEmergency(lines, requesterToken = tokens.requesterX) {
      const response = await request(app)
        .post('/api/requests')
        .set('Authorization', `Bearer ${requesterToken}`)
        .send({
          emergencyType: 'Multi',
          description: 'Phase E multi-responder socket emergency',
          location: 'Thrissur, Kerala',
          latitude: 10.5276,
          longitude: 76.2144,
          priority: 'HIGH',
          requiredResources: lines,
        });
      expect(response.statusCode).toBe(201);
      return response.body.request;
    }

    async function accept(token, requestId) {
      const response = await request(app)
        .patch(`/api/requests/${requestId}/accept`)
        .set('Authorization', `Bearer ${token}`);
      expect(response.statusCode).toBe(200);
      return response.body.request;
    }

    async function allocate(token, body) {
      return request(app)
        .post('/api/allocations')
        .set('Authorization', `Bearer ${token}`)
        .send(body);
    }

    async function patchAllocation(token, allocationId, status) {
      const response = await request(app)
        .patch(`/api/allocations/${allocationId}/status`)
        .set('Authorization', `Bearer ${token}`)
        .send({ status });
      expect(response.statusCode).toBe(200);
      return response.body.allocation;
    }

    async function confirmReceived(token, allocationId) {
      const response = await request(app)
        .patch(`/api/allocations/${allocationId}/received`)
        .set('Authorization', `Bearer ${token}`);
      expect(response.statusCode).toBe(200);
      return response.body.allocation;
    }

    async function cancelRequest(token, requestId) {
      const response = await request(app)
        .patch(`/api/requests/${requestId}/cancel`)
        .set('Authorization', `Bearer ${token}`);
      expect(response.statusCode).toBe(200);
      return response.body.request;
    }

    // A full multi-line emergency: ambulance (SERVICE, responder A), fire
    // engine (SERVICE, responder B), blood (CONSUMABLE, responder D).
    function allLines() {
      return [
        { resourceId: resources.ambulance.id, quantity: 1 },
        { resourceId: resources.fireEngine.id, quantity: 1 },
        { resourceId: resources.blood.id, quantity: 1 },
      ];
    }

    beforeAll(async () => {
      const hashedPassword = await bcrypt.hash(password, 10);
      const emails = {
        requesterX: `${runId}-requester-x@test.com`,
        requesterY: `${runId}-requester-y@test.com`,
        responderA: `${runId}-responder-a@test.com`,
        responderB: `${runId}-responder-b@test.com`,
        responderD: `${runId}-responder-d@test.com`,
        unrelated: `${runId}-unrelated@test.com`,
        admin: `${runId}-admin@test.com`,
      };

      users = {};
      for (const [key, email] of Object.entries(emails)) {
        users[key] = await prisma.user.create({
          data: {
            name: `Phase E ${key}`,
            email,
            password: hashedPassword,
            role: key === 'requesterX' || key === 'requesterY' ? 'REQUESTER' : key === 'admin' ? 'ADMIN' : 'RESPONDER',
            isActive: true,
            responderStatus: key.startsWith('responder') || key === 'unrelated' ? 'AVAILABLE' : 'OFFLINE',
            location: 'Thrissur, Kerala',
          },
        });
      }

      resources = {
        ambulance: await prisma.resource.create({
          data: { name: `${runId} Ambulance`, type: 'AMBULANCE', mode: 'SERVICE', totalQuantity: 0, availableQuantity: 0, isActive: true },
        }),
        fireEngine: await prisma.resource.create({
          data: { name: `${runId} Fire Engine`, type: 'FIRE', mode: 'SERVICE', totalQuantity: 0, availableQuantity: 0, isActive: true },
        }),
        blood: await prisma.resource.create({
          data: { name: `${runId} Blood`, type: 'Medical', mode: 'CONSUMABLE', totalQuantity: 50, availableQuantity: 50, unit: 'unit', isActive: true },
        }),
        helicopter: await prisma.resource.create({
          data: { name: `${runId} Helicopter`, type: 'AIR', mode: 'SERVICE', totalQuantity: 0, availableQuantity: 0, isActive: true },
        }),
      };

      capabilities = {
        responderAAmbulance: await prisma.responderResource.create({
          data: { responderId: users.responderA.id, resourceId: resources.ambulance.id, totalQuantity: 0, availableQuantity: 0, isEnabled: true, status: 'UNAVAILABLE' },
        }),
        responderBFire: await prisma.responderResource.create({
          data: { responderId: users.responderB.id, resourceId: resources.fireEngine.id, totalQuantity: 0, availableQuantity: 0, isEnabled: true, status: 'UNAVAILABLE' },
        }),
        responderDBlood: await prisma.responderResource.create({
          data: { responderId: users.responderD.id, resourceId: resources.blood.id, totalQuantity: 5, availableQuantity: 5, isEnabled: true, status: 'AVAILABLE' },
        }),
        unrelatedHelicopter: await prisma.responderResource.create({
          data: { responderId: users.unrelated.id, resourceId: resources.helicopter.id, totalQuantity: 0, availableQuantity: 0, isEnabled: true, status: 'UNAVAILABLE' },
        }),
      };

      tokens = {};
      for (const [key, email] of Object.entries(emails)) {
        const response = await request(app)
          .post('/api/auth/login')
          .send({ email, password });
        expect(response.statusCode).toBe(200);
        tokens[key] = response.body.data.token;
      }

      httpServer = http.createServer(app);
      createSocketServer(httpServer);
      await new Promise((resolve) => {
        httpServer.listen(0, '127.0.0.1', () => {
          const { port } = httpServer.address();
          serverUrl = `http://127.0.0.1:${port}`;
          resolve();
        });
      });
    }, 30000);

    beforeEach(async () => {
      disconnectAllSockets();
      await prisma.allocation.deleteMany({
        where: {
          OR: [
            { responderId: { in: [users.responderA.id, users.responderB.id, users.responderD.id, users.unrelated.id] } },
            { request: { requesterId: { in: [users.requesterX.id, users.requesterY.id] } } },
          ],
        },
      });
      await prisma.emergencyRequest.deleteMany({
        where: { requesterId: { in: [users.requesterX.id, users.requesterY.id] } },
      });
      await prisma.user.updateMany({
        where: { id: { in: [users.responderA.id, users.responderB.id, users.responderD.id, users.unrelated.id] } },
        data: { responderStatus: 'AVAILABLE', isActive: true, latitude: null, longitude: null },
      });
      await prisma.responderResource.update({
        where: { id: capabilities.responderDBlood.id },
        data: { availableQuantity: 5, status: 'AVAILABLE' },
      });

      sockets = {
        requesterX: await connectSocket(tokens.requesterX),
        requesterY: await connectSocket(tokens.requesterY),
        responderA: await connectSocket(tokens.responderA),
        responderB: await connectSocket(tokens.responderB),
        responderD: await connectSocket(tokens.responderD),
        unrelated: await connectSocket(tokens.unrelated),
        admin: await connectSocket(tokens.admin),
      };
    });

    afterEach(() => {
      disconnectAllSockets();
    });

    afterAll(async () => {
      disconnectAllSockets();
      await closeSocketServer();
      if (httpServer) {
        await new Promise((resolve) => httpServer.close(resolve));
      }
      const allEmails = Object.values(users || {}).map((user) => user.email);
      const allResources = Object.values(resources || {}).map((resource) => resource.name);
      await prisma.allocation.deleteMany({
        where: {
          OR: [
            { responder: { email: { in: allEmails } } },
            { resource: { name: { in: allResources } } },
          ],
        },
      });
      await prisma.emergencyRequest.deleteMany({
        where: { requester: { email: { in: allEmails } } },
      });
      await prisma.responderResource.deleteMany({
        where: { OR: [{ responder: { email: { in: allEmails } } }, { resource: { name: { in: allResources } } }] },
      });
      await prisma.resource.deleteMany({ where: { name: { in: allResources } } });
      await prisma.user.deleteMany({ where: { email: { in: allEmails } } });
      await prisma.$disconnect();
    }, 30000);

    // ------------------------------------------------------------------
    // Cases 1-4: responder.assigned notifications for first and second
    // responders, requester and admin visibility.
    // ------------------------------------------------------------------
    test('first and second responder assignments notify responder, requester, and admin', async () => {
      const emergency = await createEmergency(allLines());

      // Case 1: first responder assignment notification.
      const assignedToA = waitForEvent(
        sockets.responderA,
        'responder.assigned',
        (payload) => payload.requestId === emergency.id && payload.responderId === users.responderA.id
      );
      const assignedToRequesterA = waitForEvent(
        sockets.requesterX,
        'responder.assigned',
        (payload) => payload.requestId === emergency.id && payload.responderId === users.responderA.id
      );
      const assignedToAdminA = waitForEvent(
        sockets.admin,
        'responder.assigned',
        (payload) => payload.requestId === emergency.id && payload.responderId === users.responderA.id
      );

      await accept(tokens.responderA, emergency.id);

      const firstAssignment = await assignedToA;
      expect(firstAssignment.assignment).toMatchObject({
        requestId: emergency.id,
        responderId: users.responderA.id,
        status: 'ACTIVE',
      });
      expect(firstAssignment.assignment.responder).toMatchObject({
        id: users.responderA.id,
      });
      // The assignment responder projection must stay non-private.
      expect(firstAssignment.assignment.responder.passwordHash).toBeUndefined();
      expect(firstAssignment.assignment.responder.email).toBeUndefined();
      expect(firstAssignment.assignments).toHaveLength(1);
      expect(firstAssignment.request).toMatchObject({
        id: emergency.id,
        status: 'ACCEPTED',
      });
      expect(firstAssignment.request.assignments).toHaveLength(1);
      await assignedToRequesterA;
      await assignedToAdminA;

      // Case 2: second responder assignment notification.
      const assignedToB = waitForEvent(
        sockets.responderB,
        'responder.assigned',
        (payload) => payload.requestId === emergency.id && payload.responderId === users.responderB.id
      );
      const assignedToRequesterB = waitForEvent(
        sockets.requesterX,
        'responder.assigned',
        (payload) => payload.requestId === emergency.id && payload.responderId === users.responderB.id
      );
      const assignedToAdminB = waitForEvent(
        sockets.admin,
        'responder.assigned',
        (payload) => payload.requestId === emergency.id && payload.responderId === users.responderB.id
      );

      await accept(tokens.responderB, emergency.id);

      const secondAssignment = await assignedToB;
      expect(secondAssignment.assignment.responderId).toBe(users.responderB.id);
      expect(secondAssignment.assignment.status).toBe('ACTIVE');

      // Case 3: the requester receives the multi-responder state.
      const requesterView = await assignedToRequesterB;
      expect(requesterView.assignments).toHaveLength(2);
      expect(new Set(requesterView.assignments.map((row) => row.responderId))).toEqual(
        new Set([users.responderA.id, users.responderB.id])
      );
      expect(requesterView.request.assignments).toHaveLength(2);
      // acceptedBy compatibility fields remain in the request snapshot.
      expect(requesterView.request.acceptedById).toBe(users.responderA.id);
      expect(requesterView.request.acceptedBy).toMatchObject({ id: users.responderA.id });

      // Case 4: admin receives the same multi-responder state.
      const adminView = await assignedToAdminB;
      expect(adminView.assignments).toHaveLength(2);
    }, 15000);

    // ------------------------------------------------------------------
    // Cases 5-8: request-room subscription authorization.
    // ------------------------------------------------------------------
    test('request room authorization: assigned, allocation-only, unrelated, and legacy responders', async () => {
      const emergency = await createEmergency(allLines());
      await accept(tokens.responderA, emergency.id);
      await accept(tokens.responderB, emergency.id);

      // Case 5: assigned responders can join the request room.
      await expect(
        emitAck(sockets.responderA, 'request.subscribe', { requestId: emergency.id })
      ).resolves.toMatchObject({ ok: true, requestId: emergency.id });
      await expect(
        emitAck(sockets.responderB, 'request.subscribe', { requestId: emergency.id })
      ).resolves.toMatchObject({ ok: true, requestId: emergency.id });

      // Case 6: an allocation-only responder (no assignment row) can join
      // the request room: createAllocation intentionally permits that state.
      const allocationResponse = await allocate(tokens.responderD, {
        requestId: emergency.id,
        responderResourceId: capabilities.responderDBlood.id,
        resourceId: resources.blood.id,
        quantity: 1,
      });
      expect(allocationResponse.statusCode).toBe(201);
      await expect(
        emitAck(sockets.responderD, 'request.subscribe', { requestId: emergency.id })
      ).resolves.toMatchObject({ ok: true, requestId: emergency.id });

      // Case 7: an unrelated responder is denied.
      await expect(
        emitAck(sockets.unrelated, 'request.subscribe', { requestId: emergency.id })
      ).resolves.toMatchObject({
        ok: false,
        error: expect.objectContaining({ code: 'FORBIDDEN' }),
      });

      // Case 8a: legacy fallback - acceptedById authorizes when no
      // assignment row exists for the pair (pre-assignment-era row).
      const legacy = await prisma.emergencyRequest.create({
        data: {
          requesterId: users.requesterX.id,
          acceptedById: users.responderA.id,
          acceptedAt: new Date(),
          emergencyType: 'Medical',
          location: 'Thrissur, Kerala',
          priority: 'HIGH',
          status: 'ACCEPTED',
          requiredResources: {
            create: [{ resourceId: resources.ambulance.id, quantity: 1 }],
          },
        },
      });
      await expect(
        emitAck(sockets.responderA, 'request.subscribe', { requestId: legacy.id })
      ).resolves.toMatchObject({ ok: true, requestId: legacy.id });
      await expect(
        emitAck(sockets.responderB, 'request.subscribe', { requestId: legacy.id })
      ).resolves.toMatchObject({
        ok: false,
        error: expect.objectContaining({ code: 'FORBIDDEN' }),
      });

      // Case 8b: once an (ENDED) assignment row exists for the pair, the
      // table is authoritative and acceptedById no longer authorizes it.
      await prisma.responderAssignment.create({
        data: {
          requestId: legacy.id,
          responderId: users.responderA.id,
          status: 'ENDED',
          endedAt: new Date(),
        },
      });
      await expect(
        emitAck(sockets.responderA, 'request.subscribe', { requestId: legacy.id })
      ).resolves.toMatchObject({
        ok: false,
        error: expect.objectContaining({ code: 'FORBIDDEN' }),
      });
    }, 15000);

    // ------------------------------------------------------------------
    // Cases 9-11: full updates reach every participant; nothing leaks.
    // ------------------------------------------------------------------
    test('request.updated and allocation.updated reach all assigned responders and the allocation owner only', async () => {
      const emergency = await createEmergency(allLines());

      await accept(tokens.responderA, emergency.id);

      // Case 9: both active assigned responders receive the full update
      // (assignments[] included) after the second acceptance. The waiters
      // are registered BEFORE the acceptance so they observe its emission.
      const updatedForA = waitForEvent(
        sockets.responderA,
        'request.updated',
        (payload) =>
          payload.requestId === emergency.id &&
          payload.status === 'ACCEPTED' &&
          payload.request &&
          payload.request.assignments.length === 2
      );
      const updatedForB = waitForEvent(
        sockets.responderB,
        'request.updated',
        (payload) =>
          payload.requestId === emergency.id &&
          payload.status === 'ACCEPTED' &&
          payload.request &&
          payload.request.assignments.length === 2
      );
      const updatedForRequester = waitForEvent(
        sockets.requesterX,
        'request.updated',
        (payload) =>
          payload.requestId === emergency.id &&
          payload.status === 'ACCEPTED' &&
          payload.request &&
          payload.request.assignments.length === 2
      );
      // Case 10: the unrelated responder must NOT receive the full update.
      const noFullUpdateForUnrelated = expectNoEvent(
        sockets.unrelated,
        'request.updated',
        (payload) => payload.requestId === emergency.id && payload.request
      );

      await accept(tokens.responderB, emergency.id);

      await updatedForA;
      await updatedForB;
      await updatedForRequester;
      await noFullUpdateForUnrelated;

      // Case 11: allocation.updated reaches the allocation owner even
      // though responder D holds no assignment on this request. The waiters
      // are registered BEFORE the allocation so they observe its creation
      // emission (RESERVED).
      const allocationForOwner = waitForEvent(
        sockets.responderD,
        'allocation.updated',
        (payload) => payload.status === 'RESERVED' && payload.responderId === users.responderD.id
      );
      const allocationForRequester = waitForEvent(
        sockets.requesterX,
        'allocation.updated',
        (payload) => payload.status === 'RESERVED' && payload.responderId === users.responderD.id
      );
      const noAllocationForUnrelated = expectNoEvent(
        sockets.unrelated,
        'allocation.updated',
        (payload) => payload.responderId === users.responderD.id
      );

      const allocationResponse = await allocate(tokens.responderD, {
        requestId: emergency.id,
        responderResourceId: capabilities.responderDBlood.id,
        resourceId: resources.blood.id,
        quantity: 1,
      });
      expect(allocationResponse.statusCode).toBe(201);
      const allocation = allocationResponse.body.allocation;

      await allocationForOwner;
      await allocationForRequester;
      await noAllocationForUnrelated;

      // The owner also receives the follow-up DISPATCHED emission.
      const dispatchedForOwner = waitForEvent(
        sockets.responderD,
        'allocation.updated',
        (payload) => payload.allocationId === allocation.id && payload.status === 'DISPATCHED'
      );
      await patchAllocation(tokens.responderD, allocation.id, 'DISPATCHED');
      await dispatchedForOwner;
    }, 15000);

    // ------------------------------------------------------------------
    // Cases 12-15: multi-responder live location.
    // ------------------------------------------------------------------
    test('location streams are authorized per responder and published independently', async () => {
      const emergency = await createEmergency(allLines());
      await accept(tokens.responderA, emergency.id);
      await accept(tokens.responderB, emergency.id);
      await emitAck(sockets.requesterX, 'request.subscribe', { requestId: emergency.id });

      // Case 12: the SECOND responder (ACTIVE assignment, not acceptedById)
      // is authorized to start and update a live location.
      await expect(
        emitAck(sockets.responderB, 'responder.location.start', { requestId: emergency.id })
      ).resolves.toMatchObject({ ok: true, requestId: emergency.id });

      // An allocation-only responder may share location while they hold an
      // unfinished allocation (Part 10, second condition).
      const allocationResponse = await allocate(tokens.responderD, {
        requestId: emergency.id,
        responderResourceId: capabilities.responderDBlood.id,
        resourceId: resources.blood.id,
        quantity: 1,
      });
      expect(allocationResponse.statusCode).toBe(201);
      await expect(
        emitAck(sockets.responderD, 'responder.location.start', { requestId: emergency.id })
      ).resolves.toMatchObject({ ok: true, requestId: emergency.id });

      // Case 13: an unrelated responder cannot publish location.
      await expect(
        emitAck(sockets.unrelated, 'responder.location.update', {
          requestId: emergency.id,
          latitude: 10.52,
          longitude: 76.21,
        })
      ).resolves.toMatchObject({
        ok: false,
        error: expect.objectContaining({ code: 'FORBIDDEN' }),
      });

      // Cases 14 + 15: multiple responders publish independently; the
      // requester distinguishes them by responderId, and neither stream
      // overwrites the other.
      const locationFromB = waitForEvent(
        sockets.requesterX,
        'responder.location.update',
        (payload) =>
          payload.requestId === emergency.id &&
          payload.responderId === users.responderB.id &&
          payload.latitude === 10.5281
      );
      const locationFromD = waitForEvent(
        sockets.requesterX,
        'responder.location.update',
        (payload) =>
          payload.requestId === emergency.id &&
          payload.responderId === users.responderD.id &&
          payload.latitude === 10.5399
      );

      await expect(
        emitAck(sockets.responderB, 'responder.location.update', {
          requestId: emergency.id,
          latitude: 10.5281,
          longitude: 76.2151,
        })
      ).resolves.toMatchObject({ ok: true });
      await expect(
        emitAck(sockets.responderD, 'responder.location.update', {
          requestId: emergency.id,
          latitude: 10.5399,
          longitude: 76.2244,
        })
      ).resolves.toMatchObject({ ok: true });

      const fromB = await locationFromB;
      const fromD = await locationFromD;
      expect(fromB.responderId).not.toBe(fromD.responderId);
      expect(fromB.latitude).not.toBe(fromD.latitude);
    }, 15000);

    // ------------------------------------------------------------------
    // Case 16 + 18: terminal stop per responder; completed not joinable.
    // ------------------------------------------------------------------
    test('terminal cleanup emits a location.stop per participating responder and the completed request is no longer joinable', async () => {
      const emergency = await createEmergency(allLines());
      await accept(tokens.responderA, emergency.id);
      await accept(tokens.responderB, emergency.id);
      await emitAck(sockets.requesterX, 'request.subscribe', { requestId: emergency.id });

      // Every participating responder starts a stream: two assignment
      // holders and one allocation-only responder.
      const ambulanceAllocation = (
        await allocate(tokens.responderA, {
          requestId: emergency.id,
          responderResourceId: capabilities.responderAAmbulance.id,
          resourceId: resources.ambulance.id,
          quantity: 1,
        })
      ).body.allocation;
      const fireAllocation = (
        await allocate(tokens.responderB, {
          requestId: emergency.id,
          responderResourceId: capabilities.responderBFire.id,
          resourceId: resources.fireEngine.id,
          quantity: 1,
        })
      ).body.allocation;
      const bloodAllocation = (
        await allocate(tokens.responderD, {
          requestId: emergency.id,
          responderResourceId: capabilities.responderDBlood.id,
          resourceId: resources.blood.id,
          quantity: 1,
        })
      ).body.allocation;

      await emitAck(sockets.responderA, 'responder.location.start', { requestId: emergency.id });
      await emitAck(sockets.responderB, 'responder.location.start', { requestId: emergency.id });
      await emitAck(sockets.responderD, 'responder.location.start', { requestId: emergency.id });

      // Case 18 prelude: while every line is fully allocated (nothing
      // outstanding), the redacted signal must already say not joinable.
      const notJoinableWhenFullyAllocated = waitForEvent(
        sockets.unrelated,
        'request.updated',
        (payload) => payload.requestId === emergency.id && payload.available === false
      );
      await patchAllocation(tokens.responderA, ambulanceAllocation.id, 'DISPATCHED');
      await notJoinableWhenFullyAllocated;

      // Case 16: terminal stop is per responder - one event per
      // participating responder, each carrying that responder's id.
      const stopForA = waitForEvent(
        sockets.requesterX,
        'responder.location.stop',
        (payload) => payload.requestId === emergency.id && payload.responderId === users.responderA.id
      );
      const stopForB = waitForEvent(
        sockets.requesterX,
        'responder.location.stop',
        (payload) => payload.requestId === emergency.id && payload.responderId === users.responderB.id
      );
      const stopForD = waitForEvent(
        sockets.requesterX,
        'responder.location.stop',
        (payload) => payload.requestId === emergency.id && payload.responderId === users.responderD.id
      );
      const completedRedaction = waitForEvent(
        sockets.unrelated,
        'request.updated',
        (payload) => payload.requestId === emergency.id && payload.status === 'COMPLETED'
      );

      await patchAllocation(tokens.responderA, ambulanceAllocation.id, 'DELIVERED');
      await patchAllocation(tokens.responderB, fireAllocation.id, 'DISPATCHED');
      await patchAllocation(tokens.responderB, fireAllocation.id, 'DELIVERED');
      await patchAllocation(tokens.responderD, bloodAllocation.id, 'DISPATCHED');
      await confirmReceived(tokens.requesterX, bloodAllocation.id);

      await stopForA;
      await stopForB;
      await stopForD;

      // Case 18: a completed request is no longer joinable.
      const completedSignal = await completedRedaction;
      expect(completedSignal.available).toBe(false);
      expect(completedSignal.request).toBeUndefined();

      const stored = await prisma.emergencyRequest.findUnique({
        where: { id: emergency.id },
        select: { status: true },
      });
      expect(stored.status).toBe('COMPLETED');

      // Location updates on the completed request are rejected.
      await expect(
        emitAck(sockets.responderB, 'responder.location.update', {
          requestId: emergency.id,
          latitude: 10.53,
          longitude: 76.22,
        })
      ).resolves.toMatchObject({
        ok: false,
        error: expect.objectContaining({ code: 'FORBIDDEN' }),
      });
    }, 20000);

    // ------------------------------------------------------------------
    // Case 17: redacted joinability for accepted requests with outstanding
    // work (the old status === PENDING gate said "not available").
    // ------------------------------------------------------------------
    test('redacted responders-room signal keeps an accepted request with outstanding work joinable', async () => {
      const emergency = await createEmergency(allLines());

      // PENDING + outstanding -> available.
      const pendingSignal = waitForEvent(
        sockets.unrelated,
        'request.updated',
        (payload) => payload.requestId === emergency.id && payload.status === 'PENDING'
      );
      // Trigger a request.updated redaction while still PENDING via an
      // unrelated lifecycle emission is not possible; the first acceptance
      // below produces the first redaction. PENDING itself is broadcast via
      // request.created, so assert joinability from ACCEPTED onward.

      // ACCEPTED + outstanding -> available (the Phase E change).
      const acceptedSignal = waitForEvent(
        sockets.unrelated,
        'request.updated',
        (payload) =>
          payload.requestId === emergency.id &&
          payload.status === 'ACCEPTED' &&
          payload.available === true
      );

      await accept(tokens.responderA, emergency.id);
      await pendingSignal.catch(() => {}); // no PENDING redaction expected
      const accepted = await acceptedSignal;
      expect(accepted.request).toBeUndefined();
      expect(accepted.acceptedBy).toBeUndefined();

      // IN_PROGRESS + outstanding -> still available.
      const inProgressSignal = waitForEvent(
        sockets.unrelated,
        'request.updated',
        (payload) =>
          payload.requestId === emergency.id &&
          payload.status === 'IN_PROGRESS' &&
          payload.available === true
      );
      const ambulanceAllocation = (
        await allocate(tokens.responderA, {
          requestId: emergency.id,
          responderResourceId: capabilities.responderAAmbulance.id,
          resourceId: resources.ambulance.id,
          quantity: 1,
        })
      ).body.allocation;
      await inProgressSignal;
      await patchAllocation(tokens.responderA, ambulanceAllocation.id, 'DISPATCHED');

      // PARTIALLY_ALLOCATED + outstanding -> still available.
      const partialSignal = waitForEvent(
        sockets.unrelated,
        'request.updated',
        (payload) =>
          payload.requestId === emergency.id &&
          payload.status === 'PARTIALLY_ALLOCATED' &&
          payload.available === true
      );
      await patchAllocation(tokens.responderA, ambulanceAllocation.id, 'DELIVERED');
      await partialSignal;

      // Fully allocated -> not available (blood and fire lines still have
      // no allocations here, so allocate them too and assert the flip).
      const fireAllocation = (
        await allocate(tokens.responderB, {
          requestId: emergency.id,
          responderResourceId: capabilities.responderBFire.id,
          resourceId: resources.fireEngine.id,
          quantity: 1,
        })
      ).body.allocation;
      const bloodAllocation = (
        await allocate(tokens.responderD, {
          requestId: emergency.id,
          responderResourceId: capabilities.responderDBlood.id,
          resourceId: resources.blood.id,
          quantity: 1,
        })
      ).body.allocation;
      const fullyAllocatedSignal = waitForEvent(
        sockets.unrelated,
        'request.updated',
        (payload) =>
          payload.requestId === emergency.id &&
          payload.available === false &&
          !payload.request
      );
      await patchAllocation(tokens.responderB, fireAllocation.id, 'DISPATCHED');
      await patchAllocation(tokens.responderD, bloodAllocation.id, 'DISPATCHED');
      await fullyAllocatedSignal;
    }, 20000);

    // ------------------------------------------------------------------
    // Case 19: cancelled request is no longer joinable.
    // ------------------------------------------------------------------
    test('a cancelled request is no longer joinable', async () => {
      const emergency = await createEmergency(allLines());
      await accept(tokens.responderA, emergency.id);

      const cancelledSignal = waitForEvent(
        sockets.unrelated,
        'request.updated',
        (payload) =>
          payload.requestId === emergency.id &&
          payload.status === 'CANCELLED' &&
          payload.available === false
      );

      await cancelRequest(tokens.requesterX, emergency.id);
      const cancelled = await cancelledSignal;
      expect(cancelled.request).toBeUndefined();

      // A responder who is not a participant cannot subscribe either.
      await expect(
        emitAck(sockets.unrelated, 'request.subscribe', { requestId: emergency.id })
      ).resolves.toMatchObject({
        ok: false,
        error: expect.objectContaining({ code: 'FORBIDDEN' }),
      });
    }, 15000);

    // ------------------------------------------------------------------
    // Case 20: reconnect restores only the authorized request rooms.
    // ------------------------------------------------------------------
    test('reconnect restores the responder\'s authorized request rooms and only those', async () => {
      // E1: responder A holds an ACTIVE assignment.
      const e1 = await createEmergency([
        { resourceId: resources.ambulance.id, quantity: 1 },
        { resourceId: resources.fireEngine.id, quantity: 1 },
      ]);
      await accept(tokens.responderA, e1.id);

      // E2: responder D is an allocation-only participant.
      const e2 = await createEmergency([{ resourceId: resources.blood.id, quantity: 1 }]);
      const dAllocation = (
        await allocate(tokens.responderD, {
          requestId: e2.id,
          responderResourceId: capabilities.responderDBlood.id,
          resourceId: resources.blood.id,
          quantity: 1,
        })
      ).body.allocation;

      // E3: requester Y's private request - A and D must never see it.
      const e3 = await createEmergency(
        [{ resourceId: resources.helicopter.id, quantity: 1 }],
        tokens.requesterY
      );
      await accept(tokens.unrelated, e3.id);

      // Reconnect A and D.
      sockets.responderA.disconnect();
      sockets.responderD.disconnect();
      await wait(150);
      sockets.responderA = await connectSocket(tokens.responderA);
      sockets.responderD = await connectSocket(tokens.responderD);
      // Give the connect-time room joins a moment to settle.
      await wait(300);

      // Trigger updates on all three requests.
      const e1UpdateForA = waitForEvent(
        sockets.responderA,
        'request.updated',
        (payload) => payload.requestId === e1.id && payload.request
      );
      const e2UpdateForD = waitForEvent(
        sockets.responderD,
        'request.updated',
        (payload) => payload.requestId === e2.id && payload.request
      );
      const e3FullUpdateForA = expectNoEvent(
        sockets.responderA,
        'request.updated',
        (payload) => payload.requestId === e3.id && payload.request
      );
      const e3FullUpdateForD = expectNoEvent(
        sockets.responderD,
        'request.updated',
        (payload) => payload.requestId === e3.id && payload.request
      );

      await accept(tokens.responderB, e1.id); // triggers request.updated for E1 rooms
      await patchAllocation(tokens.responderD, dAllocation.id, 'DISPATCHED'); // triggers E2 rooms
      await allocate(tokens.unrelated, {
        requestId: e3.id,
        responderResourceId: capabilities.unrelatedHelicopter.id,
        resourceId: resources.helicopter.id,
        quantity: 1,
      }); // triggers E3 rooms

      // A receives E1 (assignment), D receives E2 (unfinished allocation),
      // and neither receives requester Y's private E3 data.
      await e1UpdateForA;
      await e2UpdateForD;
      await e3FullUpdateForA;
      await e3FullUpdateForD;

      // REST resynchronization remains the authoritative fallback.
      const resyncA = await request(app)
        .get('/api/requests/assigned')
        .set('Authorization', `Bearer ${tokens.responderA}`);
      expect(resyncA.statusCode).toBe(200);
      expect(resyncA.body.requests).toEqual(
        expect.arrayContaining([expect.objectContaining({ id: e1.id })])
      );
      expect(
        resyncA.body.requests.some((row) => row.id === e3.id)
      ).toBe(false);
    }, 20000);

    // ------------------------------------------------------------------
    // Room isolation across requests (Part 16 security matrix).
    // ------------------------------------------------------------------
    test('responders on different requests are isolated from each other\'s request data', async () => {
      // X gets responder A; Y gets the unrelated responder.
      const x = await createEmergency([{ resourceId: resources.ambulance.id, quantity: 1 }]);
      const y = await createEmergency(
        [{ resourceId: resources.helicopter.id, quantity: 1 }],
        tokens.requesterY
      );
      await accept(tokens.responderA, x.id);
      await accept(tokens.unrelated, y.id);

      await expect(
        emitAck(sockets.responderA, 'request.subscribe', { requestId: x.id })
      ).resolves.toMatchObject({ ok: true });
      await expect(
        emitAck(sockets.unrelated, 'request.subscribe', { requestId: y.id })
      ).resolves.toMatchObject({ ok: true });

      const xFullForY = expectNoEvent(
        sockets.unrelated,
        'request.updated',
        (payload) => payload.requestId === x.id && payload.request
      );
      const yFullForX = expectNoEvent(
        sockets.responderA,
        'request.updated',
        (payload) => payload.requestId === y.id && payload.request
      );
      const yFullForRequesterX = expectNoEvent(
        sockets.requesterX,
        'request.updated',
        (payload) => payload.requestId === y.id && payload.request
      );

      // Trigger full updates on both requests.
      const xAllocation = (
        await allocate(tokens.responderA, {
          requestId: x.id,
          responderResourceId: capabilities.responderAAmbulance.id,
          resourceId: resources.ambulance.id,
          quantity: 1,
        })
      ).body.allocation;
      const yAllocation = (
        await allocate(tokens.unrelated, {
          requestId: y.id,
          responderResourceId: capabilities.unrelatedHelicopter.id,
          resourceId: resources.helicopter.id,
          quantity: 1,
        })
      ).body.allocation;
      await patchAllocation(tokens.responderA, xAllocation.id, 'DISPATCHED');
      await patchAllocation(tokens.unrelated, yAllocation.id, 'DISPATCHED');

      await xFullForY;
      await yFullForX;
      await yFullForRequesterX;

      // Two responders on the SAME request both receive its updates. The
      // one-active-emergency rule keeps responder A and the unrelated
      // responder BUSY on their earlier requests, so responders B and D
      // (both still free) join this one.
      const shared = await createEmergency([
        { resourceId: resources.fireEngine.id, quantity: 1 },
        { resourceId: resources.blood.id, quantity: 1 },
      ]);
      await accept(tokens.responderB, shared.id);
      await accept(tokens.responderD, shared.id);
      await expect(
        emitAck(sockets.responderB, 'request.subscribe', { requestId: shared.id })
      ).resolves.toMatchObject({ ok: true });
      await expect(
        emitAck(sockets.responderD, 'request.subscribe', { requestId: shared.id })
      ).resolves.toMatchObject({ ok: true });

      const sharedForB = waitForEvent(
        sockets.responderB,
        'request.updated',
        (payload) => payload.requestId === shared.id && payload.request
      );
      const sharedForD = waitForEvent(
        sockets.responderD,
        'request.updated',
        (payload) => payload.requestId === shared.id && payload.request
      );
      const sharedAllocation = (
        await allocate(tokens.responderB, {
          requestId: shared.id,
          responderResourceId: capabilities.responderBFire.id,
          resourceId: resources.fireEngine.id,
          quantity: 1,
        })
      ).body.allocation;
      await patchAllocation(tokens.responderB, sharedAllocation.id, 'DISPATCHED');
      await sharedForB;
      await sharedForD;
    }, 20000);
  }
);
