// Load backend/.env first so a locally configured PostgreSQL test database is
// detected. Without this, the suite silently skipped even when a working
// DATABASE_URL/JWT_SECRET existed in .env, because the guard below read
// process.env before dotenv ran (dotenv is only loaded lazily via
// src/config/env when the app is required, which happens after this check).
require('dotenv').config();

const bcrypt = require('bcrypt');
const http = require('http');
const request = require('supertest');
const { io: ioClient } = require('socket.io-client');

const hasDatabase = Boolean(process.env.DATABASE_URL && process.env.JWT_SECRET);

if (!hasDatabase) {
  describe.skip('Socket.IO multi-client integration (requires DATABASE_URL and JWT_SECRET)', () => {
    test('skipped because a PostgreSQL test database is not configured', () => {});
  });
} else {
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

  const password = 'SocketIntegration123!';
  const runId = `socket-${Date.now()}`;
  const emails = {
    requesterA: `${runId}-requester-a@test.com`,
    requesterB: `${runId}-requester-b@test.com`,
    responderA: `${runId}-responder-a@test.com`,
    responderB: `${runId}-responder-b@test.com`,
    responderC: `${runId}-responder-c@test.com`,
    admin: `${runId}-admin@test.com`,
  };
  const resourceNames = {
    ambulance: `${runId} Ambulance`,
    fire: `${runId} Fire Engine`,
  };

  let httpServer;
  let serverUrl;
  let users;
  let tokens;
  let resources;
  let responderResources;
  let sockets;

  async function cleanup() {
    const allEmails = Object.values(emails);
    const allResources = Object.values(resourceNames);

    await prisma.allocation.deleteMany({
      where: {
        OR: [
          { responder: { email: { in: allEmails } } },
          { request: { requester: { email: { in: allEmails } } } },
          { resource: { name: { in: allResources } } },
        ],
      },
    });
    await prisma.requestResource.deleteMany({
      where: {
        OR: [
          { request: { requester: { email: { in: allEmails } } } },
          { resource: { name: { in: allResources } } },
        ],
      },
    });
    await prisma.emergencyRequest.deleteMany({
      where: {
        OR: [
          { requester: { email: { in: allEmails } } },
          { acceptedBy: { email: { in: allEmails } } },
        ],
      },
    });
    await prisma.responderResource.deleteMany({
      where: {
        OR: [
          { responder: { email: { in: allEmails } } },
          { resource: { name: { in: allResources } } },
        ],
      },
    });
    await prisma.resource.deleteMany({ where: { name: { in: allResources } } });
    await prisma.user.deleteMany({ where: { email: { in: allEmails } } });
  }

  async function seed() {
    await cleanup();
    const hashedPassword = await bcrypt.hash(password, 10);

    users = {
      requesterA: await prisma.user.create({
        data: {
          name: 'Socket Requester A',
          email: emails.requesterA,
          password: hashedPassword,
          role: 'REQUESTER',
          isActive: true,
          location: 'Thrissur, Kerala',
        },
      }),
      requesterB: await prisma.user.create({
        data: {
          name: 'Socket Requester B',
          email: emails.requesterB,
          password: hashedPassword,
          role: 'REQUESTER',
          isActive: true,
          location: 'Kochi, Kerala',
        },
      }),
      responderA: await prisma.user.create({
        data: {
          name: 'Socket Responder A',
          email: emails.responderA,
          password: hashedPassword,
          role: 'RESPONDER',
          isActive: true,
          responderStatus: 'AVAILABLE',
          location: 'Thrissur Round, Kerala',
        },
      }),
      responderB: await prisma.user.create({
        data: {
          name: 'Socket Responder B',
          email: emails.responderB,
          password: hashedPassword,
          role: 'RESPONDER',
          isActive: true,
          responderStatus: 'AVAILABLE',
          location: 'Kochi Marine Drive, Kerala',
        },
      }),
      responderC: await prisma.user.create({
        data: {
          name: 'Socket Incompatible Responder C',
          email: emails.responderC,
          password: hashedPassword,
          role: 'RESPONDER',
          isActive: true,
          responderStatus: 'AVAILABLE',
          location: 'Kozhikode Beach, Kerala',
        },
      }),
      admin: await prisma.user.create({
        data: {
          name: 'Socket Admin',
          email: emails.admin,
          password: hashedPassword,
          role: 'ADMIN',
          isActive: true,
        },
      }),
    };

    resources = {
      ambulance: await prisma.resource.create({
        data: {
          name: resourceNames.ambulance,
          type: 'AMBULANCE',
          mode: 'SERVICE',
          totalQuantity: 0,
          availableQuantity: 0,
          isActive: true,
        },
      }),
      fire: await prisma.resource.create({
        data: {
          name: resourceNames.fire,
          type: 'FIRE',
          mode: 'SERVICE',
          totalQuantity: 0,
          availableQuantity: 0,
          isActive: true,
        },
      }),
    };

    responderResources = {
      responderAAmbulance: await prisma.responderResource.create({
        data: {
          responderId: users.responderA.id,
          resourceId: resources.ambulance.id,
          totalQuantity: 0,
          availableQuantity: 0,
          isEnabled: true,
          status: 'UNAVAILABLE',
        },
      }),
      responderBAmbulance: await prisma.responderResource.create({
        data: {
          responderId: users.responderB.id,
          resourceId: resources.ambulance.id,
          totalQuantity: 0,
          availableQuantity: 0,
          isEnabled: true,
          status: 'UNAVAILABLE',
        },
      }),
      responderCFire: await prisma.responderResource.create({
        data: {
          responderId: users.responderC.id,
          resourceId: resources.fire.id,
          totalQuantity: 0,
          availableQuantity: 0,
          isEnabled: true,
          status: 'UNAVAILABLE',
        },
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
  }

  function wait(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }

  async function waitForCondition(assertion, timeoutMs = 1500) {
    const started = Date.now();
    let lastError;
    while (Date.now() - started < timeoutMs) {
      try {
        await assertion();
        return;
      } catch (error) {
        lastError = error;
        await wait(40);
      }
    }
    throw lastError;
  }

  function waitForEvent(socket, eventName, predicate = () => true, timeoutMs = 1500) {
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

  function expectNoEvent(socket, eventName, predicate = () => true, durationMs = 300) {
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

  async function connectAllSockets() {
    sockets = {
      requesterA: await connectSocket(tokens.requesterA),
      requesterB: await connectSocket(tokens.requesterB),
      responderA: await connectSocket(tokens.responderA),
      responderB: await connectSocket(tokens.responderB),
      responderC: await connectSocket(tokens.responderC),
      admin: await connectSocket(tokens.admin),
    };
  }

  function disconnectAllSockets() {
    if (!sockets) return;
    for (const socket of Object.values(sockets)) {
      socket.removeAllListeners();
      socket.disconnect();
    }
    sockets = null;
  }

  async function createEmergency({ requesterToken = tokens.requesterA, location = 'Thrissur, Kerala' } = {}) {
    const response = await request(app)
      .post('/api/requests')
      .set('Authorization', `Bearer ${requesterToken}`)
      .send({
        emergencyType: 'Medical',
        description: 'Socket.IO integration ambulance emergency',
        location,
        latitude: 10.5276,
        longitude: 76.2144,
        priority: 'HIGH',
        requiredResources: [
          { resourceId: resources.ambulance.id, quantity: 1 },
        ],
      });

    expect(response.statusCode).toBe(201);
    return response.body.request;
  }

  async function acceptEmergency(requestId) {
    const response = await request(app)
      .patch(`/api/requests/${requestId}/accept`)
      .set('Authorization', `Bearer ${tokens.responderA}`);
    expect(response.statusCode).toBe(200);
    return response.body.request;
  }

  async function createAllocation(requestId) {
    const response = await request(app)
      .post('/api/allocations')
      .set('Authorization', `Bearer ${tokens.responderA}`)
      .send({
        requestId,
        responderResourceId: responderResources.responderAAmbulance.id,
        resourceId: resources.ambulance.id,
        quantity: 1,
      });
    expect(response.statusCode).toBe(201);
    return response.body.allocation;
  }

  async function patchAllocation(allocationId, status) {
    const response = await request(app)
      .patch(`/api/allocations/${allocationId}/status`)
      .set('Authorization', `Bearer ${tokens.responderA}`)
      .send({ status });
    expect(response.statusCode).toBe(200);
    return response.body.allocation;
  }

  async function confirmReceived(allocationId) {
    const response = await request(app)
      .patch(`/api/allocations/${allocationId}/received`)
      .set('Authorization', `Bearer ${tokens.requesterA}`);
    expect(response.statusCode).toBe(200);
    return response.body.allocation;
  }

  async function expectResponderStatus(status) {
    await waitForCondition(async () => {
      const responder = await prisma.user.findUnique({
        where: { id: users.responderA.id },
        select: { responderStatus: true },
      });
      expect(responder.responderStatus).toBe(status);
    });
  }

  async function createAcceptedRequestDirect(requesterId, location = 'Thrissur, Kerala') {
    return prisma.emergencyRequest.create({
      data: {
        requesterId,
        acceptedById: users.responderA.id,
        acceptedAt: new Date(),
        emergencyType: 'Medical',
        description: 'Direct location isolation request',
        location,
        latitude: location === 'Kochi, Kerala' ? 9.9312 : 10.5276,
        longitude: location === 'Kochi, Kerala' ? 76.2673 : 76.2144,
        priority: 'HIGH',
        status: 'ACCEPTED',
        requiredResources: {
          create: [{ resourceId: resources.ambulance.id, quantity: 1 }],
        },
      },
    });
  }

  beforeAll(async () => {
    await seed();
    httpServer = http.createServer(app);
    createSocketServer(httpServer);
    await new Promise((resolve) => {
      httpServer.listen(0, '127.0.0.1', () => {
        const { port } = httpServer.address();
        serverUrl = `http://127.0.0.1:${port}`;
        resolve();
      });
    });
  });

  beforeEach(async () => {
    disconnectAllSockets();
    await prisma.allocation.deleteMany({
      where: { responderId: { in: [users.responderA.id, users.responderB.id, users.responderC.id] } },
    });
    await prisma.requestResource.deleteMany({
      where: { request: { requesterId: { in: [users.requesterA.id, users.requesterB.id] } } },
    });
    await prisma.emergencyRequest.deleteMany({
      where: { requesterId: { in: [users.requesterA.id, users.requesterB.id] } },
    });
    await prisma.user.updateMany({
      where: { id: { in: [users.responderA.id, users.responderB.id, users.responderC.id] } },
      data: { responderStatus: 'AVAILABLE', isActive: true, latitude: null, longitude: null },
    });
    await connectAllSockets();
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
    await cleanup();
    await prisma.$disconnect();
  });

  test('request creation, acceptance, allocation, dispatch, and both delivery flows are emitted and persisted', async () => {
    const createdForRequester = waitForEvent(sockets.requesterA, 'request.created');
    const createdForResponderA = waitForEvent(sockets.responderA, 'request.created');
    const createdForResponderB = waitForEvent(sockets.responderB, 'request.created');
    const createdForAdmin = waitForEvent(sockets.admin, 'request.created');
    const noCreateForRequesterB = expectNoEvent(sockets.requesterB, 'request.created');
    const noCreateForIncompatible = expectNoEvent(sockets.responderC, 'request.created');

    const emergency = await createEmergency();

    await expect(createdForRequester).resolves.toMatchObject({ requestId: emergency.id });
    await expect(createdForResponderA).resolves.toMatchObject({ requestId: emergency.id });
    await expect(createdForResponderB).resolves.toMatchObject({ requestId: emergency.id });
    await expect(createdForAdmin).resolves.toMatchObject({ requestId: emergency.id });
    await noCreateForRequesterB;
    await noCreateForIncompatible;

    const requesterUpdated = waitForEvent(
      sockets.requesterA,
      'request.updated',
      (payload) => payload.requestId === emergency.id && payload.status === 'ACCEPTED'
    );
    const responderAUpdated = waitForEvent(
      sockets.responderA,
      'request.updated',
      (payload) => payload.requestId === emergency.id && payload.status === 'ACCEPTED'
    );
    const responderBSeesUnavailable = waitForEvent(
      sockets.responderB,
      'request.updated',
      (payload) => payload.requestId === emergency.id && payload.status === 'ACCEPTED'
    );
    const adminUpdated = waitForEvent(
      sockets.admin,
      'request.updated',
      (payload) => payload.requestId === emergency.id && payload.status === 'ACCEPTED'
    );
    const availabilityBusy = waitForEvent(
      sockets.responderA,
      'responder.availability',
      (payload) => payload.responderId === users.responderA.id && payload.responderStatus === 'BUSY'
    );

    await acceptEmergency(emergency.id);
    await requesterUpdated;
    await responderAUpdated;
    const responderBInvalidation = await responderBSeesUnavailable;
    // PHASE E (redacted joinability): an ACCEPTED emergency with outstanding
    // required quantity is still potentially joinable by other compatible
    // responders, so the redacted responders-room signal is now `available:
    // true` instead of the old `status === 'PENDING'` gate. The payload stays
    // redacted (no requester data); GET /compatible stays authoritative.
    expect(responderBInvalidation).toEqual(
      expect.objectContaining({
        requestId: emergency.id,
        status: 'ACCEPTED',
        available: true,
      })
    );
    expect(responderBInvalidation.request).toBeUndefined();
    expect(responderBInvalidation.acceptedBy).toBeUndefined();
    await adminUpdated;
    await availabilityBusy;
    await expectResponderStatus('BUSY');

    const compatibleAfterAccept = await request(app)
      .get('/api/requests/compatible')
      .set('Authorization', `Bearer ${tokens.responderB}`);
    expect(compatibleAfterAccept.statusCode).toBe(200);
    // PHASE C multi-responder dispatch: an ACCEPTED emergency with
    // outstanding work stays visible to other compatible AVAILABLE
    // responders, so responderB may still join. (The old expectation that
    // acceptance hides the request from everyone was intentionally changed;
    // zero-overlap responders still never see it - see responderC above.)
    expect(compatibleAfterAccept.body.requests).toEqual(
      expect.arrayContaining([expect.objectContaining({ id: emergency.id })])
    );

    const allocationEvent = waitForEvent(
      sockets.requesterA,
      'allocation.updated',
      (payload) => payload.requestId === emergency.id && payload.status === 'RESERVED'
    );
    const noAllocationForUnassignedResponder = expectNoEvent(
      sockets.responderB,
      'allocation.updated',
      (payload) => payload.requestId === emergency.id
    );
    const allocation = await createAllocation(emergency.id);
    const allocationPayload = await allocationEvent;
    await noAllocationForUnassignedResponder;
    expect(allocationPayload.allocationId).toBe(allocation.id);
    await expectResponderStatus('BUSY');

    const persistedReserved = await prisma.allocation.findUnique({ where: { id: allocation.id } });
    expect(persistedReserved.status).toBe('RESERVED');
    expect(persistedReserved.quantity).toBe(allocationPayload.quantity);

    const dispatchedEvent = waitForEvent(
      sockets.requesterA,
      'allocation.updated',
      (payload) => payload.allocationId === allocation.id && payload.status === 'DISPATCHED'
    );
    await patchAllocation(allocation.id, 'DISPATCHED');
    await expect(dispatchedEvent).resolves.toMatchObject({
      allocationId: allocation.id,
      status: 'DISPATCHED',
    });
    await expectResponderStatus('BUSY');

    await emitAck(sockets.responderA, 'responder.location.start', {
      requestId: emergency.id,
    });
    const deliveredByRequester = waitForEvent(
      sockets.requesterA,
      'allocation.updated',
      (payload) => payload.allocationId === allocation.id && payload.status === 'DELIVERED'
    );
    const completedLocationCleanup = waitForEvent(
      sockets.requesterA,
      'responder.location.stop',
      (payload) => payload.requestId === emergency.id
    );
    const completedByRequester = waitForEvent(
      sockets.requesterA,
      'request.updated',
      (payload) => payload.requestId === emergency.id && payload.status === 'COMPLETED'
    );
    await confirmReceived(allocation.id);
    await deliveredByRequester;
    await completedByRequester;
    await completedLocationCleanup;

    const requesterFinal = await prisma.emergencyRequest.findUnique({ where: { id: emergency.id } });
    const requesterAllocationFinal = await prisma.allocation.findUnique({ where: { id: allocation.id } });
    expect(requesterFinal.status).toBe('COMPLETED');
    expect(requesterAllocationFinal.status).toBe('DELIVERED');
    await expectResponderStatus('AVAILABLE');

    const fallbackEmergency = await createEmergency();
    await acceptEmergency(fallbackEmergency.id);
    const fallbackAllocation = await createAllocation(fallbackEmergency.id);
    await patchAllocation(fallbackAllocation.id, 'DISPATCHED');

    const responderDelivered = waitForEvent(
      sockets.requesterA,
      'allocation.updated',
      (payload) => payload.allocationId === fallbackAllocation.id && payload.status === 'DELIVERED'
    );
    const responderCompleted = waitForEvent(
      sockets.requesterA,
      'request.updated',
      (payload) => payload.requestId === fallbackEmergency.id && payload.status === 'COMPLETED'
    );
    await patchAllocation(fallbackAllocation.id, 'DELIVERED');
    await responderDelivered;
    await responderCompleted;

    const fallbackFinal = await prisma.emergencyRequest.findUnique({ where: { id: fallbackEmergency.id } });
    const fallbackAllocationFinal = await prisma.allocation.findUnique({ where: { id: fallbackAllocation.id } });
    expect(fallbackFinal.status).toBe('COMPLETED');
    expect(fallbackAllocationFinal.status).toBe('DELIVERED');
    await expectResponderStatus('AVAILABLE');

    const blockerRequest = await createAcceptedRequestDirect(users.requesterA.id);
    await prisma.allocation.create({
      data: {
        requestId: blockerRequest.id,
        resourceId: resources.ambulance.id,
        responderId: users.responderA.id,
        responderResourceId: responderResources.responderAAmbulance.id,
        quantity: 1,
        status: 'RESERVED',
      },
    });

    const blockedEmergency = await createAcceptedRequestDirect(users.requesterA.id);
    const blockedAllocation = await prisma.allocation.create({
      data: {
        requestId: blockedEmergency.id,
        resourceId: resources.ambulance.id,
        responderId: users.responderA.id,
        responderResourceId: responderResources.responderAAmbulance.id,
        quantity: 1,
        status: 'DISPATCHED',
      },
    });
    await patchAllocation(blockedAllocation.id, 'DELIVERED');
    await expectResponderStatus('BUSY');
  }, 20000);

  test('location authorization, room isolation, rate limiting, and socket invalidation hold across clients', async () => {
    const locationEmergency = await createEmergency();
    await acceptEmergency(locationEmergency.id);
    await emitAck(sockets.requesterA, 'request.subscribe', { requestId: locationEmergency.id });

    const requesterLocation = waitForEvent(
      sockets.requesterA,
      'responder.location.update',
      (payload) => payload.requestId === locationEmergency.id && payload.latitude === 10.5281
    );
    const requesterBNoLocation = expectNoEvent(
      sockets.requesterB,
      'responder.location.update',
      (payload) => payload.requestId === locationEmergency.id
    );

    await expect(
      emitAck(sockets.responderA, 'responder.location.start', { requestId: locationEmergency.id })
    ).resolves.toMatchObject({ ok: true, requestId: locationEmergency.id });
    await expect(
      emitAck(sockets.responderA, 'responder.location.update', {
        requestId: locationEmergency.id,
        latitude: 10.5281,
        longitude: 76.2151,
      })
    ).resolves.toMatchObject({ ok: true, requestId: locationEmergency.id });
    await requesterLocation;
    await requesterBNoLocation;

    await expect(
      emitAck(sockets.responderB, 'responder.location.update', {
        requestId: locationEmergency.id,
        latitude: 10.52,
        longitude: 76.21,
      })
    ).resolves.toMatchObject({
      ok: false,
      error: expect.objectContaining({ code: 'FORBIDDEN' }),
    });

    await expect(
      emitAck(sockets.responderA, 'responder.location.update', {
        requestId: 99999999,
        latitude: 10.52,
        longitude: 76.21,
      })
    ).resolves.toMatchObject({
      ok: false,
      error: expect.objectContaining({ code: 'FORBIDDEN' }),
    });

    await prisma.emergencyRequest.update({
      where: { id: locationEmergency.id },
      data: { status: 'COMPLETED' },
    });
    await expect(
      emitAck(sockets.responderA, 'responder.location.update', {
        requestId: locationEmergency.id,
        latitude: 10.529,
        longitude: 76.216,
      })
    ).resolves.toMatchObject({
      ok: false,
      error: expect.objectContaining({ code: 'FORBIDDEN' }),
    });

    const cancelledEmergency = await createAcceptedRequestDirect(users.requesterA.id);
    await prisma.emergencyRequest.update({
      where: { id: cancelledEmergency.id },
      data: { status: 'CANCELLED' },
    });
    await expect(
      emitAck(sockets.responderA, 'responder.location.update', {
        requestId: cancelledEmergency.id,
        latitude: 10.529,
        longitude: 76.216,
      })
    ).resolves.toMatchObject({
      ok: false,
      error: expect.objectContaining({ code: 'FORBIDDEN' }),
    });

    const requestA = await createAcceptedRequestDirect(users.requesterA.id, 'Thrissur, Kerala');
    const requestB = await createAcceptedRequestDirect(users.requesterB.id, 'Kochi, Kerala');
    await emitAck(sockets.requesterA, 'request.subscribe', { requestId: requestA.id });
    await emitAck(sockets.requesterB, 'request.subscribe', { requestId: requestB.id });

    await wait(1100);
    const requesterAOwnLocation = waitForEvent(
      sockets.requesterA,
      'responder.location.update',
      (payload) => payload.requestId === requestA.id && payload.latitude === 11.1
    );
    const requesterBNoA = expectNoEvent(
      sockets.requesterB,
      'responder.location.update',
      (payload) => payload.requestId === requestA.id
    );
    await emitAck(sockets.responderA, 'responder.location.update', {
      requestId: requestA.id,
      latitude: 11.1,
      longitude: 76.1,
    });
    await requesterAOwnLocation;
    await requesterBNoA;

    await wait(1100);
    const requesterBOwnLocation = waitForEvent(
      sockets.requesterB,
      'responder.location.update',
      (payload) => payload.requestId === requestB.id && payload.latitude === 12.2
    );
    const requesterANoB = expectNoEvent(
      sockets.requesterA,
      'responder.location.update',
      (payload) => payload.requestId === requestB.id
    );
    await emitAck(sockets.responderA, 'responder.location.update', {
      requestId: requestB.id,
      latitude: 12.2,
      longitude: 77.2,
    });
    await requesterBOwnLocation;
    await requesterANoB;

    await wait(2100);
    await emitAck(sockets.responderA, 'responder.location.update', {
      requestId: requestA.id,
      latitude: 13.1,
      longitude: 78.1,
    });
    await waitForCondition(async () => {
      const responder = await prisma.user.findUnique({
        where: { id: users.responderA.id },
        select: { latitude: true, longitude: true },
      });
      expect(responder.latitude).toBeCloseTo(13.1, 5);
      expect(responder.longitude).toBeCloseTo(78.1, 5);
    });

    await expect(
      emitAck(sockets.responderA, 'responder.location.update', {
        requestId: requestA.id,
        latitude: 13.2,
        longitude: 78.2,
      })
    ).resolves.toMatchObject({ ok: true });
    await expect(
      emitAck(sockets.responderA, 'responder.location.update', {
        requestId: requestA.id,
        latitude: 13.3,
        longitude: 78.3,
      })
    ).resolves.toMatchObject({
      ok: false,
      error: expect.objectContaining({ code: 'RATE_LIMITED' }),
    });
    await wait(250);
    const throttledPersistence = await prisma.user.findUnique({
      where: { id: users.responderA.id },
      select: { latitude: true, longitude: true },
    });
    expect(throttledPersistence.latitude).toBeCloseTo(13.1, 5);
    expect(throttledPersistence.longitude).toBeCloseTo(78.1, 5);

    const invalidated = waitForEvent(sockets.responderB, 'socket.invalidated');
    const disconnected = new Promise((resolve) => sockets.responderB.once('disconnect', resolve));
    await prisma.user.update({
      where: { id: users.responderB.id },
      data: { isActive: false },
    });
    await expect(
      emitAck(sockets.responderB, 'responder.location.update', {
        requestId: requestA.id,
        latitude: 14,
        longitude: 79,
      })
    ).resolves.toMatchObject({
      ok: false,
      error: expect.objectContaining({ code: 'USER_INACTIVE' }),
    });
    await expect(invalidated).resolves.toMatchObject({ code: 'USER_INACTIVE' });
    await disconnected;
  }, 20000);

  test('reconnect followed by REST resynchronization restores state without duplicate socket updates', async () => {
    const emergency = await createEmergency();
    await acceptEmergency(emergency.id);
    const allocation = await createAllocation(emergency.id);
    await patchAllocation(allocation.id, 'DISPATCHED');

    sockets.requesterA.disconnect();
    await patchAllocation(allocation.id, 'DELIVERED');

    sockets.requesterA = await connectSocket(tokens.requesterA);
    const resync = await request(app)
      .get('/api/requests/my')
      .set('Authorization', `Bearer ${tokens.requesterA}`);
    expect(resync.statusCode).toBe(200);
    expect(resync.body.requests).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ id: emergency.id, status: 'COMPLETED' }),
      ])
    );

    const requestA = await createAcceptedRequestDirect(users.requesterA.id, 'Thrissur, Kerala');
    await emitAck(sockets.requesterA, 'request.subscribe', { requestId: requestA.id });

    let updateCount = 0;
    sockets.requesterA.on('responder.location.update', (payload) => {
      if (payload.requestId === requestA.id) updateCount += 1;
    });
    await emitAck(sockets.responderA, 'responder.location.update', {
      requestId: requestA.id,
      latitude: 15.15,
      longitude: 76.76,
    });
    await wait(250);
    expect(updateCount).toBe(1);
  }, 15000);
}
