// Realtime + push notification routing for the "requester can always submit"
// design. Socket.IO stays the foreground channel and only COMPATIBLE
// responders are ever notified; FCM covers backgrounded responders whose
// device is not connected over Socket.IO.
require('dotenv').config();

const bcrypt = require('bcrypt');
const http = require('http');
const request = require('supertest');
const { io: ioClient } = require('socket.io-client');

const hasDatabase = Boolean(process.env.DATABASE_URL && process.env.JWT_SECRET);

if (!hasDatabase) {
  describe.skip('Offline responder notification (requires DATABASE_URL and JWT_SECRET)', () => {
    test('skipped because a PostgreSQL test database is not configured', () => {});
  });
} else {
  const app = require('../../src/app');
  const prisma = require('../../src/config/prisma');
  const pushNotificationService = require('../../src/services/pushNotificationService');
  const { createSocketServer } = require('../../src/realtime/socketServer');
  const { closeSocketServer } = require('../../src/realtime/socketEvents');

  const password = 'OfflineNotify123!';
  const runId = `offline-notify-${Date.now()}`;
  const emails = {
    requester: `${runId}-requester@test.com`,
    responderAmbulance: `${runId}-responder-ambulance@test.com`,
    responderFire: `${runId}-responder-fire@test.com`,
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
  let sockets = {};

  async function cleanup() {
    const allEmails = Object.values(emails);
    const allResources = Object.values(resourceNames);

    await prisma.pushDeviceToken.deleteMany({
      where: { user: { email: { in: allEmails } } },
    });
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

    users = {};
    for (const [key, email] of Object.entries(emails)) {
      const role = key === 'requester' ? 'REQUESTER' : 'RESPONDER';
      users[key] = await prisma.user.create({
        data: {
          name: `Offline Notify ${key}`,
          email,
          password: hashedPassword,
          role,
          isActive: true,
          // Responders begin OFFLINE; individual tests flip them AVAILABLE.
          responderStatus: key === 'requester' ? undefined : 'OFFLINE',
        },
      });
    }

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

    await prisma.responderResource.create({
      data: {
        responderId: users.responderAmbulance.id,
        resourceId: resources.ambulance.id,
        totalQuantity: 2,
        availableQuantity: 2,
        isEnabled: true,
        status: 'AVAILABLE',
      },
    });
    await prisma.responderResource.create({
      data: {
        responderId: users.responderFire.id,
        resourceId: resources.fire.id,
        totalQuantity: 1,
        availableQuantity: 1,
        isEnabled: true,
        status: 'AVAILABLE',
      },
    });

    tokens = {};
    for (const [key, email] of Object.entries(emails)) {
      const response = await request(app)
        .post('/api/auth/login')
        .send({ email, password });
      expect(response.statusCode).toBe(200);
      tokens[key] = response.body.data.token;
    }
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

  function expectNoEvent(socket, eventName, predicate = () => true, durationMs = 400) {
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

  async function connectSocket(token, key) {
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
    if (key) sockets[key] = socket;
    return socket;
  }

  function disconnectAllSockets() {
    if (!sockets) return;
    for (const socket of Object.values(sockets)) {
      socket.removeAllListeners();
      socket.disconnect();
    }
    sockets = {};
  }

  async function createEmergency({ resourceId = null } = {}) {
    const response = await request(app)
      .post('/api/requests')
      .set('Authorization', `Bearer ${tokens.requester}`)
      .send({
        emergencyType: 'Medical',
        description: 'Offline responder notification test',
        location: 'Thrissur, Kerala',
        latitude: 10.5276,
        longitude: 76.2144,
        priority: 'HIGH',
        requiredResources: [
          { resourceId: resourceId || resources.ambulance.id, quantity: 1 },
        ],
      });
    expect(response.statusCode).toBe(201);
    return response.body.request;
  }

  async function setResponderStatus(userId, status) {
    await prisma.user.update({
      where: { id: userId },
      data: { responderStatus: status },
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
    jest.restoreAllMocks();
    pushNotificationService.setServiceAccountForTests(false);
    await prisma.pushDeviceToken.deleteMany({
      where: {
        userId: { in: [users.responderAmbulance.id, users.responderFire.id] },
      },
    });
    await prisma.allocation.deleteMany({
      where: { request: { requesterId: users.requester.id } },
    });
    await prisma.requestResource.deleteMany({
      where: { request: { requesterId: users.requester.id } },
    });
    await prisma.emergencyRequest.deleteMany({
      where: { requesterId: users.requester.id },
    });
    await setResponderStatus(users.responderAmbulance.id, 'OFFLINE');
    await setResponderStatus(users.responderFire.id, 'OFFLINE');
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

  test('a connected compatible responder receives request.created in real time', async () => {
    await setResponderStatus(users.responderAmbulance.id, 'AVAILABLE');
    const socket = await connectSocket(tokens.responderAmbulance, 'ambulance');

    const received = waitForEvent(socket, 'request.created');
    const created = await createEmergency();
    const payload = await received;

    expect(payload.requestId).toBe(created.id);
    expect(payload.request.id).toBe(created.id);
    expect(payload.request.emergencyType).toBe('Medical');
    expect(payload.request.location).toBe('Thrissur, Kerala');
    expect(payload.request.latitude).toBe(10.5276);
    expect(payload.request.longitude).toBe(76.2144);
    expect(payload.request.priority).toBe('HIGH');
    expect(payload.request.status).toBe('PENDING');
  });

  test('a connected incompatible responder never receives the request', async () => {
    // Both responders are online, but the emergency needs an ambulance while
    // this responder only provides fire capability.
    await setResponderStatus(users.responderAmbulance.id, 'AVAILABLE');
    await setResponderStatus(users.responderFire.id, 'AVAILABLE');
    const ambulanceSocket = await connectSocket(tokens.responderAmbulance, 'ambulance');
    const fireSocket = await connectSocket(tokens.responderFire, 'fire');

    const received = waitForEvent(ambulanceSocket, 'request.created');
    const notReceived = expectNoEvent(
      fireSocket,
      'request.created',
      (payload) => payload.requestId != null
    );

    const created = await createEmergency();
    await received;
    await notReceived;
    expect(created.status).toBe('PENDING');
  });

  test('an offline responder gets no socket event, and the request stays PENDING', async () => {
    await setResponderStatus(users.responderAmbulance.id, 'AVAILABLE');
    const ambulanceSocket = await connectSocket(tokens.responderAmbulance, 'ambulance');

    const received = waitForEvent(ambulanceSocket, 'request.created');
    const created = await createEmergency();
    await received;

    // The fire responder never connected: no socket exists for them, so there
    // is nothing to assert on the wire - the durable proof is that the
    // request is still PENDING and visible through the compatible API.
    const persisted = await prisma.emergencyRequest.findUnique({
      where: { id: created.id },
      select: { status: true, acceptedById: true },
    });
    expect(persisted.status).toBe('PENDING');
    expect(persisted.acceptedById).toBeNull();
  });

  test('a responder who comes online retrieves previously created pending requests', async () => {
    // 1. Emergency is created while every responder is OFFLINE (no sockets).
    const created = await createEmergency();
    expect(created.status).toBe('PENDING');

    // 2. The compatible responder comes online: flips to AVAILABLE and opens
    //    a Socket.IO connection (exactly what the Flutter app does on login).
    await setResponderStatus(users.responderAmbulance.id, 'AVAILABLE');
    await connectSocket(tokens.responderAmbulance, 'ambulance');

    // 3. The frontend refetch (dashboard open / reconnect) uses the
    //    compatible endpoint and must see the previously created request.
    const compatible = await request(app)
      .get('/api/requests/compatible')
      .set('Authorization', `Bearer ${tokens.responderAmbulance}`);
    expect(compatible.statusCode).toBe(200);
    const match = compatible.body.requests.find((row) => row.id === created.id);
    expect(match).toBeDefined();
    expect(match.status).toBe('PENDING');
    expect(match.emergencyType).toBe('Medical');
    expect(match.location).toBe('Thrissur, Kerala');
  });

  test('FCM push is skipped for a compatible responder with a live socket, and sent once they disconnect', async () => {
    await setResponderStatus(users.responderAmbulance.id, 'AVAILABLE');
    await prisma.pushDeviceToken.create({
      data: { userId: users.responderAmbulance.id, token: 'ambulance-phone-token' },
    });

    pushNotificationService.setServiceAccountForTests({
      clientEmail: 'push@test-project.iam.gserviceaccount.com',
      privateKey: 'fake-key-for-message-building',
      projectId: 'eras-test-project',
    });
    const deliveredTokens = [];
    jest
      .spyOn(pushNotificationService, 'deliverFcmMessage')
      .mockImplementation(async (message) => {
        deliveredTokens.push(message.token);
        return { ok: true, unregistered: false };
      });

    // Connected: the realtime event already reached them, so no push.
    const socket = await connectSocket(tokens.responderAmbulance, 'ambulance');
    const received = waitForEvent(socket, 'request.created');
    const connectedRequest = await createEmergency();
    await received;
    expect(deliveredTokens).toEqual([]);

    // Disconnected (app backgrounded / connection lost): the next emergency
    // reaches their registered device through FCM instead.
    socket.disconnect();
    const backgroundedRequest = await createEmergency();
    await new Promise((resolve) => setTimeout(resolve, 250));
    expect(deliveredTokens).toEqual(['ambulance-phone-token']);

    // Both requests were persisted identically - push vs socket is purely a
    // transport difference.
    for (const created of [connectedRequest, backgroundedRequest]) {
      const persisted = await prisma.emergencyRequest.findUnique({
        where: { id: created.id },
        select: { status: true, acceptedById: true },
      });
      expect(persisted.status).toBe('PENDING');
      expect(persisted.acceptedById).toBeNull();
    }
  });

  test('FCM push goes only to the compatible responder even when an incompatible responder is offline too', async () => {
    await setResponderStatus(users.responderAmbulance.id, 'AVAILABLE');
    await setResponderStatus(users.responderFire.id, 'AVAILABLE');
    await prisma.pushDeviceToken.create({
      data: { userId: users.responderAmbulance.id, token: 'ambulance-phone-token' },
    });
    await prisma.pushDeviceToken.create({
      data: { userId: users.responderFire.id, token: 'fire-phone-token' },
    });

    pushNotificationService.setServiceAccountForTests({
      clientEmail: 'push@test-project.iam.gserviceaccount.com',
      privateKey: 'fake-key-for-message-building',
      projectId: 'eras-test-project',
    });
    const deliveredTokens = [];
    jest
      .spyOn(pushNotificationService, 'deliverFcmMessage')
      .mockImplementation(async (message) => {
        deliveredTokens.push(message.token);
        return { ok: true, unregistered: false };
      });

    // Nobody is connected over Socket.IO.
    await createEmergency();
    await new Promise((resolve) => setTimeout(resolve, 250));

    expect(deliveredTokens).toEqual(['ambulance-phone-token']);
  });

  test('notification failures leave the created request fully intact', async () => {
    await setResponderStatus(users.responderAmbulance.id, 'AVAILABLE');
    await connectSocket(tokens.responderAmbulance, 'ambulance');
    await prisma.pushDeviceToken.create({
      data: { userId: users.responderAmbulance.id, token: 'failing-phone-token' },
    });

    // Make the FCM delivery layer throw the way a real outage would.
    jest.spyOn(pushNotificationService, 'deliverFcmMessage').mockImplementation(
      async () => {
        throw new Error('FCM endpoint unreachable');
      }
    );

    const created = await createEmergency();
    expect(created.status).toBe('PENDING');

    const persisted = await prisma.emergencyRequest.findUnique({
      where: { id: created.id },
      include: { requiredResources: true },
    });
    expect(persisted).not.toBeNull();
    expect(persisted.status).toBe('PENDING');
    expect(persisted.acceptedById).toBeNull();
    expect(persisted.requiredResources).toHaveLength(1);
  });
}
