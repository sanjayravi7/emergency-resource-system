require('dotenv').config();

const bcrypt = require('bcrypt');
const request = require('supertest');

const hasDatabase = Boolean(process.env.DATABASE_URL && process.env.JWT_SECRET);

if (!hasDatabase) {
  describe.skip('Responder help types (requires DATABASE_URL and JWT_SECRET)', () => {
    test('skipped because a PostgreSQL test database is not configured', () => {});
  });
} else {
  const app = require('../../src/app');
  const prisma = require('../../src/config/prisma');
  const pushNotificationService = require('../../src/services/pushNotificationService');

  const runId = `help-types-${Date.now()}`;
  const password = 'HelpTypes123!';
  const emails = {
    requester: `${runId}-requester@test.com`,
    fire: `${runId}-fire@test.com`,
    medical: `${runId}-medical@test.com`,
  };
  let users;
  let tokens;
  let resource;

  async function cleanup() {
    const ids = Object.values(users || {}).map((user) => user.id);
    if (ids.length) {
      await prisma.allocation.deleteMany({
        where: { OR: [{ responderId: { in: ids } }, { request: { requesterId: { in: ids } } }] },
      });
      await prisma.responderAssignment.deleteMany({
        where: { OR: [{ responderId: { in: ids } }, { request: { requesterId: { in: ids } } }] },
      });
      await prisma.requestResource.deleteMany({
        where: { request: { requesterId: { in: ids } } },
      });
      await prisma.emergencyRequest.deleteMany({ where: { requesterId: { in: ids } } });
      await prisma.responderResource.deleteMany({ where: { responderId: { in: ids } } });
      await prisma.responderHelpType.deleteMany({ where: { responderId: { in: ids } } });
      await prisma.pushDeviceToken.deleteMany({ where: { userId: { in: ids } } });
    }
    if (resource) await prisma.resource.deleteMany({ where: { id: resource.id } });
    await prisma.user.deleteMany({ where: { email: { in: Object.values(emails) } } });
  }

  async function login(email) {
    const response = await request(app).post('/api/auth/login').send({ email, password });
    expect(response.statusCode).toBe(200);
    return response.body.data.token;
  }

  beforeAll(async () => {
    await cleanup();
    const hash = await bcrypt.hash(password, 10);
    users = {
      requester: await prisma.user.create({
        data: { name: 'Requester', email: emails.requester, password: hash, role: 'REQUESTER' },
      }),
      fire: await prisma.user.create({
        data: { name: 'Fire responder', email: emails.fire, password: hash, role: 'RESPONDER' },
      }),
      medical: await prisma.user.create({
        data: { name: 'Medical responder', email: emails.medical, password: hash, role: 'RESPONDER' },
      }),
    };
    tokens = {
      requester: await login(emails.requester),
      fire: await login(emails.fire),
      medical: await login(emails.medical),
    };
  });

  afterEach(async () => {
    jest.restoreAllMocks();
    await prisma.allocation.deleteMany({ where: { request: { requesterId: users.requester.id } } });
    await prisma.responderAssignment.deleteMany({ where: { request: { requesterId: users.requester.id } } });
    await prisma.requestResource.deleteMany({ where: { request: { requesterId: users.requester.id } } });
    await prisma.emergencyRequest.deleteMany({ where: { requesterId: users.requester.id } });
  });

  afterAll(async () => {
    await cleanup();
    await prisma.$disconnect();
  });

  test('canonical help types can be selected with no responder resource rows and make the responder available', async () => {
    expect(await prisma.responderResource.count({ where: { responderId: users.fire.id } })).toBe(0);

    const response = await request(app)
      .put('/api/responders/help-types')
      .set('Authorization', `Bearer ${tokens.fire}`)
      .send({ helpTypes: ['FIRE', 'RESCUE'] });

    expect(response.statusCode).toBe(200);
    expect(response.body.categories.map((item) => item.value)).toEqual(
      expect.arrayContaining(['FIRE', 'MEDICAL', 'ACCIDENT', 'FLOOD', 'RESCUE', 'OTHER'])
    );
    expect(response.body.selected).toEqual(['FIRE', 'RESCUE']);
    expect((await prisma.user.findUnique({ where: { id: users.fire.id } })).responderStatus).toBe('AVAILABLE');

    const status = await request(app)
      .patch('/api/responders/status')
      .set('Authorization', `Bearer ${tokens.fire}`)
      .send({ status: 'AVAILABLE' });
    expect(status.statusCode).toBe(200);
  });

  test('a responder with no help types cannot go available', async () => {
    await request(app)
      .put('/api/responders/help-types')
      .set('Authorization', `Bearer ${tokens.medical}`)
      .send({ helpTypes: [] });

    const response = await request(app)
      .patch('/api/responders/status')
      .set('Authorization', `Bearer ${tokens.medical}`)
      .send({ status: 'AVAILABLE' });
    expect(response.statusCode).toBe(400);
    expect(response.body.message).toMatch(/help type/i);
  });

  test('only the FIRE responder retrieves an existing FIRE request after coming online', async () => {
    await request(app).put('/api/responders/help-types').set('Authorization', `Bearer ${tokens.fire}`).send({ helpTypes: ['FIRE'] });
    await request(app).put('/api/responders/help-types').set('Authorization', `Bearer ${tokens.medical}`).send({ helpTypes: ['MEDICAL'] });
    await prisma.user.updateMany({
      where: { id: { in: [users.fire.id, users.medical.id] } },
      data: { responderStatus: 'OFFLINE' },
    });

    const created = await request(app)
      .post('/api/requests')
      .set('Authorization', `Bearer ${tokens.requester}`)
      .send({ emergencyType: 'Fire', location: 'Test location' });
    expect(created.statusCode).toBe(201);
    expect(created.body.request.requiredResources).toHaveLength(0);

    await request(app)
      .patch('/api/responders/status')
      .set('Authorization', `Bearer ${tokens.fire}`)
      .send({ status: 'AVAILABLE' });
    await request(app)
      .patch('/api/responders/status')
      .set('Authorization', `Bearer ${tokens.medical}`)
      .send({ status: 'AVAILABLE' });

    const fire = await request(app).get('/api/requests/compatible').set('Authorization', `Bearer ${tokens.fire}`);
    const medical = await request(app).get('/api/requests/compatible').set('Authorization', `Bearer ${tokens.medical}`);
    expect(fire.body.requests.map((row) => row.id)).toContain(created.body.request.id);
    expect(medical.body.requests.map((row) => row.id)).not.toContain(created.body.request.id);
  });

  test('notifications target category-compatible responders only and remain best effort', async () => {
    await request(app).put('/api/responders/help-types').set('Authorization', `Bearer ${tokens.fire}`).send({ helpTypes: ['FIRE'] });
    await request(app).put('/api/responders/help-types').set('Authorization', `Bearer ${tokens.medical}`).send({ helpTypes: ['MEDICAL'] });
    const notify = jest
      .spyOn(pushNotificationService, 'notifyRespondersOfNewEmergency')
      .mockResolvedValue({ sent: 1 });

    const created = await request(app)
      .post('/api/requests')
      .set('Authorization', `Bearer ${tokens.requester}`)
      .send({ emergencyType: 'FIRE', location: 'Test location' });
    expect(created.statusCode).toBe(201);
    expect(notify).toHaveBeenCalled();
    const compatibleIds = notify.mock.calls[0][1];
    expect(compatibleIds).toContain(users.fire.id);
    expect(compatibleIds).not.toContain(users.medical.id);
  });

  test('resource checks still gate acceptance/allocation for a resource-bearing emergency', async () => {
    await request(app).put('/api/responders/help-types').set('Authorization', `Bearer ${tokens.fire}`).send({ helpTypes: ['FIRE'] });
    resource = await prisma.resource.create({
      data: {
        name: `${runId} oxygen`,
        type: 'OXYGEN',
        mode: 'CONSUMABLE',
        totalQuantity: 2,
        availableQuantity: 2,
      },
    });
    const created = await request(app)
      .post('/api/requests')
      .set('Authorization', `Bearer ${tokens.requester}`)
      .send({
        emergencyType: 'FIRE',
        location: 'Test location',
        requiredResources: [{ resourceId: resource.id, quantity: 1 }],
      });
    expect(created.statusCode).toBe(201);

    // Category matching makes the request discoverable, but existing resource
    // compatibility remains authoritative when it is accepted/allocated.
    const compatible = await request(app).get('/api/requests/compatible').set('Authorization', `Bearer ${tokens.fire}`);
    expect(compatible.body.requests.map((row) => row.id)).toContain(created.body.request.id);
    const rejected = await request(app)
      .patch(`/api/requests/${created.body.request.id}/accept`)
      .set('Authorization', `Bearer ${tokens.fire}`);
    // Missing responder inventory is a business validation failure, not a
    // server error. The acceptance endpoint returns a client error while
    // leaving the request pending for a compatible responder.
    expect(rejected.statusCode).toBe(400);
    expect(rejected.body.message).toMatch(/compatible resource|required resource|resource/i);

    const inventory = await prisma.responderResource.create({
      data: {
        responderId: users.fire.id,
        resourceId: resource.id,
        totalQuantity: 1,
        availableQuantity: 1,
        isEnabled: true,
        status: 'AVAILABLE',
      },
    });
    const accepted = await request(app)
      .patch(`/api/requests/${created.body.request.id}/accept`)
      .set('Authorization', `Bearer ${tokens.fire}`);
    expect(accepted.statusCode).toBe(200);

    const allocated = await request(app)
      .post('/api/allocations')
      .set('Authorization', `Bearer ${tokens.fire}`)
      .send({
        requestId: created.body.request.id,
        responderResourceId: inventory.id,
        resourceId: resource.id,
        quantity: 1,
      });
    expect(allocated.statusCode).toBe(201);
    expect(allocated.body.allocation.quantity).toBe(1);
  });
}
