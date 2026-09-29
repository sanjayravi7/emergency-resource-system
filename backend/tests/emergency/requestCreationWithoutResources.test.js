// A requester must ALWAYS be able to file an emergency, even when they name
// zero resources, the resource catalog is completely empty, or nothing is
// currently allocatable. These regression tests lock in the "resource
// information is optional" rule for POST /api/requests:
//
//   - a request is created (HTTP 201) with requiredResources omitted,
//   - a request is created with an explicit empty requiredResources array,
//   - a request is created when the catalog has NO active resources at all,
//   - a request is created when the database has zero responders,
//   - the row is persisted as PENDING / unassigned with ZERO RequestResource
//     rows (EmergencyRequest 0..N RequestResource),
//   - a notification failure never turns a committed creation into an error,
//   - resource matching stays capability-based: a compatible responder that
//     comes online later retrieves a resource-bearing pending request while an
//     incompatible responder never does,
//   - structurally invalid resource lines are still rejected (400), proving we
//     only stopped REQUIRING resources - we did not stop validating them.
require('dotenv').config();

const bcrypt = require('bcrypt');
const request = require('supertest');

const hasDatabase = Boolean(process.env.DATABASE_URL && process.env.JWT_SECRET);

if (!hasDatabase) {
  describe.skip('Emergency creation without resources (requires DATABASE_URL and JWT_SECRET)', () => {
    test('skipped because a PostgreSQL test database is not configured', () => {});
  });
} else {
  const app = require('../../src/app');
  const prisma = require('../../src/config/prisma');

  const password = 'ResourcelessRequester123!';
  const runId = `no-resource-create-${Date.now()}`;
  const emails = {
    requester: `${runId}-requester@test.com`,
    responderAmbulance: `${runId}-responder-ambulance@test.com`,
    responderFire: `${runId}-responder-fire@test.com`,
  };
  const resourceNames = {
    ambulance: `${runId} Ambulance`,
    fire: `${runId} Fire Engine`,
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

  function baseBody(overrides = {}) {
    // A minimal emergency: type + location only. No resource information.
    return {
      emergencyType: 'Medical',
      location: 'Thrissur Round, Kerala',
      priority: 'HIGH',
      ...overrides,
    };
  }

  async function createEmergency({ token, body } = {}) {
    return request(app)
      .post('/api/requests')
      .set('Authorization', `Bearer ${token || tokens.requester}`)
      .send(body || baseBody());
  }

  beforeAll(async () => {
    await cleanup();

    const hashedPassword = await bcrypt.hash(password, 10);

    requester = await prisma.user.create({
      data: {
        name: 'Resourceless Requester',
        email: emails.requester,
        password: hashedPassword,
        role: 'REQUESTER',
        isActive: true,
        location: 'Thrissur, Kerala',
      },
    });

    responderAmbulance = await prisma.user.create({
      data: {
        name: 'Ambulance Responder',
        email: emails.responderAmbulance,
        password: hashedPassword,
        role: 'RESPONDER',
        responderStatus: 'OFFLINE',
        isActive: true,
      },
    });

    responderFire = await prisma.user.create({
      data: {
        name: 'Fire Responder',
        email: emails.responderFire,
        password: hashedPassword,
        role: 'RESPONDER',
        responderStatus: 'OFFLINE',
        isActive: true,
      },
    });

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
    await prisma.allocation.deleteMany({
      where: { request: { requesterId: requester.id } },
    });
    await prisma.requestResource.deleteMany({
      where: { request: { requesterId: requester.id } },
    });
    await prisma.emergencyRequest.deleteMany({
      where: { requesterId: requester.id },
    });
    await prisma.user.updateMany({
      where: { id: { in: [responderAmbulance.id, responderFire.id] } },
      data: { responderStatus: 'OFFLINE' },
    });
  });

  afterAll(async () => {
    await cleanup();
    await prisma.$disconnect();
  });

  describe('resource information is optional', () => {
    test('creates an emergency with requiredResources omitted -> 201 PENDING, zero RequestResource rows', async () => {
      const response = await createEmergency();

      expect(response.statusCode).toBe(201);
      expect(response.body.success).toBe(true);
      expect(response.body.request.status).toBe('PENDING');
      expect(response.body.request.acceptedById).toBeNull();
      expect(response.body.request.requiredResources).toHaveLength(0);

      const persisted = await prisma.emergencyRequest.findUnique({
        where: { id: response.body.request.id },
        include: { requiredResources: true },
      });
      expect(persisted).not.toBeNull();
      expect(persisted.status).toBe('PENDING');
      expect(persisted.acceptedById).toBeNull();
      expect(persisted.requiredResources).toHaveLength(0);
    });

    test('creates an emergency with an explicit empty requiredResources array', async () => {
      const response = await createEmergency({
        body: baseBody({ requiredResources: [] }),
      });

      expect(response.statusCode).toBe(201);
      expect(response.body.request.status).toBe('PENDING');
      expect(response.body.request.requiredResources).toHaveLength(0);
    });

    test('emergency type stays mandatory even when resources are omitted', async () => {
      const response = await createEmergency({
        body: { location: 'Somewhere, Kerala', priority: 'HIGH' },
      });
      expect(response.statusCode).toBe(400);
      expect(response.body.success).toBe(false);
      expect(response.body.message).toMatch(/emergency type/i);
    });

    test('location rules are preserved when resources are omitted', async () => {
      const response = await createEmergency({
        body: { emergencyType: 'Medical', priority: 'HIGH' },
      });
      expect(response.statusCode).toBe(400);
      expect(response.body.message).toMatch(/location/i);
    });
  });

  describe('availability never blocks creation', () => {
    test('creates an emergency when the catalog has NO active resources at all', async () => {
      // Deactivate every resource in this run so the catalog exposes zero
      // active/allocatable resources - the empty-catalog case.
      await prisma.resource.updateMany({
        where: { id: { in: [resources.ambulance.id, resources.fire.id] } },
        data: { isActive: false },
      });

      try {
        const response = await createEmergency();
        expect(response.statusCode).toBe(201);
        expect(response.body.request.status).toBe('PENDING');
        expect(response.body.request.requiredResources).toHaveLength(0);
      } finally {
        await prisma.resource.updateMany({
          where: { id: { in: [resources.ambulance.id, resources.fire.id] } },
          data: { isActive: true },
        });
      }
    });

    test('creates a resourceless emergency when the database has zero responders', async () => {
      // Temporarily remove both responders (capabilities cascade with them).
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
        expect(response.body.request.status).toBe('PENDING');

        const responderCount = await prisma.user.count({
          where: { role: 'RESPONDER', email: { in: Object.values(emails) } },
        });
        expect(responderCount).toBe(0);
      } finally {
        const hashedPassword = await bcrypt.hash(password, 10);
        responderAmbulance = await prisma.user.create({
          data: {
            name: 'Ambulance Responder',
            email: emails.responderAmbulance,
            password: hashedPassword,
            role: 'RESPONDER',
            responderStatus: 'OFFLINE',
            isActive: true,
          },
        });
        responderFire = await prisma.user.create({
          data: {
            name: 'Fire Responder',
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

    test('a notification failure never fails a resourceless creation', async () => {
      // The post-commit notification path reads responders through
      // prisma.user.findMany. Even a hard failure there must leave the
      // already-committed emergency intact and the HTTP response at 201.
      jest
        .spyOn(prisma.user, 'findMany')
        .mockRejectedValue(new Error('database read failed during notification'));

      const response = await createEmergency();
      expect(response.statusCode).toBe(201);
      expect(response.body.request.requiredResources).toHaveLength(0);

      const persisted = await prisma.emergencyRequest.findUnique({
        where: { id: response.body.request.id },
      });
      expect(persisted).not.toBeNull();
      expect(persisted.status).toBe('PENDING');
    });
  });

  describe('matching stays capability-based and server-side', () => {
    test('a compatible responder coming online retrieves a pending resource-bearing request; an incompatible one never does', async () => {
      // A resource-bearing emergency is filed while everyone is OFFLINE.
      const response = await createEmergency({
        body: baseBody({
          requiredResources: [{ resourceId: resources.ambulance.id, quantity: 1 }],
        }),
      });
      expect(response.statusCode).toBe(201);
      const requestId = response.body.request.id;

      // While offline, the compatible responder cannot see it yet.
      const whileOffline = await request(app)
        .get('/api/requests/compatible')
        .set('Authorization', `Bearer ${tokens.responderAmbulance}`);
      expect(whileOffline.statusCode).toBe(200);
      expect(whileOffline.body.requests.some((row) => row.id === requestId)).toBe(false);

      // Both responders come online.
      await prisma.user.updateMany({
        where: { id: { in: [responderAmbulance.id, responderFire.id] } },
        data: { responderStatus: 'AVAILABLE' },
      });

      // The AMBULANCE-capable responder now retrieves the pending request.
      const compatible = await request(app)
        .get('/api/requests/compatible')
        .set('Authorization', `Bearer ${tokens.responderAmbulance}`);
      expect(compatible.statusCode).toBe(200);
      const match = compatible.body.requests.find((row) => row.id === requestId);
      expect(match).toBeDefined();
      expect(match.status).toBe('PENDING');

      // The FIRE-only responder is incompatible and never retrieves it.
      const incompatible = await request(app)
        .get('/api/requests/compatible')
        .set('Authorization', `Bearer ${tokens.responderFire}`);
      expect(incompatible.statusCode).toBe(200);
      expect(incompatible.body.requests.some((row) => row.id === requestId)).toBe(false);
    });

    test('a resourceless emergency is not offered to responders through capability matching, yet remains PENDING', async () => {
      const response = await createEmergency();
      expect(response.statusCode).toBe(201);
      const requestId = response.body.request.id;

      await prisma.user.updateMany({
        where: { id: { in: [responderAmbulance.id, responderFire.id] } },
        data: { responderStatus: 'AVAILABLE' },
      });

      for (const token of [tokens.responderAmbulance, tokens.responderFire]) {
        const compatible = await request(app)
          .get('/api/requests/compatible')
          .set('Authorization', `Bearer ${token}`);
        expect(compatible.statusCode).toBe(200);
        expect(compatible.body.requests.some((row) => row.id === requestId)).toBe(false);
      }

      // It is created and durably PENDING, waiting for triage - never rejected.
      const persisted = await prisma.emergencyRequest.findUnique({
        where: { id: requestId },
      });
      expect(persisted.status).toBe('PENDING');
    });
  });

  describe('supplied resource lines are still validated', () => {
    test('rejects a non-array requiredResources value', async () => {
      const response = await createEmergency({
        body: baseBody({ requiredResources: 'not-an-array' }),
      });
      expect(response.statusCode).toBe(400);
      expect(response.body.success).toBe(false);
    });

    test('rejects a structurally invalid resource line', async () => {
      const response = await createEmergency({
        body: baseBody({
          requiredResources: [{ resourceId: resources.ambulance.id, quantity: 0 }],
        }),
      });
      expect(response.statusCode).toBe(400);
      expect(response.body.success).toBe(false);
    });

    test('rejects a resource line that references a resource that does not exist', async () => {
      const response = await createEmergency({
        body: baseBody({
          requiredResources: [{ resourceId: 987654321, quantity: 1 }],
        }),
      });
      expect(response.statusCode).toBe(400);
      expect(response.body.success).toBe(false);
    });
  });
}
