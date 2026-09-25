const request = require('supertest');
const jwt = require('jsonwebtoken');

const app = require('../../src/app');
const prisma = require('../../src/config/prisma');
const env = require('../../src/config/env');

describe('SERVICE resources and availability counts', () => {
  const suffix = `service-${Date.now()}`;
  let requester;
  let responder;
  let secondResponder;
  let service;
  let serviceCapability;
  let secondCapability;
  let requesterToken;
  let responderToken;

  const tokenFor = (user) =>
    jwt.sign({ userId: user.id, role: user.role }, env.JWT_SECRET, {
      expiresIn: '1h',
    });

  async function createRequest() {
    const response = await request(app)
      .post('/api/requests')
      .set('Authorization', `Bearer ${requesterToken}`)
      .send({
        emergencyType: 'Service test',
        description: 'Reusable capability',
        location: 'Test location',
        priority: 'HIGH',
        requiredResources: [{ resourceId: service.id, quantity: 4 }],
      });
    expect(response.statusCode).toBe(201);
    return response.body.request;
  }

  async function finish(requestId) {
    const allocation = await request(app)
      .post('/api/allocations')
      .set('Authorization', `Bearer ${responderToken}`)
      .send({
        requestId,
        responderResourceId: serviceCapability.id,
        resourceId: service.id,
        quantity: 4,
      });
    expect(allocation.statusCode).toBe(201);

    const dispatched = await request(app)
      .patch(`/api/allocations/${allocation.body.allocation.id}/status`)
      .set('Authorization', `Bearer ${responderToken}`)
      .send({ status: 'DISPATCHED' });
    expect(dispatched.statusCode).toBe(200);

    const delivered = await request(app)
      .patch(`/api/allocations/${allocation.body.allocation.id}/received`)
      .set('Authorization', `Bearer ${requesterToken}`);
    expect(delivered.statusCode).toBe(200);
  }

  beforeAll(async () => {
    await prisma.allocation.deleteMany({
      where: {
        OR: [
          { responder: { email: { in: [userEmail('responder'), userEmail('second')] } } },
          { request: { requester: { email: userEmail('requester') } } },
        ],
      },
    });
    await prisma.requestResource.deleteMany({
      where: { request: { requester: { email: userEmail('requester') } } },
    });
    await prisma.emergencyRequest.deleteMany({
      where: { requester: { email: userEmail('requester') } },
    });
    await prisma.responderResource.deleteMany({
      where: { responder: { email: { in: [userEmail('responder'), userEmail('second')] } } },
    });
    await prisma.resource.deleteMany({ where: { name: resourceName() } });
    await prisma.user.deleteMany({
      where: { email: { in: [userEmail('requester'), userEmail('responder'), userEmail('second')] } },
    });

    requester = await prisma.user.create({
      data: {
        name: 'Service requester',
        email: userEmail('requester'),
        password: 'test',
        role: 'REQUESTER',
        isActive: true,
      },
    });
    responder = await prisma.user.create({
      data: {
        name: 'Service responder',
        email: userEmail('responder'),
        password: 'test',
        role: 'RESPONDER',
        isActive: true,
        responderStatus: 'AVAILABLE',
      },
    });
    secondResponder = await prisma.user.create({
      data: {
        name: 'Second service responder',
        email: userEmail('second'),
        password: 'test',
        role: 'RESPONDER',
        isActive: true,
        responderStatus: 'AVAILABLE',
      },
    });
    service = await prisma.resource.create({
      data: {
        name: resourceName(),
        type: 'SERVICE_TEST',
        mode: 'SERVICE',
        totalQuantity: 0,
        availableQuantity: 0,
        isActive: true,
      },
    });
    serviceCapability = await prisma.responderResource.create({
      data: {
        responderId: responder.id,
        resourceId: service.id,
        totalQuantity: 0,
        availableQuantity: 0,
        isEnabled: true,
        status: 'UNAVAILABLE',
      },
    });
    secondCapability = await prisma.responderResource.create({
      data: {
        responderId: secondResponder.id,
        resourceId: service.id,
        totalQuantity: 0,
        availableQuantity: 0,
        isEnabled: true,
        status: 'UNAVAILABLE',
      },
    });
    requesterToken = tokenFor(requester);
    responderToken = tokenFor(responder);
  });

  afterAll(async () => {
    await prisma.allocation.deleteMany({ where: { resourceId: service.id } });
    await prisma.requestResource.deleteMany({ where: { resourceId: service.id } });
    await prisma.emergencyRequest.deleteMany({ where: { requesterId: requester.id } });
    await prisma.responderResource.deleteMany({ where: { resourceId: service.id } });
    await prisma.resource.delete({ where: { id: service.id } });
    await prisma.user.deleteMany({
      where: { id: { in: [requester.id, responder.id, secondResponder.id] } },
    });
  });

  test('SERVICE request can be accepted with zero inventory quantity', async () => {
    const emergency = await createRequest();
    const accepted = await request(app)
      .patch(`/api/requests/${emergency.id}/accept`)
      .set('Authorization', `Bearer ${responderToken}`);

    expect(accepted.statusCode).toBe(200);
    expect((await prisma.user.findUnique({ where: { id: responder.id } })).responderStatus).toBe('BUSY');
    await finish(emergency.id);
  });

  test('SERVICE allocation is reusable and does not consume quantity', async () => {
    const before = await prisma.responderResource.findUnique({ where: { id: serviceCapability.id } });
    const catalogBefore = await prisma.resource.findUnique({ where: { id: service.id } });
    const first = await createRequest();
    const acceptedFirst = await request(app)
      .patch(`/api/requests/${first.id}/accept`)
      .set('Authorization', `Bearer ${responderToken}`);
    expect(acceptedFirst.statusCode).toBe(200);
    await finish(first.id);

    const middle = await prisma.responderResource.findUnique({ where: { id: serviceCapability.id } });
    expect(middle.availableQuantity).toBe(before.availableQuantity);

    const second = await createRequest();
    const acceptedSecond = await request(app)
      .patch(`/api/requests/${second.id}/accept`)
      .set('Authorization', `Bearer ${responderToken}`);
    expect(acceptedSecond.statusCode).toBe(200);
    await finish(second.id);

    const after = await prisma.responderResource.findUnique({ where: { id: serviceCapability.id } });
    const catalogAfter = await prisma.resource.findUnique({ where: { id: service.id } });
    expect(after.availableQuantity).toBe(before.availableQuantity);
    expect(catalogAfter.availableQuantity).toBe(catalogBefore.availableQuantity);
  });

  test('availability endpoint counts only active AVAILABLE enabled service responders', async () => {
    const available = await request(app)
      .get('/api/resources/availability')
      .set('Authorization', `Bearer ${requesterToken}`);
    expect(available.statusCode).toBe(200);
    expect(available.body.resources.find((row) => row.id === service.id)).toMatchObject({
      mode: 'SERVICE',
      availableResponders: 2,
      availableQuantity: null,
    });

    await prisma.user.update({ where: { id: secondResponder.id }, data: { responderStatus: 'BUSY' } });
    const busy = await request(app)
      .get('/api/resources/availability')
      .set('Authorization', `Bearer ${requesterToken}`);
    expect(busy.body.resources.find((row) => row.id === service.id).availableResponders).toBe(1);

    await prisma.responderResource.update({ where: { id: serviceCapability.id }, data: { isEnabled: false } });
    const disabled = await request(app)
      .get('/api/resources/availability')
      .set('Authorization', `Bearer ${requesterToken}`);
    expect(disabled.body.resources.find((row) => row.id === service.id).availableResponders).toBe(0);

    await prisma.responderResource.update({ where: { id: serviceCapability.id }, data: { isEnabled: true } });
    await prisma.user.update({ where: { id: responder.id }, data: { isActive: false, responderStatus: 'OFFLINE' } });
    const inactiveResponder = await request(app)
      .get('/api/resources/availability')
      .set('Authorization', `Bearer ${requesterToken}`);
    expect(inactiveResponder.body.resources.find((row) => row.id === service.id).availableResponders).toBe(0);

    await prisma.user.update({ where: { id: responder.id }, data: { isActive: true, responderStatus: 'AVAILABLE' } });
    await prisma.user.update({ where: { id: secondResponder.id }, data: { responderStatus: 'AVAILABLE' } });
    await prisma.resource.update({ where: { id: service.id }, data: { isActive: false } });
    const inactiveResource = await request(app)
      .get('/api/resources/availability')
      .set('Authorization', `Bearer ${requesterToken}`);
    expect(inactiveResource.body.resources.some((row) => row.id === service.id)).toBe(false);
  });

  function userEmail(kind) {
    return `${suffix}-${kind}@test.invalid`;
  }

  function resourceName() {
    return `${suffix}-Ambulance`;
  }
});
