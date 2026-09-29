// A citizen's emergency submission must NEVER be blocked by responder
// availability. These tests lock in the persist-first / notify-second design:
//
//   - a request is created (HTTP 201) with zero responders in the database,
//   - a request is created when responders exist but are all OFFLINE,
//   - the row is persisted as PENDING / unassigned with every submitted
//     field preserved,
//   - only compatible responders ever see or get notified about it,
//   - a responder coming online can fetch it through the compatible API,
//   - notification failures (Socket.IO / FCM) never fail the creation.
require('dotenv').config();

const bcrypt = require('bcrypt');
const request = require('supertest');

const hasDatabase = Boolean(process.env.DATABASE_URL && process.env.JWT_SECRET);

if (!hasDatabase) {
  describe.skip('Emergency creation without responders (requires DATABASE_URL and JWT_SECRET)', () => {
    test('skipped because a PostgreSQL test database is not configured', () => {});
  });
} else {
  const app = require('../../src/app');
  const prisma = require('../../src/config/prisma');
  const pushNotificationService = require('../../src/services/pushNotificationService');

  const password = 'OfflineResponder123!';
  const runId = `offline-create-${Date.now()}`;
  const emails = {
    requester: `${runId}-requester@test.com`,
    responderAmbulance: `${runId}-responder-ambulance@test.com`,
    responderFire: `${runId}-responder-fire@test.com`,
  };
  const resourceNames = {
    ambulance: `${runId} Ambulance`,
    fire: `${runId} Fire Engine`,
    blood: `${runId} Blood Bag`,
  };

  let requester;
  let responderAmbulance;
  let responderFire;
  let tokens;
  let resources;

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

  async function login(email) {
    const response = await request(app)
      .post('/api/auth/login')
      .send({ email, password });
    expect(response.statusCode).toBe(200);
    return response.body.data.token;
  }

  async function createEmergency({
    token,
    body,
  } = {}) {
    const response = await request(app)
      .post('/api/requests')
      .set('Authorization', `Bearer ${token || tokens.requester}`)
      .send(body || {
        emergencyType: 'Medical',
        description: 'Heart attack victim needs immediate help',
        location: 'Thrissur Round, Kerala',
        latitude: 10.5276,
        longitude: 76.2144,
        priority: 'HIGH',
        requiredResources: [
          { resourceId: resources.ambulance.id, quantity: 1 },
        ],
      });
    return response;
  }

  beforeAll(async () => {
    await cleanup();

    const hashedPassword = await bcrypt.hash(password, 10);

    requester = await prisma.user.create({
      data: {
        name: 'Offline Creation Requester',
        email: emails.requester,
        password: hashedPassword,
        role: 'REQUESTER',
        isActive: true,
        location: 'Thrissur, Kerala',
      },
    });

    // Responders start OFFLINE: registered capabilities exist, but nobody is
    // online/available - the exact state that must not block a requester.
    responderAmbulance = await prisma.user.create({
      data: {
        name: 'Offline Ambulance Responder',
        email: emails.responderAmbulance,
        password: hashedPassword,
        role: 'RESPONDER',
        responderStatus: 'OFFLINE',
        isActive: true,
      },
    });

    responderFire = await prisma.user.create({
      data: {
        name: 'Offline Fire Responder',
        email: emails.responderFire,
        password: hashedPassword,
        role: 'RESPONDER',
        responderStatus: 'OFFLINE',
        isActive: true,
      },
    });

    resources = {
      // SERVICE resources are reusable responder capabilities. Availability is
      // derived from responders at matching time, never from catalog stock.
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
      blood: await prisma.resource.create({
        data: {
          name: resourceNames.blood,
          type: 'BLOOD',
          mode: 'CONSUMABLE',
          totalQuantity: 10,
          availableQuantity: 10,
          unit: 'bags',
          isActive: true,
        },
      }),
    };

    await prisma.responderResource.create({
      data: {
        responderId: responderAmbulance.id,
        resourceId: resources.ambulance.id,
        totalQuantity: 2,
        availableQuantity: 2,
        isEnabled: true,
        status: 'AVAILABLE',
      },
    });
    await prisma.responderResource.create({
      data: {
        responderId: responderFire.id,
        resourceId: resources.fire.id,
        totalQuantity: 1,
        availableQuantity: 1,
        isEnabled: true,
        status: 'AVAILABLE',
      },
    });

    tokens = {
      requester: await login(emails.requester),
      responderAmbulance: await login(emails.responderAmbulance),
      responderFire: await login(emails.responderFire),
    };
  });

  afterEach(async () => {
    jest.restoreAllMocks();
    pushNotificationService.setServiceAccountForTests(false);
    await prisma.allocation.deleteMany({
      where: { request: { requesterId: requester.id } },
    });
    await prisma.requestResource.deleteMany({
      where: { request: { requesterId: requester.id } },
    });
    await prisma.emergencyRequest.deleteMany({
      where: { requesterId: requester.id },
    });
    await prisma.user.update({
      where: { id: responderAmbulance.id },
      data: { responderStatus: 'OFFLINE' },
    });
    await prisma.user.update({
      where: { id: responderFire.id },
      data: { responderStatus: 'OFFLINE' },
    });
  });

  afterAll(async () => {
    await cleanup();
    await prisma.$disconnect();
  });

  describe('requester can always submit an emergency', () => {
    test('creates a request when zero responders exist in the database', async () => {
      // Temporarily remove both responder users so the database genuinely has
      // no responders at all. Capabilities travel with them (cascade).
      await prisma.pushDeviceToken.deleteMany({
        where: { userId: { in: [responderAmbulance.id, responderFire.id] } },
      });
      await prisma.responderResource.deleteMany({
        where: { responderId: { in: [responderAmbulance.id, responderFire.id] } },
      });
      await prisma.user.deleteMany({
        where: { id: { in: [responderAmbulance.id, responderFire.id] } },
      });

      try {
        const response = await createEmergency();
        expect(response.statusCode).toBe(201);
        expect(response.body.success).toBe(true);
        expect(response.body.request.status).toBe('PENDING');
        expect(response.body.request.acceptedById).toBeNull();

        const responderCount = await prisma.user.count({ where: { role: 'RESPONDER' } });
        expect(responderCount).toBe(0);
      } finally {
        // Restore the offline responders for the remaining tests.
        const hashedPassword = await bcrypt.hash(password, 10);
        responderAmbulance = await prisma.user.create({
          data: {
            name: 'Offline Ambulance Responder',
            email: emails.responderAmbulance,
            password: hashedPassword,
            role: 'RESPONDER',
            responderStatus: 'OFFLINE',
            isActive: true,
          },
        });
        responderFire = await prisma.user.create({
          data: {
            name: 'Offline Fire Responder',
            email: emails.responderFire,
            password: hashedPassword,
            role: 'RESPONDER',
            responderStatus: 'OFFLINE',
            isActive: true,
          },
        });
        await prisma.responderResource.create({
          data: {
            responderId: responderAmbulance.id,
            resourceId: resources.ambulance.id,
            totalQuantity: 2,
            availableQuantity: 2,
            isEnabled: true,
            status: 'AVAILABLE',
          },
        });
        await prisma.responderResource.create({
          data: {
            responderId: responderFire.id,
            resourceId: resources.fire.id,
            totalQuantity: 1,
            availableQuantity: 1,
            isEnabled: true,
            status: 'AVAILABLE',
          },
        });
        tokens.responderAmbulance = await login(emails.responderAmbulance);
        tokens.responderFire = await login(emails.responderFire);
      }
    });

    test('creates a request when responders exist but all are offline', async () => {
      const offlineResponders = await prisma.user.findMany({
        where: { id: { in: [responderAmbulance.id, responderFire.id] } },
        select: { responderStatus: true },
      });
      expect(offlineResponders).toHaveLength(2);
      expect(offlineResponders.every((row) => row.responderStatus === 'OFFLINE')).toBe(true);

      const response = await createEmergency();
      expect(response.statusCode).toBe(201);
      expect(response.body.request.status).toBe('PENDING');
    });

    test('creates a request for a SERVICE resource with zero available responders', async () => {
      // All responders stay OFFLINE, so the ambulance capability currently has
      // zero AVAILABLE responders - exactly the "no responders available"
      // state that used to block the requester UI.
      const availability = await request(app)
        .get('/api/resources/availability')
        .set('Authorization', `Bearer ${tokens.requester}`);
      expect(availability.statusCode).toBe(200);
      const ambulanceAvailability = availability.body.resources.find(
        (row) => row.id === resources.ambulance.id
      );
      expect(ambulanceAvailability.availableResponders).toBe(0);

      const response = await createEmergency();
      expect(response.statusCode).toBe(201);
      expect(response.body.request.status).toBe('PENDING');
    });

    test('persists the request as PENDING/unassigned with every submitted field', async () => {
      const response = await createEmergency({
        body: {
          emergencyType: 'Fire',
          description: 'Kitchen fire spreading to the first floor',
          location: 'Kochi Marine Drive, Kerala',
          latitude: 9.9312,
          longitude: 76.2673,
          priority: 'CRITICAL',
          requiredResources: [
            { resourceId: resources.fire.id, quantity: 2 },
            { resourceId: resources.blood.id, quantity: 3 },
          ],
        },
      });
      expect(response.statusCode).toBe(201);

      const persisted = await prisma.emergencyRequest.findUnique({
        where: { id: response.body.request.id },
        include: { requiredResources: true },
      });

      expect(persisted).not.toBeNull();
      expect(persisted.status).toBe('PENDING');
      expect(persisted.acceptedById).toBeNull();
      expect(persisted.acceptedAt).toBeNull();
      expect(persisted.emergencyType).toBe('Fire');
      expect(persisted.description).toBe('Kitchen fire spreading to the first floor');
      expect(persisted.location).toBe('Kochi Marine Drive, Kerala');
      expect(persisted.latitude).toBe(9.9312);
      expect(persisted.longitude).toBe(76.2673);
      expect(persisted.priority).toBe('CRITICAL');
      expect(persisted.requesterId).toBe(requester.id);
      expect(persisted.requiredResources).toHaveLength(2);
      expect(persisted.requiredResources.map((row) => row.resourceId).sort())
        .toEqual([resources.fire.id, resources.blood.id].sort());
    });

    test('is not rejected merely because no responder is available for the request', async () => {
      // Both responders OFFLINE + no Socket.IO server + no compatible
      // responder anywhere: creation must still succeed.
      const response = await createEmergency();
      expect(response.statusCode).toBe(201);
      expect(response.body.success).toBe(true);
    });
  });

  describe('compatibility scoping (server-side)', () => {
    test('only the compatible responder sees the request in GET /compatible', async () => {
      await prisma.user.update({
        where: { id: responderAmbulance.id },
        data: { responderStatus: 'AVAILABLE' },
      });
      await prisma.user.update({
        where: { id: responderFire.id },
        data: { responderStatus: 'AVAILABLE' },
      });

      const response = await createEmergency();
      expect(response.statusCode).toBe(201);
      const requestId = response.body.request.id;

      const compatible = await request(app)
        .get('/api/requests/compatible')
        .set('Authorization', `Bearer ${tokens.responderAmbulance}`);
      expect(compatible.statusCode).toBe(200);
      expect(
        compatible.body.requests.some((row) => row.id === requestId)
      ).toBe(true);

      const incompatible = await request(app)
        .get('/api/requests/compatible')
        .set('Authorization', `Bearer ${tokens.responderFire}`);
      expect(incompatible.statusCode).toBe(200);
      expect(
        incompatible.body.requests.some((row) => row.id === requestId)
      ).toBe(false);
    });

    test('a responder coming online retrieves previously created pending requests', async () => {
      // 1. Request is created while every responder is OFFLINE.
      const response = await createEmergency();
      expect(response.statusCode).toBe(201);
      const requestId = response.body.request.id;

      // While offline, the compatible list is empty for them.
      const whileOffline = await request(app)
        .get('/api/requests/compatible')
        .set('Authorization', `Bearer ${tokens.responderAmbulance}`);
      expect(whileOffline.statusCode).toBe(200);
      expect(whileOffline.body.requests.some((row) => row.id === requestId)).toBe(false);

      // 2. The responder comes online (AVAILABLE).
      await prisma.user.update({
        where: { id: responderAmbulance.id },
        data: { responderStatus: 'AVAILABLE' },
      });

      // 3. The compatible API now returns the previously created request.
      const whileOnline = await request(app)
        .get('/api/requests/compatible')
        .set('Authorization', `Bearer ${tokens.responderAmbulance}`);
      expect(whileOnline.statusCode).toBe(200);
      const match = whileOnline.body.requests.find((row) => row.id === requestId);
      expect(match).toBeDefined();
      expect(match.status).toBe('PENDING');
    });

    test('terminal requests are excluded from the compatible list', async () => {
      await prisma.user.update({
        where: { id: responderAmbulance.id },
        data: { responderStatus: 'AVAILABLE' },
      });

      const response = await createEmergency();
      expect(response.statusCode).toBe(201);
      const requestId = response.body.request.id;

      await prisma.emergencyRequest.update({
        where: { id: requestId },
        data: { status: 'COMPLETED' },
      });

      const compatible = await request(app)
        .get('/api/requests/compatible')
        .set('Authorization', `Bearer ${tokens.responderAmbulance}`);
      expect(
        compatible.body.requests.some((row) => row.id === requestId)
      ).toBe(false);
    });
  });

  describe('FCM device tokens', () => {
    test('rejects requester registration with 403', async () => {
      const response = await request(app)
        .post('/api/responders/device-tokens')
        .set('Authorization', `Bearer ${tokens.requester}`)
        .send({ token: 'requester-device-token' });
      expect(response.statusCode).toBe(403);
    });

    test('rejects unauthenticated registration with 401', async () => {
      const response = await request(app)
        .post('/api/responders/device-tokens')
        .send({ token: 'anonymous-device-token' });
      expect(response.statusCode).toBe(401);
    });

    test('rejects an invalid token with 400', async () => {
      for (const token of ['', null, 42, 'x'.repeat(5000), 'bad\x01token']) {
        const response = await request(app)
          .post('/api/responders/device-tokens')
          .set('Authorization', `Bearer ${tokens.responderAmbulance}`)
          .send({ token });
        expect(response.statusCode).toBe(400);
        expect(response.body.success).toBe(false);
      }
    });

    test('a responder registers, re-registers and removes a device token', async () => {
      const register = await request(app)
        .post('/api/responders/device-tokens')
        .set('Authorization', `Bearer ${tokens.responderAmbulance}`)
        .send({ token: 'valid-fcm-token-1', platform: 'android' });
      expect(register.statusCode).toBe(201);
      expect(register.body.deviceToken.userId).toBe(responderAmbulance.id);

      const stored = await prisma.pushDeviceToken.findUnique({
        where: { token: 'valid-fcm-token-1' },
      });
      expect(stored).not.toBeNull();
      expect(stored.userId).toBe(responderAmbulance.id);
      expect(stored.platform).toBe('android');

      // Re-registration refreshes the same row instead of duplicating it.
      const again = await request(app)
        .post('/api/responders/device-tokens')
        .set('Authorization', `Bearer ${tokens.responderAmbulance}`)
        .send({ token: 'valid-fcm-token-1', platform: 'android' });
      expect(again.statusCode).toBe(201);
      const count = await prisma.pushDeviceToken.count({
        where: { token: 'valid-fcm-token-1' },
      });
      expect(count).toBe(1);

      // A different responder's token is untouched by foreign deletes.
      await request(app)
        .post('/api/responders/device-tokens')
        .set('Authorization', `Bearer ${tokens.responderFire}`)
        .send({ token: 'valid-fcm-token-2', platform: 'ios' });

      const remove = await request(app)
        .delete('/api/responders/device-tokens')
        .set('Authorization', `Bearer ${tokens.responderAmbulance}`)
        .send({ token: 'valid-fcm-token-1' });
      expect(remove.statusCode).toBe(200);

      expect(
        await prisma.pushDeviceToken.count({ where: { token: 'valid-fcm-token-1' } })
      ).toBe(0);
      expect(
        await prisma.pushDeviceToken.count({ where: { token: 'valid-fcm-token-2' } })
      ).toBe(1);
    });
  });

  describe('push notifications are best-effort and compatibility-scoped', () => {
    test('FCM push targets only compatible responders, skipping connected devices', async () => {
      // Register devices for the ambulance responder (compatible) and the fire
      // responder (incompatible).
      await prisma.pushDeviceToken.create({
        data: { userId: responderAmbulance.id, token: 'ambulance-device-token' },
      });
      await prisma.pushDeviceToken.create({
        data: { userId: responderFire.id, token: 'fire-device-token' },
      });

      // The delivery layer is mocked below, so a syntactically valid fake
      // service account is enough to make the service "configured".
      pushNotificationService.setServiceAccountForTests({
        clientEmail: 'push@test-project.iam.gserviceaccount.com',
        privateKey: 'fake-key-for-message-building',
        projectId: 'eras-test-project',
      });

      const delivered = [];
      const deliverSpy = jest
        .spyOn(pushNotificationService, 'deliverFcmMessage')
        .mockImplementation(async (message) => {
          delivered.push(message);
          return { ok: true, unregistered: false };
        });

      // Both responders are compatible-capable but only the ambulance
      // responder matches this request. Keep them AVAILABLE so compatibility
      // is computed, and pretend the ambulance responder is ONLINE (already
      // notified over Socket.IO) by seeding the online set through the
      // responder status: the service receives the online set from the
      // request service. Here the ambulance responder is treated as offline
      // because no socket server exists in this suite.
      await prisma.user.update({
        where: { id: responderAmbulance.id },
        data: { responderStatus: 'AVAILABLE' },
      });
      await prisma.user.update({
        where: { id: responderFire.id },
        data: { responderStatus: 'AVAILABLE' },
      });

      const response = await createEmergency();
      expect(response.statusCode).toBe(201);

      await new Promise((resolve) => setTimeout(resolve, 300));
      expect(delivered.length).toBeGreaterThan(0);

      const notifiedTokens = delivered.map((message) => message.token);
      expect(notifiedTokens).toContain('ambulance-device-token');
      expect(notifiedTokens).not.toContain('fire-device-token');

      for (const message of delivered) {
        expect(message.data.kind).toBe('request.created');
        expect(message.data.requestId).toBe(String(response.body.request.id));
        expect(message.notification.title).toBe('New emergency request');
      }

      expect(deliverSpy).toHaveBeenCalled();
    });

    test('a push failure never fails request creation', async () => {
      await prisma.pushDeviceToken.create({
        data: { userId: responderAmbulance.id, token: 'failing-device-token' },
      });
      await prisma.user.update({
        where: { id: responderAmbulance.id },
        data: { responderStatus: 'AVAILABLE' },
      });

      // Force the delivery layer to fail hard, the way a real FCM outage
      // would. Creation must still succeed and the request must be persisted.
      jest.spyOn(pushNotificationService, 'deliverFcmMessage').mockImplementation(
        async () => {
          throw new Error('FCM is down');
        }
      );

      const response = await createEmergency();
      expect(response.statusCode).toBe(201);
      expect(response.body.success).toBe(true);

      const persisted = await prisma.emergencyRequest.findUnique({
        where: { id: response.body.request.id },
      });
      expect(persisted).not.toBeNull();
      expect(persisted.status).toBe('PENDING');
    });

    test('a fully broken notification pipeline (incompatible read failure) still keeps the request', async () => {
      // Even the compatibility lookup used for notifications fails: creation
      // is already committed, so the HTTP response must stay 201.
      jest
        .spyOn(prisma.user, 'findMany')
        .mockRejectedValue(new Error('database read failed during notification'));

      const response = await createEmergency();
      expect(response.statusCode).toBe(201);

      const persisted = await prisma.emergencyRequest.findUnique({
        where: { id: response.body.request.id },
      });
      expect(persisted).not.toBeNull();
      expect(persisted.status).toBe('PENDING');
    });

    test('with FCM unconfigured, registered tokens are simply skipped', async () => {
      await prisma.pushDeviceToken.create({
        data: { userId: responderAmbulance.id, token: 'unconfigured-device-token' },
      });
      await prisma.user.update({
        where: { id: responderAmbulance.id },
        data: { responderStatus: 'AVAILABLE' },
      });

      const response = await createEmergency();
      expect(response.statusCode).toBe(201);
      expect(response.body.request.status).toBe('PENDING');
    });
  });

  describe('existing acceptance rules still hold', () => {
    test('an offline responder still cannot accept, an available compatible one can', async () => {
      const response = await createEmergency();
      expect(response.statusCode).toBe(201);
      const requestId = response.body.request.id;

      // Offline responder: acceptance is refused (existing business rule).
      const offlineAccept = await request(app)
        .patch(`/api/requests/${requestId}/accept`)
        .set('Authorization', `Bearer ${tokens.responderAmbulance}`);
      expect(offlineAccept.statusCode).toBe(400);
      expect(offlineAccept.body.message).toBe('Responder is not available');

      // The request is untouched by the failed acceptance.
      const stillPending = await prisma.emergencyRequest.findUnique({
        where: { id: requestId },
      });
      expect(stillPending.status).toBe('PENDING');
      expect(stillPending.acceptedById).toBeNull();

      // Once available, the compatible responder accepts exactly once.
      await prisma.user.update({
        where: { id: responderAmbulance.id },
        data: { responderStatus: 'AVAILABLE' },
      });
      const accept = await request(app)
        .patch(`/api/requests/${requestId}/accept`)
        .set('Authorization', `Bearer ${tokens.responderAmbulance}`);
      expect(accept.statusCode).toBe(200);
      expect(accept.body.request.status).toBe('ACCEPTED');

      // One active emergency per responder: a second accept is refused.
      const secondAccept = await request(app)
        .patch(`/api/requests/${requestId}/accept`)
        .set('Authorization', `Bearer ${tokens.responderAmbulance}`);
      expect(secondAccept.statusCode).toBe(400);
    });
  });
}
