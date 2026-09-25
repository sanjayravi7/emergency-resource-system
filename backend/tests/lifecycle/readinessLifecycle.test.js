const request = require('supertest');
const jwt = require('jsonwebtoken');

const app = require('../../src/app');
const prisma = require('../../src/config/prisma');
const env = require('../../src/config/env');

describe('Responder readiness and delivery lifecycle', () => {
  const suffix = `readiness-${Date.now()}`;
  let requester;
  let otherRequester;
  let responder;
  let requesterToken;
  let otherRequesterToken;
  let responderToken;
  let blood;
  let fire;
  let inactive;
  let bloodInventory;
  let fireInventory;

  const userEmail = (kind) => `${suffix}-${kind}@test.invalid`;

  const tokenFor = (user) =>
    jwt.sign({ userId: user.id, role: user.role }, env.JWT_SECRET, {
      expiresIn: '1h',
    });

  async function createEmergency(requiredResources, requesterId = requester.id) {
    return prisma.emergencyRequest.create({
      data: {
        requesterId,
        emergencyType: 'Lifecycle test',
        description: 'Readiness lifecycle verification',
        location: 'Test location',
        priority: 'HIGH',
        status: 'PENDING',
        requiredResources: { create: requiredResources },
      },
    });
  }

  async function accept(requestId) {
    return request(app)
      .patch(`/api/requests/${requestId}/accept`)
      .set('Authorization', `Bearer ${responderToken}`);
  }

  async function createAllocation(requestId, inventory, resource, quantity = 1) {
    return request(app)
      .post('/api/allocations')
      .set('Authorization', `Bearer ${responderToken}`)
      .send({
        requestId,
        responderResourceId: inventory.id,
        resourceId: resource.id,
        quantity,
      });
  }

  async function dispatch(allocationId) {
    return request(app)
      .patch(`/api/allocations/${allocationId}/status`)
      .set('Authorization', `Bearer ${responderToken}`)
      .send({ status: 'DISPATCHED' });
  }

  async function received(allocationId, token = requesterToken) {
    return request(app)
      .patch(`/api/allocations/${allocationId}/received`)
      .set('Authorization', `Bearer ${token}`);
  }

  beforeEach(async () => {
    requester = await prisma.user.create({
      data: {
        name: 'Lifecycle requester',
        email: userEmail('requester'),
        password: 'not-used',
        role: 'REQUESTER',
      },
    });
    otherRequester = await prisma.user.create({
      data: {
        name: 'Other lifecycle requester',
        email: userEmail('other-requester'),
        password: 'not-used',
        role: 'REQUESTER',
      },
    });
    responder = await prisma.user.create({
      data: {
        name: 'Lifecycle responder',
        email: userEmail('responder'),
        password: 'not-used',
        role: 'RESPONDER',
        isActive: true,
        responderStatus: 'AVAILABLE',
      },
    });

    requesterToken = tokenFor(requester);
    otherRequesterToken = tokenFor(otherRequester);
    responderToken = tokenFor(responder);

    blood = await prisma.resource.create({
      data: {
        name: `${suffix}-Blood-${Date.now()}`,
        type: 'BLOOD',
        totalQuantity: 20,
        availableQuantity: 20,
        unit: 'unit',
        isActive: true,
      },
    });
    fire = await prisma.resource.create({
      data: {
        name: `${suffix}-Fire-${Date.now()}`,
        type: 'FIRE',
        totalQuantity: 20,
        availableQuantity: 20,
        unit: 'unit',
        isActive: true,
      },
    });
    inactive = await prisma.resource.create({
      data: {
        name: `${suffix}-Inactive-${Date.now()}`,
        type: 'INACTIVE',
        totalQuantity: 20,
        availableQuantity: 20,
        unit: 'unit',
        isActive: false,
      },
    });

    bloodInventory = await prisma.responderResource.create({
      data: {
        responderId: responder.id,
        resourceId: blood.id,
        totalQuantity: 10,
        availableQuantity: 10,
        isEnabled: true,
        status: 'AVAILABLE',
      },
    });
    fireInventory = await prisma.responderResource.create({
      data: {
        responderId: responder.id,
        resourceId: fire.id,
        totalQuantity: 10,
        availableQuantity: 10,
        isEnabled: false,
        status: 'AVAILABLE',
      },
    });
  });

  afterEach(async () => {
    await prisma.allocation.deleteMany({
      where: { request: { requesterId: { in: [requester.id, otherRequester.id] } } },
    });
    await prisma.requestResource.deleteMany({
      where: { request: { requesterId: { in: [requester.id, otherRequester.id] } } },
    });
    await prisma.emergencyRequest.deleteMany({
      where: { requesterId: { in: [requester.id, otherRequester.id] } },
    });
    await prisma.responderResource.deleteMany({ where: { responderId: responder.id } });
    await prisma.resource.deleteMany({ where: { id: { in: [blood.id, fire.id, inactive.id] } } });
    await prisma.user.deleteMany({
      where: { id: { in: [requester.id, otherRequester.id, responder.id] } },
    });
  });

  test('1. responder selects Blood', async () => {
    const response = await request(app)
      .get('/api/responder-resources/my')
      .set('Authorization', `Bearer ${responderToken}`);

    expect(response.statusCode).toBe(200);
    expect(response.body.resources.find((row) => row.id === bloodInventory.id).isEnabled).toBe(true);
  });

  test('2. responder does not select Fire', async () => {
    const response = await request(app)
      .get('/api/responder-resources/my')
      .set('Authorization', `Bearer ${responderToken}`);

    expect(response.statusCode).toBe(200);
    expect(response.body.resources.find((row) => row.id === fireInventory.id).isEnabled).toBe(false);
  });

  test('3. request requiring Blood + Fire does not appear', async () => {
    const emergency = await createEmergency([
      { resourceId: blood.id, quantity: 1 },
      { resourceId: fire.id, quantity: 1 },
    ]);

    const response = await request(app)
      .get('/api/requests/compatible')
      .set('Authorization', `Bearer ${responderToken}`);

    expect(response.statusCode).toBe(200);
    expect(response.body.requests.map((item) => item.id)).not.toContain(emergency.id);
  });

  test('4. request requiring only Blood appears', async () => {
    const emergency = await createEmergency([{ resourceId: blood.id, quantity: 1 }]);

    const response = await request(app)
      .get('/api/requests/compatible')
      .set('Authorization', `Bearer ${responderToken}`);

    expect(response.statusCode).toBe(200);
    expect(response.body.requests.map((item) => item.id)).toContain(emergency.id);
  });

  test('5. responder accepts a compatible request', async () => {
    const emergency = await createEmergency([{ resourceId: blood.id, quantity: 1 }]);
    const response = await accept(emergency.id);

    expect(response.statusCode).toBe(200);
    expect(response.body.request.acceptedById).toBe(responder.id);
  });

  test('6. responder becomes BUSY after acceptance', async () => {
    const emergency = await createEmergency([{ resourceId: blood.id, quantity: 1 }]);
    await accept(emergency.id);

    const current = await prisma.user.findUnique({ where: { id: responder.id } });
    expect(current.responderStatus).toBe('BUSY');
  });

  test('7. RESERVED keeps responder BUSY', async () => {
    const emergency = await createEmergency([{ resourceId: blood.id, quantity: 1 }]);
    await accept(emergency.id);
    const allocation = await createAllocation(emergency.id, bloodInventory, blood);

    expect(allocation.statusCode).toBe(201);
    expect((await prisma.user.findUnique({ where: { id: responder.id } })).responderStatus).toBe('BUSY');
  });

  test('8. DISPATCHED keeps responder BUSY', async () => {
    const emergency = await createEmergency([{ resourceId: blood.id, quantity: 1 }]);
    await accept(emergency.id);
    const allocation = await createAllocation(emergency.id, bloodInventory, blood);
    const response = await dispatch(allocation.body.allocation.id);

    expect(response.statusCode).toBe(200);
    expect((await prisma.user.findUnique({ where: { id: responder.id } })).responderStatus).toBe('BUSY');
  });

  test('9. requester confirms receipt', async () => {
    const emergency = await createEmergency([{ resourceId: blood.id, quantity: 1 }]);
    await accept(emergency.id);
    const allocation = await createAllocation(emergency.id, bloodInventory, blood);
    await dispatch(allocation.body.allocation.id);

    const response = await received(allocation.body.allocation.id);
    expect(response.statusCode).toBe(200);
    expect(response.body.message).toBe('Resource receipt confirmed');
  });

  test('10. allocation becomes DELIVERED', async () => {
    const emergency = await createEmergency([{ resourceId: blood.id, quantity: 1 }]);
    await accept(emergency.id);
    const allocation = await createAllocation(emergency.id, bloodInventory, blood);
    await dispatch(allocation.body.allocation.id);
    await received(allocation.body.allocation.id);

    const current = await prisma.allocation.findUnique({
      where: { id: allocation.body.allocation.id },
    });
    expect(current.status).toBe('DELIVERED');
  });

  test('11. responder becomes AVAILABLE after final delivery', async () => {
    const emergency = await createEmergency([{ resourceId: blood.id, quantity: 1 }]);
    await accept(emergency.id);
    const allocation = await createAllocation(emergency.id, bloodInventory, blood);
    await dispatch(allocation.body.allocation.id);
    await received(allocation.body.allocation.id);

    expect((await prisma.user.findUnique({ where: { id: responder.id } })).responderStatus).toBe('AVAILABLE');
  });

  test('12. multi-resource delivery keeps responder BUSY until all work finishes', async () => {
    await request(app)
      .patch(`/api/responder-resources/${fireInventory.id}`)
      .set('Authorization', `Bearer ${responderToken}`)
      .send({ isEnabled: true, status: 'AVAILABLE', availableQuantity: 10 });
    const emergency = await createEmergency([
      { resourceId: blood.id, quantity: 1 },
      { resourceId: fire.id, quantity: 1 },
    ]);
    await accept(emergency.id);
    const bloodAllocation = await createAllocation(emergency.id, bloodInventory, blood);
    const fireAllocation = await createAllocation(emergency.id, fireInventory, fire);
    await dispatch(bloodAllocation.body.allocation.id);
    await dispatch(fireAllocation.body.allocation.id);
    await received(bloodAllocation.body.allocation.id);

    expect((await prisma.user.findUnique({ where: { id: responder.id } })).responderStatus).toBe('BUSY');

    await received(fireAllocation.body.allocation.id);
    expect((await prisma.user.findUnique({ where: { id: responder.id } })).responderStatus).toBe('AVAILABLE');
  });

  test('13. cancellation restores inventory', async () => {
    const emergency = await createEmergency([{ resourceId: blood.id, quantity: 2 }]);
    await accept(emergency.id);
    await createAllocation(emergency.id, bloodInventory, blood, 2);
    const cancelled = await request(app)
      .patch(`/api/requests/${emergency.id}/cancel`)
      .set('Authorization', `Bearer ${requesterToken}`);

    expect(cancelled.statusCode).toBe(200);
    expect((await prisma.responderResource.findUnique({ where: { id: bloodInventory.id } })).availableQuantity).toBe(10);
  });

  test('14. delivery does not restore inventory', async () => {
    const emergency = await createEmergency([{ resourceId: blood.id, quantity: 2 }]);
    await accept(emergency.id);
    const allocation = await createAllocation(emergency.id, bloodInventory, blood, 2);
    await dispatch(allocation.body.allocation.id);
    await received(allocation.body.allocation.id);

    expect((await prisma.responderResource.findUnique({ where: { id: bloodInventory.id } })).availableQuantity).toBe(8);
  });

  test('15. unselected resource cannot make request compatible', async () => {
    const emergency = await createEmergency([{ resourceId: fire.id, quantity: 1 }]);
    const response = await request(app)
      .get('/api/requests/compatible')
      .set('Authorization', `Bearer ${responderToken}`);

    expect(response.body.requests.map((item) => item.id)).not.toContain(emergency.id);
  });

  test('16. zero inventory cannot make request compatible', async () => {
    await request(app)
      .patch(`/api/responder-resources/${bloodInventory.id}`)
      .set('Authorization', `Bearer ${responderToken}`)
      .send({ availableQuantity: 0, isEnabled: true });
    const emergency = await createEmergency([{ resourceId: blood.id, quantity: 1 }]);
    const response = await request(app)
      .get('/api/requests/compatible')
      .set('Authorization', `Bearer ${responderToken}`);

    expect(response.body.requests.map((item) => item.id)).not.toContain(emergency.id);
  });

  test('17. inactive resource cannot match', async () => {
    await prisma.resource.update({ where: { id: blood.id }, data: { isActive: false } });
    const emergency = await createEmergency([{ resourceId: blood.id, quantity: 1 }]);
    const response = await request(app)
      .get('/api/requests/compatible')
      .set('Authorization', `Bearer ${responderToken}`);

    expect(response.body.requests.map((item) => item.id)).not.toContain(emergency.id);
  });

  test('18. inactive responder cannot accept', async () => {
    const emergency = await createEmergency([{ resourceId: blood.id, quantity: 1 }]);
    await prisma.user.update({ where: { id: responder.id }, data: { isActive: false } });

    const response = await accept(emergency.id);
    expect(response.statusCode).not.toBe(200);
  });

  test('19. requester cannot confirm another user allocation', async () => {
    const emergency = await createEmergency([{ resourceId: blood.id, quantity: 1 }]);
    await accept(emergency.id);
    const allocation = await createAllocation(emergency.id, bloodInventory, blood);
    await dispatch(allocation.body.allocation.id);

    const response = await received(allocation.body.allocation.id, otherRequesterToken);
    expect(response.statusCode).not.toBe(200);
  });

  test('20. duplicate receipt confirmation is rejected safely', async () => {
    const emergency = await createEmergency([{ resourceId: blood.id, quantity: 1 }]);
    await accept(emergency.id);
    const allocation = await createAllocation(emergency.id, bloodInventory, blood);
    await dispatch(allocation.body.allocation.id);
    expect((await received(allocation.body.allocation.id)).statusCode).toBe(200);

    const duplicate = await received(allocation.body.allocation.id);
    expect(duplicate.statusCode).not.toBe(200);
    expect((await prisma.allocation.findUnique({ where: { id: allocation.body.allocation.id } })).status).toBe('DELIVERED');
  });
});
