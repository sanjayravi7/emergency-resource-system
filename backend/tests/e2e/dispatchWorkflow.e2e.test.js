require('dotenv').config();

const bcrypt = require('bcrypt');
const http = require('http');
const request = require('supertest');
const { io: ioClient } = require('socket.io-client');

const app = require('../../src/app');
const prisma = require('../../src/config/prisma');
const { createSocketServer } = require('../../src/realtime/socketServer');
const { closeSocketServer } = require('../../src/realtime/socketEvents');
const errorHandler = require('../../src/middleware/errorMiddleware');

const hasDatabase = Boolean(process.env.DATABASE_URL && process.env.JWT_SECRET);

(hasDatabase ? describe : describe.skip)(
  'Phase H end-to-end dispatch workflow',
  () => {
    const runId = `phase-h-${Date.now()}`;
    const password = 'PhaseHWorkflow123!';
    let server;
    let serverUrl;
    let users;
    let tokens;
    let resources;
    let capabilities;
    let sockets = [];

    const auth = (token) => ({ Authorization: `Bearer ${token}` });

    function waitForEvent(socket, eventName, predicate = () => true, timeout = 3000) {
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          socket.off(eventName, handler);
          reject(new Error(`Timed out waiting for ${eventName}`));
        }, timeout);
        function handler(payload = {}) {
          if (!predicate(payload)) return;
          clearTimeout(timer);
          socket.off(eventName, handler);
          resolve(payload);
        }
        socket.on(eventName, handler);
      });
    }

    function expectNoEvent(socket, eventName, predicate = () => true, timeout = 250) {
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          socket.off(eventName, handler);
          resolve();
        }, timeout);
        function handler(payload = {}) {
          if (!predicate(payload)) return;
          clearTimeout(timer);
          socket.off(eventName, handler);
          reject(new Error(`Unexpected ${eventName}`));
        }
        socket.on(eventName, handler);
      });
    }

    function emitAck(socket, eventName, payload) {
      return new Promise((resolve) => {
        socket.emit(eventName, payload, (response) => resolve(response));
      });
    }

    async function connect(token) {
      const socket = ioClient(serverUrl, {
        transports: ['websocket'],
        auth: { token },
        forceNew: true,
        reconnection: false,
        autoConnect: false,
      });
      const authenticated = waitForEvent(socket, 'socket.authenticated');
      socket.connect();
      await authenticated;
      sockets.push(socket);
      return socket;
    }

    function disconnectSockets() {
      for (const socket of sockets) {
        socket.removeAllListeners();
        socket.disconnect();
      }
      sockets = [];
    }

    async function createEmergency(lines, options = {}) {
      const body = {
        emergencyType: options.emergencyType || 'Medical and Fire',
        location: options.location || 'Thrissur, Kerala',
        latitude: options.latitude === undefined ? 10.5276 : options.latitude,
        longitude: options.longitude === undefined ? 76.2144 : options.longitude,
        priority: options.priority || 'CRITICAL',
        requiredResources: lines,
      };
      if (Object.prototype.hasOwnProperty.call(options, 'description')) {
        body.description = options.description;
      }
      return request(app)
        .post('/api/requests')
        .set(auth(options.token || tokens.requesterA))
        .send(body);
    }

    const accept = (token, requestId) =>
      request(app)
        .patch(`/api/requests/${requestId}/accept`)
        .set(auth(token));

    const endAssignment = (token, requestId) =>
      request(app)
        .patch(`/api/requests/${requestId}/assignment/end`)
        .set(auth(token));

    const allocate = (token, data) =>
      request(app).post('/api/allocations').set(auth(token)).send(data);

    const updateAllocation = (token, allocationId, status) =>
      request(app)
        .patch(`/api/allocations/${allocationId}/status`)
        .set(auth(token))
        .send({ status });

    const confirmReceipt = (token, allocationId) =>
      request(app)
        .patch(`/api/allocations/${allocationId}/received`)
        .set(auth(token));

    async function acceptAAndB(requestId) {
      expect((await accept(tokens.responderA, requestId)).statusCode).toBe(200);
      expect((await accept(tokens.responderB, requestId)).statusCode).toBe(200);
    }

    async function allocateBlood(requestId, responder = 'responderA', quantity = 2) {
      const key = responder === 'responderA' ? 'bloodA' : 'bloodD';
      return allocate(tokens[responder], {
        requestId,
        responderResourceId: capabilities[key].id,
        resourceId: resources.blood.id,
        quantity,
      });
    }

    async function allocateFire(requestId) {
      return allocate(tokens.responderB, {
        requestId,
        responderResourceId: capabilities.fireB.id,
        resourceId: resources.fire.id,
        quantity: 1,
      });
    }

    async function cleanRequests() {
      if (!users) return;
      const requesterIds = [users.requesterA.id, users.requesterB.id];
      await prisma.allocation.deleteMany({
        where: { request: { requesterId: { in: requesterIds } } },
      });
      await prisma.emergencyRequest.deleteMany({
        where: { requesterId: { in: requesterIds } },
      });
    }

    beforeAll(async () => {
      const hash = await bcrypt.hash(password, 10);
      const definitions = {
        requesterA: ['Phase H Requester A', 'REQUESTER'],
        requesterB: ['Phase H Requester B', 'REQUESTER'],
        responderA: ['Phase H Blood A', 'RESPONDER'],
        responderB: ['Phase H Fire B', 'RESPONDER'],
        responderC: ['Phase H Unrelated C', 'RESPONDER'],
        responderD: ['Phase H Blood D', 'RESPONDER'],
        admin: ['Phase H Admin', 'ADMIN'],
      };
      users = {};
      for (const [key, [name, role]] of Object.entries(definitions)) {
        users[key] = await prisma.user.create({
          data: {
            name,
            email: `${runId}-${key.toLowerCase()}@test.com`,
            password: hash,
            role,
            isActive: true,
            responderStatus: role === 'RESPONDER' ? 'AVAILABLE' : 'OFFLINE',
          },
        });
      }

      resources = {
        blood: await prisma.resource.create({
          data: {
            name: `${runId} Blood`,
            type: 'Medical',
            mode: 'CONSUMABLE',
            totalQuantity: 100,
            availableQuantity: 100,
            unit: 'unit',
          },
        }),
        fire: await prisma.resource.create({
          data: {
            name: `${runId} Fire Service`,
            type: 'Fire',
            mode: 'SERVICE',
            totalQuantity: 0,
            availableQuantity: 0,
          },
        }),
        unrelated: await prisma.resource.create({
          data: {
            name: `${runId} Rescue Boat`,
            type: 'Rescue',
            mode: 'SERVICE',
            totalQuantity: 0,
            availableQuantity: 0,
          },
        }),
      };

      capabilities = {
        bloodA: await prisma.responderResource.create({
          data: {
            responderId: users.responderA.id,
            resourceId: resources.blood.id,
            totalQuantity: 20,
            availableQuantity: 20,
            isEnabled: true,
            status: 'AVAILABLE',
          },
        }),
        fireB: await prisma.responderResource.create({
          data: {
            responderId: users.responderB.id,
            resourceId: resources.fire.id,
            totalQuantity: 0,
            availableQuantity: 0,
            isEnabled: true,
            status: 'UNAVAILABLE',
          },
        }),
        unrelatedC: await prisma.responderResource.create({
          data: {
            responderId: users.responderC.id,
            resourceId: resources.unrelated.id,
            totalQuantity: 0,
            availableQuantity: 0,
            isEnabled: true,
            status: 'UNAVAILABLE',
          },
        }),
        bloodD: await prisma.responderResource.create({
          data: {
            responderId: users.responderD.id,
            resourceId: resources.blood.id,
            totalQuantity: 20,
            availableQuantity: 20,
            isEnabled: true,
            status: 'AVAILABLE',
          },
        }),
      };

      tokens = {};
      for (const [key, user] of Object.entries(users)) {
        const response = await request(app)
          .post('/api/auth/login')
          .send({ email: user.email, password });
        expect(response.statusCode).toBe(200);
        tokens[key] = response.body.data.token;
      }

      server = http.createServer(app);
      createSocketServer(server);
      await new Promise((resolve) => {
        server.listen(0, '127.0.0.1', () => {
          serverUrl = `http://127.0.0.1:${server.address().port}`;
          resolve();
        });
      });
    }, 30000);

    beforeEach(async () => {
      disconnectSockets();
      await cleanRequests();
      await prisma.user.updateMany({
        where: {
          id: {
            in: [
              users.responderA.id,
              users.responderB.id,
              users.responderC.id,
              users.responderD.id,
            ],
          },
        },
        data: {
          isActive: true,
          responderStatus: 'AVAILABLE',
          latitude: null,
          longitude: null,
        },
      });
      await prisma.responderResource.update({
        where: { id: capabilities.bloodA.id },
        data: { availableQuantity: 20, status: 'AVAILABLE', isEnabled: true },
      });
      await prisma.responderResource.update({
        where: { id: capabilities.bloodD.id },
        data: { availableQuantity: 20, status: 'AVAILABLE', isEnabled: true },
      });
    });

    afterEach(() => disconnectSockets());

    afterAll(async () => {
      disconnectSockets();
      await closeSocketServer();
      if (server) await new Promise((resolve) => server.close(resolve));
      await cleanRequests();
      await prisma.responderResource.deleteMany({
        where: { id: { in: Object.values(capabilities).map((row) => row.id) } },
      });
      await prisma.resource.deleteMany({
        where: { id: { in: Object.values(resources).map((row) => row.id) } },
      });
      await prisma.user.deleteMany({
        where: { id: { in: Object.values(users).map((user) => user.id) } },
      });
      await prisma.$disconnect();
    }, 30000);

    test('scenario 1: single responder request completes through requester receipt', async () => {
      const created = await createEmergency([
        { resourceId: resources.blood.id, quantity: 1 },
      ], { description: null });
      expect(created.statusCode).toBe(201);
      const emergency = created.body.request;
      expect(emergency.description).toBeNull();

      expect((await accept(tokens.responderA, emergency.id)).statusCode).toBe(200);
      const allocation = await allocateBlood(emergency.id, 'responderA', 1);
      expect(allocation.statusCode).toBe(201);
      expect(
        (await updateAllocation(
          tokens.responderA,
          allocation.body.allocation.id,
          'DISPATCHED'
        )).statusCode
      ).toBe(200);
      expect(
        (await confirmReceipt(tokens.requesterA, allocation.body.allocation.id))
          .statusCode
      ).toBe(200);

      const stored = await prisma.emergencyRequest.findUnique({
        where: { id: emergency.id },
        include: { assignments: true },
      });
      expect(stored.status).toBe('COMPLETED');
      expect(stored.acceptedById).toBe(users.responderA.id);
      expect(stored.assignments).toHaveLength(1);
      expect(stored.assignments[0]).toMatchObject({ status: 'ENDED' });
      expect(stored.assignments[0].endedAt).not.toBeNull();
    });

    test('scenario 2/3: compatible notifications, multi-acceptance, allocation, locations, and completion stay isolated', async () => {
      const requesterSocket = await connect(tokens.requesterA);
      const responderASocket = await connect(tokens.responderA);
      const responderBSocket = await connect(tokens.responderB);
      const responderCSocket = await connect(tokens.responderC);
      const adminSocket = await connect(tokens.admin);

      const createdForA = waitForEvent(
        responderASocket,
        'request.created',
        (payload) => payload.emergencyType === 'Medical and Fire'
      );
      const createdForB = waitForEvent(
        responderBSocket,
        'request.created',
        (payload) => payload.emergencyType === 'Medical and Fire'
      );
      const notCreatedForC = expectNoEvent(
        responderCSocket,
        'request.created',
        (payload) => payload.emergencyType === 'Medical and Fire'
      );
      const created = await createEmergency([
        { resourceId: resources.blood.id, quantity: 2 },
        { resourceId: resources.fire.id, quantity: 1 },
      ]);
      expect(created.statusCode).toBe(201);
      const emergency = created.body.request;
      expect((await createdForA).requestId).toBe(emergency.id);
      expect((await createdForB).requestId).toBe(emergency.id);
      await notCreatedForC;

      const compatibleA = await request(app)
        .get('/api/requests/compatible')
        .set(auth(tokens.responderA));
      const compatibleB = await request(app)
        .get('/api/requests/compatible')
        .set(auth(tokens.responderB));
      const compatibleC = await request(app)
        .get('/api/requests/compatible')
        .set(auth(tokens.responderC));
      expect(compatibleA.body.requests.map((row) => row.id)).toContain(emergency.id);
      expect(compatibleB.body.requests.map((row) => row.id)).toContain(emergency.id);
      expect(compatibleC.body.requests.map((row) => row.id)).not.toContain(emergency.id);

      expect((await accept(tokens.responderA, emergency.id)).statusCode).toBe(200);
      // An ACCEPTED request with outstanding Fire work remains joinable by B.
      const afterLead = await request(app)
        .get('/api/requests/compatible')
        .set(auth(tokens.responderB));
      expect(afterLead.body.requests.find((row) => row.id === emergency.id).status)
        .toBe('ACCEPTED');
      expect((await accept(tokens.responderB, emergency.id)).statusCode).toBe(200);
      expect((await accept(tokens.responderC, emergency.id)).statusCode).toBe(400);

      await emitAck(requesterSocket, 'request.subscribe', { requestId: emergency.id });
      const allocationAudience = [requesterSocket, responderASocket, responderBSocket, adminSocket]
        .map((socket) => waitForEvent(
          socket,
          'allocation.updated',
          (payload) => payload.requestId === emergency.id &&
            payload.responderId === users.responderA.id
        ));
      const bloodAllocation = await allocateBlood(emergency.id);
      expect(bloodAllocation.statusCode).toBe(201);
      await Promise.all(allocationAudience);
      const fireAllocation = await allocateFire(emergency.id);
      expect(fireAllocation.statusCode).toBe(201);

      const snapshot = await prisma.emergencyRequest.findUnique({
        where: { id: emergency.id },
        include: { assignments: true, allocations: true },
      });
      expect(snapshot.acceptedById).toBe(users.responderA.id);
      expect(snapshot.assignments.map((row) => row.responderId).sort((a, b) => a - b))
        .toEqual([users.responderA.id, users.responderB.id].sort((a, b) => a - b));
      expect(snapshot.allocations).toEqual(
        expect.arrayContaining([
          expect.objectContaining({ responderId: users.responderA.id, quantity: 2 }),
          expect.objectContaining({ responderId: users.responderB.id, quantity: 1 }),
        ])
      );
      expect(snapshot.status).toBe('IN_PROGRESS');

      const [bloodInventory, fireInventory] = await Promise.all([
        prisma.responderResource.findUnique({ where: { id: capabilities.bloodA.id } }),
        prisma.responderResource.findUnique({ where: { id: capabilities.fireB.id } }),
      ]);
      expect(bloodInventory.availableQuantity).toBe(18);
      expect(fireInventory.availableQuantity).toBe(0);
      expect(fireInventory.totalQuantity).toBe(0);

      await emitAck(responderASocket, 'responder.location.start', { requestId: emergency.id });
      await emitAck(responderBSocket, 'responder.location.start', { requestId: emergency.id });
      const locationA = waitForEvent(
        requesterSocket,
        'responder.location.update',
        (payload) => payload.requestId === emergency.id &&
          payload.responderId === users.responderA.id
      );
      const locationB = waitForEvent(
        requesterSocket,
        'responder.location.update',
        (payload) => payload.requestId === emergency.id &&
          payload.responderId === users.responderB.id
      );
      await emitAck(responderASocket, 'responder.location.update', {
        requestId: emergency.id,
        responderId: users.responderB.id,
        latitude: 10.53,
        longitude: 76.22,
      });
      await emitAck(responderBSocket, 'responder.location.update', {
        requestId: emergency.id,
        latitude: 10.54,
        longitude: 76.23,
      });
      expect((await locationA).latitude).toBe(10.53);
      expect((await locationB).latitude).toBe(10.54);

      const stoppedB = waitForEvent(
        requesterSocket,
        'responder.location.stop',
        (payload) => payload.requestId === emergency.id &&
          payload.responderId === users.responderB.id
      );
      await emitAck(responderBSocket, 'responder.location.stop', {
        requestId: emergency.id,
      });
      await stoppedB;
      // B stopping does not revoke A's independent stream.
      expect(
        (await emitAck(responderASocket, 'responder.location.update', {
          requestId: emergency.id,
          latitude: 10.531,
          longitude: 76.221,
        })).ok
      ).toBe(true);

      for (const [token, allocationId] of [
        [tokens.responderA, bloodAllocation.body.allocation.id],
        [tokens.responderB, fireAllocation.body.allocation.id],
      ]) {
        expect((await updateAllocation(token, allocationId, 'DISPATCHED')).statusCode)
          .toBe(200);
      }
      const finalRequesterUpdate = waitForEvent(
        requesterSocket,
        'request.updated',
        (payload) => payload.requestId === emergency.id && payload.status === 'COMPLETED'
      );
      const finalAUpdate = waitForEvent(
        responderASocket,
        'request.updated',
        (payload) => payload.requestId === emergency.id && payload.status === 'COMPLETED'
      );
      const finalBUpdate = waitForEvent(
        responderBSocket,
        'request.updated',
        (payload) => payload.requestId === emergency.id && payload.status === 'COMPLETED'
      );
      expect((await confirmReceipt(tokens.requesterA, bloodAllocation.body.allocation.id)).statusCode)
        .toBe(200);
      expect((await confirmReceipt(tokens.requesterA, fireAllocation.body.allocation.id)).statusCode)
        .toBe(200);
      await Promise.all([finalRequesterUpdate, finalAUpdate, finalBUpdate]);

      const terminal = await prisma.emergencyRequest.findUnique({
        where: { id: emergency.id },
        include: { assignments: true },
      });
      expect(terminal.status).toBe('COMPLETED');
      expect(terminal.acceptedById).toBe(users.responderA.id);
      expect(terminal.assignments.every((row) => row.status === 'ENDED' && row.endedAt))
        .toBe(true);
    }, 20000);

    test('scenario 4: allocation-only responder retains the complete allocation lifecycle', async () => {
      const created = await createEmergency([
        { resourceId: resources.blood.id, quantity: 2 },
      ]);
      const emergency = created.body.request;
      const allocation = await allocateBlood(emergency.id, 'responderD', 2);
      expect(allocation.statusCode).toBe(201);

      const assigned = await request(app)
        .get('/api/requests/assigned')
        .set(auth(tokens.responderD));
      expect(assigned.body.requests.map((row) => row.id)).toContain(emergency.id);
      expect(assigned.body.requests[0].assignments).toEqual([]);

      const responderSocket = await connect(tokens.responderD);
      expect(
        (await emitAck(responderSocket, 'request.subscribe', { requestId: emergency.id })).ok
      ).toBe(true);
      expect(
        (await emitAck(responderSocket, 'responder.location.start', { requestId: emergency.id })).ok
      ).toBe(true);
      expect(
        (await updateAllocation(
          tokens.responderD,
          allocation.body.allocation.id,
          'DISPATCHED'
        )).statusCode
      ).toBe(200);
      expect(
        (await updateAllocation(
          tokens.responderD,
          allocation.body.allocation.id,
          'DELIVERED'
        )).statusCode
      ).toBe(200);
      const stored = await prisma.emergencyRequest.findUnique({ where: { id: emergency.id } });
      expect(stored.status).toBe('COMPLETED');
    });

    test('scenario 5: ending A stops only A while B remains assigned and BUSY', async () => {
      const emergency = (await createEmergency([
        { resourceId: resources.blood.id, quantity: 2 },
        { resourceId: resources.fire.id, quantity: 1 },
      ])).body.request;
      await acceptAAndB(emergency.id);
      const requesterSocket = await connect(tokens.requesterA);
      const aSocket = await connect(tokens.responderA);
      const bSocket = await connect(tokens.responderB);
      await emitAck(requesterSocket, 'request.subscribe', { requestId: emergency.id });
      await emitAck(aSocket, 'responder.location.start', { requestId: emergency.id });
      await emitAck(bSocket, 'responder.location.start', { requestId: emergency.id });

      const stopA = waitForEvent(
        requesterSocket,
        'responder.location.stop',
        (payload) => payload.requestId === emergency.id &&
          payload.responderId === users.responderA.id
      );
      expect((await endAssignment(tokens.responderA, emergency.id)).statusCode).toBe(200);
      await stopA;

      const rows = await prisma.responderAssignment.findMany({
        where: { requestId: emergency.id },
      });
      expect(rows.find((row) => row.responderId === users.responderA.id).status)
        .toBe('ENDED');
      expect(rows.find((row) => row.responderId === users.responderB.id).status)
        .toBe('ACTIVE');
      const stored = await prisma.emergencyRequest.findUnique({
        where: { id: emergency.id },
        include: { acceptedBy: true },
      });
      expect(stored.acceptedById).toBe(users.responderA.id);
      const statuses = await prisma.user.findMany({
        where: { id: { in: [users.responderA.id, users.responderB.id] } },
        select: { id: true, responderStatus: true },
      });
      expect(statuses.find((row) => row.id === users.responderA.id).responderStatus)
        .toBe('AVAILABLE');
      expect(statuses.find((row) => row.id === users.responderB.id).responderStatus)
        .toBe('BUSY');
      expect(
        (await emitAck(aSocket, 'responder.location.update', {
          requestId: emergency.id,
          latitude: 10.55,
          longitude: 76.25,
        })).ok
      ).toBe(false);
      expect(
        (await emitAck(bSocket, 'responder.location.update', {
          requestId: emergency.id,
          latitude: 10.56,
          longitude: 76.26,
        })).ok
      ).toBe(true);
    });

    test('scenario 6: ended responder sees outstanding work and rejoins using the same row', async () => {
      const emergency = (await createEmergency([
        { resourceId: resources.blood.id, quantity: 2 },
        { resourceId: resources.fire.id, quantity: 1 },
      ])).body.request;
      await acceptAAndB(emergency.id);
      const original = await prisma.responderAssignment.findUnique({
        where: {
          requestId_responderId: {
            requestId: emergency.id,
            responderId: users.responderA.id,
          },
        },
      });
      await endAssignment(tokens.responderA, emergency.id);
      const compatible = await request(app)
        .get('/api/requests/compatible')
        .set(auth(tokens.responderA));
      expect(compatible.body.requests.map((row) => row.id)).toContain(emergency.id);
      expect((await accept(tokens.responderA, emergency.id)).statusCode).toBe(200);
      const rows = await prisma.responderAssignment.findMany({
        where: { requestId: emergency.id, responderId: users.responderA.id },
      });
      expect(rows).toHaveLength(1);
      expect(rows[0]).toMatchObject({ id: original.id, status: 'ACTIVE', endedAt: null });
    });

    test('scenario 7: requester cancellation cleans assignments, allocations, inventory, and availability', async () => {
      const emergency = (await createEmergency([
        { resourceId: resources.blood.id, quantity: 2 },
        { resourceId: resources.fire.id, quantity: 1 },
      ])).body.request;
      await acceptAAndB(emergency.id);
      const blood = await allocateBlood(emergency.id);
      const fire = await allocateFire(emergency.id);
      await updateAllocation(tokens.responderA, blood.body.allocation.id, 'DISPATCHED');

      const cancelled = await request(app)
        .patch(`/api/requests/${emergency.id}/cancel`)
        .set(auth(tokens.requesterA));
      expect(cancelled.statusCode).toBe(200);
      expect(cancelled.body.request.status).toBe('CANCELLED');

      const [assignments, allocations, bloodInventory, responders] = await Promise.all([
        prisma.responderAssignment.findMany({ where: { requestId: emergency.id } }),
        prisma.allocation.findMany({ where: { requestId: emergency.id } }),
        prisma.responderResource.findUnique({ where: { id: capabilities.bloodA.id } }),
        prisma.user.findMany({
          where: { id: { in: [users.responderA.id, users.responderB.id] } },
          select: { responderStatus: true },
        }),
      ]);
      expect(assignments.every((row) => row.status === 'ENDED' && row.endedAt)).toBe(true);
      expect(allocations.every((row) => row.status === 'CANCELLED')).toBe(true);
      expect(bloodInventory.availableQuantity).toBe(20);
      expect(responders.every((row) => row.responderStatus === 'AVAILABLE')).toBe(true);
      expect(fire.statusCode).toBe(201);
    });

    test('scenario 8: completion stops an assignment-only third responder too', async () => {
      const emergency = (await createEmergency([
        { resourceId: resources.blood.id, quantity: 2 },
        { resourceId: resources.fire.id, quantity: 1 },
      ])).body.request;
      await acceptAAndB(emergency.id);
      expect((await accept(tokens.responderD, emergency.id)).statusCode).toBe(200);

      const requesterSocket = await connect(tokens.requesterA);
      const dSocket = await connect(tokens.responderD);
      await emitAck(requesterSocket, 'request.subscribe', { requestId: emergency.id });
      await emitAck(dSocket, 'responder.location.start', { requestId: emergency.id });
      const stopD = waitForEvent(
        requesterSocket,
        'responder.location.stop',
        (payload) => payload.requestId === emergency.id &&
          payload.responderId === users.responderD.id
      );

      const blood = await allocateBlood(emergency.id);
      const fire = await allocateFire(emergency.id);
      await updateAllocation(tokens.responderA, blood.body.allocation.id, 'DISPATCHED');
      await updateAllocation(tokens.responderB, fire.body.allocation.id, 'DISPATCHED');
      await confirmReceipt(tokens.requesterA, blood.body.allocation.id);
      await confirmReceipt(tokens.requesterA, fire.body.allocation.id);
      await stopD;

      const assignments = await prisma.responderAssignment.findMany({
        where: { requestId: emergency.id },
      });
      expect(assignments).toHaveLength(3);
      expect(assignments.every((row) => row.status === 'ENDED' && row.endedAt)).toBe(true);
      expect(
        (await accept(tokens.responderD, emergency.id)).body.message
      ).toBe('Request has already been completed');
    });

    test('scenario 9: disconnect, missed allocation, reconnect, and REST resync are idempotent', async () => {
      const emergency = (await createEmergency([
        { resourceId: resources.blood.id, quantity: 2 },
        { resourceId: resources.fire.id, quantity: 1 },
      ])).body.request;
      await acceptAAndB(emergency.id);
      let bSocket = await connect(tokens.responderB);
      await emitAck(bSocket, 'responder.location.start', { requestId: emergency.id });
      await emitAck(bSocket, 'responder.location.update', {
        requestId: emergency.id,
        latitude: 10.6,
        longitude: 76.3,
      });
      bSocket.disconnect();

      const blood = await allocateBlood(emergency.id);
      expect(blood.statusCode).toBe(201);
      bSocket = await connect(tokens.responderB);
      expect(bSocket.connected).toBe(true);

      const first = await request(app)
        .get('/api/requests/assigned')
        .set(auth(tokens.responderB));
      const second = await request(app)
        .get('/api/requests/assigned')
        .set(auth(tokens.responderB));
      for (const response of [first, second]) {
        expect(response.statusCode).toBe(200);
        expect(response.body.requests.filter((row) => row.id === emergency.id)).toHaveLength(1);
        const row = response.body.requests.find((item) => item.id === emergency.id);
        expect(row.assignments.filter(
          (assignment) => assignment.responderId === users.responderB.id
        )).toHaveLength(1);
        expect(row.allocations.filter(
          (allocation) => allocation.id === blood.body.allocation.id
        )).toHaveLength(1);
      }
      expect(
        await prisma.responderAssignment.count({ where: { requestId: emergency.id } })
      ).toBe(2);
      expect(await prisma.allocation.count({ where: { requestId: emergency.id } }))
        .toBe(1);
    });

    test('scenario 10: concurrent final receipts complete once with no duplicate rows', async () => {
      const emergency = (await createEmergency([
        { resourceId: resources.blood.id, quantity: 2 },
        { resourceId: resources.fire.id, quantity: 1 },
      ])).body.request;
      await acceptAAndB(emergency.id);
      const blood = await allocateBlood(emergency.id);
      const fire = await allocateFire(emergency.id);
      await updateAllocation(tokens.responderA, blood.body.allocation.id, 'DISPATCHED');
      await updateAllocation(tokens.responderB, fire.body.allocation.id, 'DISPATCHED');

      const results = await Promise.all([
        confirmReceipt(tokens.requesterA, blood.body.allocation.id),
        confirmReceipt(tokens.requesterA, fire.body.allocation.id),
      ]);
      expect(results.map((response) => response.statusCode)).toEqual([200, 200]);
      const stored = await prisma.emergencyRequest.findUnique({
        where: { id: emergency.id },
        include: { assignments: true, allocations: true },
      });
      expect(stored.status).toBe('COMPLETED');
      expect(stored.assignments).toHaveLength(2);
      expect(stored.allocations).toHaveLength(2);
      expect(stored.assignments.every((row) => row.status === 'ENDED')).toBe(true);
    });

    test('scenario 11: concurrent assignment end/rejoin never creates a second row', async () => {
      const emergency = (await createEmergency([
        { resourceId: resources.blood.id, quantity: 2 },
        { resourceId: resources.fire.id, quantity: 1 },
      ])).body.request;
      await acceptAAndB(emergency.id);
      const original = await prisma.responderAssignment.findUnique({
        where: {
          requestId_responderId: {
            requestId: emergency.id,
            responderId: users.responderA.id,
          },
        },
      });

      const race = await Promise.all([
        endAssignment(tokens.responderA, emergency.id),
        accept(tokens.responderA, emergency.id),
      ]);
      expect(race.some((response) => response.statusCode === 200)).toBe(true);
      let rows = await prisma.responderAssignment.findMany({
        where: { requestId: emergency.id, responderId: users.responderA.id },
      });
      expect(rows).toHaveLength(1);
      expect(rows[0].id).toBe(original.id);
      if (rows[0].status === 'ENDED') {
        expect((await accept(tokens.responderA, emergency.id)).statusCode).toBe(200);
      }
      rows = await prisma.responderAssignment.findMany({
        where: { requestId: emergency.id, responderId: users.responderA.id },
      });
      expect(rows).toHaveLength(1);
      expect(rows[0]).toMatchObject({ id: original.id, status: 'ACTIVE', endedAt: null });
    });

    test('scenario 12: REST and Socket.IO IDOR attempts are denied independently', async () => {
      const emergency = (await createEmergency([
        { resourceId: resources.blood.id, quantity: 1 },
      ])).body.request;
      await accept(tokens.responderA, emergency.id);
      const allocation = await allocateBlood(emergency.id, 'responderA', 1);

      const unrelatedOverview = await request(app)
        .get('/api/requests')
        .set(auth(tokens.responderC));
      expect(unrelatedOverview.statusCode).toBe(200);
      expect(unrelatedOverview.body.requests.map((row) => row.id)).not.toContain(emergency.id);
      const requesterBOverview = await request(app)
        .get('/api/requests/my')
        .set(auth(tokens.requesterB));
      expect(requesterBOverview.body.requests.map((row) => row.id)).not.toContain(emergency.id);
      expect(
        (await updateAllocation(
          tokens.responderC,
          allocation.body.allocation.id,
          'CANCELLED'
        )).statusCode
      ).toBe(500);
      expect(
        (await endAssignment(tokens.requesterA, emergency.id)).statusCode
      ).toBe(403);

      const unrelatedSocket = await connect(tokens.responderC);
      expect(
        (await emitAck(unrelatedSocket, 'request.subscribe', { requestId: emergency.id }))
          .ok
      ).toBe(false);
      expect(
        (await emitAck(unrelatedSocket, 'responder.location.update', {
          requestId: emergency.id,
          responderId: users.responderA.id,
          latitude: 10.7,
          longitude: 76.4,
        })).ok
      ).toBe(false);

      const aSocket = await connect(tokens.responderA);
      const requesterSocket = await connect(tokens.requesterA);
      await emitAck(requesterSocket, 'request.subscribe', { requestId: emergency.id });
      const actualIdentity = waitForEvent(
        requesterSocket,
        'responder.location.update',
        (payload) => payload.requestId === emergency.id
      );
      await emitAck(aSocket, 'responder.location.update', {
        requestId: emergency.id,
        responderId: users.responderB.id,
        latitude: 10.71,
        longitude: 76.41,
      });
      expect((await actualIdentity).responderId).toBe(users.responderA.id);
    });

    test('edge matrix: optional descriptions, invalid input, inactive account, safe duplicates, and admin contract', async () => {
      for (const description of [undefined, null, '   ']) {
        const options = description === undefined ? {} : { description };
        const response = await createEmergency([
          { resourceId: resources.blood.id, quantity: 1 },
        ], options);
        expect(response.statusCode).toBe(201);
        expect(response.body.request.description).toBeNull();
      }
      const invalidLocation = await createEmergency([
        { resourceId: resources.blood.id, quantity: 1 },
      ], { latitude: 100, longitude: 76 });
      expect(invalidLocation.statusCode).toBe(400);

      const emergency = (await createEmergency([
        { resourceId: resources.blood.id, quantity: 1 },
      ], { description: 'Admin payload check' })).body.request;
      await accept(tokens.responderA, emergency.id);
      const allocation = await allocateBlood(emergency.id, 'responderA', 1);
      const duplicateAllocation = await allocateBlood(emergency.id, 'responderD', 1);
      expect(duplicateAllocation.statusCode).toBe(500);
      await updateAllocation(tokens.responderA, allocation.body.allocation.id, 'DISPATCHED');
      await confirmReceipt(tokens.requesterA, allocation.body.allocation.id);
      const duplicateReceipt = await confirmReceipt(
        tokens.requesterA,
        allocation.body.allocation.id
      );
      expect(duplicateReceipt.statusCode).toBe(500);
      expect(duplicateReceipt.body.message).toBe('Receipt has already been confirmed');

      const admin = await request(app)
        .get('/api/admin/requests')
        .set(auth(tokens.admin));
      const adminRow = admin.body.requests.find((row) => row.id === emergency.id);
      expect(adminRow.assignments).toHaveLength(1);
      expect(adminRow.allocations).toHaveLength(1);
      expect(adminRow.requiredResources).toHaveLength(1);

      // Admin cancellation must use the same cleanup path as requester
      // cancellation rather than stranding inventory or unfinished rows.
      const adminCancellationTarget = (await createEmergency([
        { resourceId: resources.blood.id, quantity: 1 },
      ], { description: 'Admin cancellation cleanup' })).body.request;
      await accept(tokens.responderA, adminCancellationTarget.id);
      const adminAllocation = await allocateBlood(
        adminCancellationTarget.id,
        'responderA',
        1
      );
      const forcedCompletion = await request(app)
        .patch(`/api/admin/requests/${adminCancellationTarget.id}/status`)
        .set(auth(tokens.admin))
        .send({ status: 'COMPLETED' });
      expect(forcedCompletion.statusCode).toBe(200);
      expect(forcedCompletion.body.request.status).toBe('COMPLETED');
      expect(
        (await prisma.allocation.findUnique({
          where: { id: adminAllocation.body.allocation.id },
        })).status
      ).toBe('CANCELLED');
      expect(
        (await prisma.responderResource.findUnique({
          where: { id: capabilities.bloodA.id },
        })).availableQuantity
      ).toBe(19);

      const cancellationTarget = (await createEmergency([
        { resourceId: resources.blood.id, quantity: 1 },
      ], { description: 'Admin cancellation cleanup' })).body.request;
      await accept(tokens.responderA, cancellationTarget.id);
      const cancellationAllocation = await allocateBlood(
        cancellationTarget.id,
        'responderA',
        1
      );
      const adminCancelled = await request(app)
        .patch(`/api/admin/requests/${cancellationTarget.id}/status`)
        .set(auth(tokens.admin))
        .send({ status: 'CANCELLED' });
      expect(adminCancelled.statusCode).toBe(200);
      expect(adminCancelled.body.request.status).toBe('CANCELLED');
      expect(
        (await prisma.allocation.findUnique({
          where: { id: cancellationAllocation.body.allocation.id },
        })).status
      ).toBe('CANCELLED');
      expect(
        (await prisma.responderResource.findUnique({
          where: { id: capabilities.bloodA.id },
        })).availableQuantity
      ).toBe(19);

      await prisma.user.update({
        where: { id: users.responderC.id },
        data: { isActive: false },
      });
      const inactive = await request(app)
        .get('/api/requests/compatible')
        .set(auth(tokens.responderC));
      expect(inactive.statusCode).toBe(401);
      // The server remains healthy after expected conflicts.
      expect(
        (await request(app)
          .get('/api/requests/my')
          .set(auth(tokens.requesterA))).statusCode
      ).toBe(200);
    });

    test('error boundary sanitizes Prisma details and logs expected conflicts without stacks', () => {
      const prismaLog = jest.spyOn(console, 'error').mockImplementation(() => {});
      const conflictLog = jest.spyOn(console, 'warn').mockImplementation(() => {});
      const response = {
        statusCode: 0,
        body: null,
        status(code) {
          this.statusCode = code;
          return this;
        },
        json(body) {
          this.body = body;
          return this;
        },
      };
      const prismaError = Object.assign(
        new Error('Invalid `prisma.user.findMany()` invocation with secret SQL'),
        { code: 'P2025', name: 'PrismaClientKnownRequestError' }
      );
      errorHandler(prismaError, {}, response, () => {});
      expect(response).toMatchObject({
        statusCode: 500,
        body: { success: false, message: 'Database operation failed' },
      });
      expect(prismaLog).toHaveBeenCalledWith('Database operation failed (P2025)');
      expect(JSON.stringify(prismaLog.mock.calls)).not.toContain('secret SQL');

      errorHandler(new Error('Receipt has already been confirmed'), {}, response, () => {});
      expect(conflictLog).toHaveBeenCalledWith(
        'Business conflict: Receipt has already been confirmed'
      );
      expect(JSON.stringify(conflictLog.mock.calls)).not.toContain('\n    at ');
      prismaLog.mockRestore();
      conflictLog.mockRestore();
    });
  }
);
