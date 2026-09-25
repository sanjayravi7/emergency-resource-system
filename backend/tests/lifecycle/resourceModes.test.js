const request = require('supertest');
const jwt = require('jsonwebtoken');

const app = require('../../src/app');
const prisma = require('../../src/config/prisma');
const env = require('../../src/config/env');

// These tests are additive: they exercise the SERVICE/CONSUMABLE resource
// mode split (spec items 3-13, 16) and the new GET /api/resources/availability
// endpoint (spec item 6). They do not modify or remove any pre-existing test
// in readinessLifecycle.test.js or elsewhere.
describe('Resource modes (SERVICE vs CONSUMABLE) and availability', () => {
  const suffix = `modes-${Date.now()}`;
  let requester;
  let responderIds = [];
  let userIds = [];
  let resourceIds = [];

  const userEmail = (kind) => `${suffix}-${kind}-${Math.random().toString(36).slice(2)}@test.invalid`;

  const tokenFor = (user) =>
    jwt.sign({ userId: user.id, role: user.role }, env.JWT_SECRET, {
      expiresIn: '1h',
    });

  async function createResponder(name, { isActive = true } = {}) {
    const user = await prisma.user.create({
      data: {
        name,
        email: userEmail(name.replace(/\s+/g, '-')),
        password: 'not-used',
        role: 'RESPONDER',
        isActive,
        responderStatus: isActive ? 'AVAILABLE' : 'OFFLINE',
      },
    });
    userIds.push(user.id);
    responderIds.push(user.id);
    return user;
  }

  async function createRequester() {
    const user = await prisma.user.create({
      data: {
        name: 'Modes requester',
        email: userEmail('requester'),
        password: 'not-used',
        role: 'REQUESTER',
      },
    });
    userIds.push(user.id);
    return user;
  }

  async function createResource(name, mode, extra = {}) {
    const resource = await prisma.resource.create({
      data: {
        name: `${suffix}-${name}-${Date.now()}-${Math.random()}`,
        type: name.toUpperCase(),
        mode,
        totalQuantity: 0,
        availableQuantity: 0,
        unit: 'unit',
        isActive: true,
        ...extra,
      },
    });
    resourceIds.push(resource.id);
    return resource;
  }

  async function enableCapability(responder, resource, extra = {}) {
    return prisma.responderResource.create({
      data: {
        responderId: responder.id,
        resourceId: resource.id,
        totalQuantity: 0,
        availableQuantity: 0,
        isEnabled: true,
        status: 'AVAILABLE',
        ...extra,
      },
    });
  }

  async function createEmergency(requesterUser, requiredResources) {
    return prisma.emergencyRequest.create({
      data: {
        requesterId: requesterUser.id,
        emergencyType: 'Resource mode test',
        description: 'Resource mode verification',
        location: 'Test location',
        priority: 'HIGH',
        status: 'PENDING',
        requiredResources: { create: requiredResources },
      },
    });
  }

  async function accept(emergencyId, responderToken) {
    return request(app)
      .patch(`/api/requests/${emergencyId}/accept`)
      .set('Authorization', `Bearer ${responderToken}`);
  }

  async function createAllocation(responderToken, requestId, inventory, resource, quantity = 1) {
    return request(app)
      .post('/api/allocations')
      .set('Authorization', `Bearer ${responderToken}`)
      .send({ requestId, responderResourceId: inventory.id, resourceId: resource.id, quantity });
  }

  async function dispatch(responderToken, allocationId) {
    return request(app)
      .patch(`/api/allocations/${allocationId}/status`)
      .set('Authorization', `Bearer ${responderToken}`)
      .send({ status: 'DISPATCHED' });
  }

  async function received(requesterToken, allocationId) {
    return request(app)
      .patch(`/api/allocations/${allocationId}/received`)
      .set('Authorization', `Bearer ${requesterToken}`);
  }

  async function getAvailability(token) {
    return request(app)
      .get('/api/resources/availability')
      .set('Authorization', `Bearer ${token}`);
  }

  beforeEach(() => {
    responderIds = [];
    userIds = [];
    resourceIds = [];
  });

  afterEach(async () => {
    await prisma.allocation.deleteMany({ where: { responderId: { in: responderIds } } });
    await prisma.requestResource.deleteMany({ where: { resourceId: { in: resourceIds } } });
    await prisma.emergencyRequest.deleteMany({ where: { requesterId: { in: userIds } } });
    await prisma.responderResource.deleteMany({ where: { responderId: { in: responderIds } } });
    await prisma.resource.deleteMany({ where: { id: { in: resourceIds } } });
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
  });

  // ----------------------------------------------------------------
  // SERVICE resources are reusable and never decrement quantity
  // ----------------------------------------------------------------

  test('SERVICE resource is reusable across sequential requests without ever being depleted', async () => {
    const requesterUser = await createRequester();
    const requesterToken = tokenFor(requesterUser);
    const responder = await createResponder('Ambulance responder');
    const responderToken = tokenFor(responder);
    const ambulance = await createResource('Ambulance', 'SERVICE');
    const inventory = await enableCapability(responder, ambulance);

    // First full cycle.
    const first = await createEmergency(requesterUser, [{ resourceId: ambulance.id, quantity: 1 }]);
    expect((await accept(first.id, responderToken)).statusCode).toBe(200);
    const firstAllocation = await createAllocation(responderToken, first.id, inventory, ambulance);
    expect(firstAllocation.statusCode).toBe(201);
    expect(firstAllocation.body.allocation.status).toBe('RESERVED');
    await dispatch(responderToken, firstAllocation.body.allocation.id);
    await received(requesterToken, firstAllocation.body.allocation.id);

    const afterFirst = await prisma.responderResource.findUnique({ where: { id: inventory.id } });
    expect(afterFirst.availableQuantity).toBe(0); // untouched, never had quantity to begin with
    expect((await prisma.user.findUnique({ where: { id: responder.id } })).responderStatus).toBe('AVAILABLE');
    expect((await prisma.emergencyRequest.findUnique({ where: { id: first.id } })).status).toBe('COMPLETED');

    // Second full cycle using the exact same responder + capability again.
    const second = await createEmergency(requesterUser, [{ resourceId: ambulance.id, quantity: 1 }]);
    expect((await accept(second.id, responderToken)).statusCode).toBe(200);
    const secondAllocation = await createAllocation(responderToken, second.id, inventory, ambulance);
    expect(secondAllocation.statusCode).toBe(201);
    await dispatch(responderToken, secondAllocation.body.allocation.id);
    await received(requesterToken, secondAllocation.body.allocation.id);

    const afterSecond = await prisma.responderResource.findUnique({ where: { id: inventory.id } });
    expect(afterSecond.availableQuantity).toBe(0);
    expect((await prisma.emergencyRequest.findUnique({ where: { id: second.id } })).status).toBe('COMPLETED');
  });

  test('accepting a SERVICE request transitions AVAILABLE -> BUSY without decrementing quantity', async () => {
    const requesterUser = await createRequester();
    const responder = await createResponder('Volunteer responder');
    const responderToken = tokenFor(responder);
    const volunteer = await createResource('Volunteer', 'SERVICE');
    const inventory = await enableCapability(responder, volunteer);

    const emergency = await createEmergency(requesterUser, [{ resourceId: volunteer.id, quantity: 1 }]);
    const acceptResponse = await accept(emergency.id, responderToken);

    expect(acceptResponse.statusCode).toBe(200);
    expect((await prisma.user.findUnique({ where: { id: responder.id } })).responderStatus).toBe('BUSY');
    expect((await prisma.responderResource.findUnique({ where: { id: inventory.id } })).availableQuantity).toBe(0);
  });

  // ----------------------------------------------------------------
  // CONSUMABLE resources keep inventory semantics
  // ----------------------------------------------------------------

  test('CONSUMABLE allocation decreases inventory, cancellation restores it, delivery does not', async () => {
    const requesterUser = await createRequester();
    const requesterToken = tokenFor(requesterUser);
    const responder = await createResponder('Blood responder');
    const responderToken = tokenFor(responder);
    const blood = await createResource('Blood', 'CONSUMABLE');
    const inventory = await enableCapability(responder, blood, { totalQuantity: 10, availableQuantity: 10 });

    const emergency = await createEmergency(requesterUser, [{ resourceId: blood.id, quantity: 3 }]);
    await accept(emergency.id, responderToken);
    const allocation = await createAllocation(responderToken, emergency.id, inventory, blood, 3);
    expect(allocation.statusCode).toBe(201);
    expect((await prisma.responderResource.findUnique({ where: { id: inventory.id } })).availableQuantity).toBe(7);

    await dispatch(responderToken, allocation.body.allocation.id);
    await received(requesterToken, allocation.body.allocation.id);
    expect((await prisma.responderResource.findUnique({ where: { id: inventory.id } })).availableQuantity).toBe(7);
  });

  test('cancelling a CONSUMABLE request before delivery restores inventory', async () => {
    const requesterUser = await createRequester();
    const requesterToken = tokenFor(requesterUser);
    const responder = await createResponder('Oxygen responder');
    const responderToken = tokenFor(responder);
    const oxygen = await createResource('Oxygen', 'CONSUMABLE');
    const inventory = await enableCapability(responder, oxygen, { totalQuantity: 10, availableQuantity: 10 });

    const emergency = await createEmergency(requesterUser, [{ resourceId: oxygen.id, quantity: 4 }]);
    await accept(emergency.id, responderToken);
    await createAllocation(responderToken, emergency.id, inventory, oxygen, 4);
    expect((await prisma.responderResource.findUnique({ where: { id: inventory.id } })).availableQuantity).toBe(6);

    const cancelled = await request(app)
      .patch(`/api/requests/${emergency.id}/cancel`)
      .set('Authorization', `Bearer ${requesterToken}`);
    expect(cancelled.statusCode).toBe(200);
    expect((await prisma.responderResource.findUnique({ where: { id: inventory.id } })).availableQuantity).toBe(10);
  });

  // ----------------------------------------------------------------
  // Request completion status must reflect delivery, never reservation
  // ----------------------------------------------------------------

  test('RESERVED allocation alone never completes the request', async () => {
    const requesterUser = await createRequester();
    const responder = await createResponder('Water responder');
    const responderToken = tokenFor(responder);
    const water = await createResource('Water', 'CONSUMABLE');
    const inventory = await enableCapability(responder, water, { totalQuantity: 10, availableQuantity: 10 });

    const emergency = await createEmergency(requesterUser, [{ resourceId: water.id, quantity: 1 }]);
    await accept(emergency.id, responderToken);
    const allocation = await createAllocation(responderToken, emergency.id, inventory, water, 1);
    expect(allocation.body.allocation.status).toBe('RESERVED');

    const current = await prisma.emergencyRequest.findUnique({ where: { id: emergency.id } });
    expect(current.status).not.toBe('COMPLETED');
  });

  test('DISPATCHED allocation alone never completes the request', async () => {
    const requesterUser = await createRequester();
    const responder = await createResponder('Medicine responder');
    const responderToken = tokenFor(responder);
    const medicine = await createResource('Medicine', 'CONSUMABLE');
    const inventory = await enableCapability(responder, medicine, { totalQuantity: 10, availableQuantity: 10 });

    const emergency = await createEmergency(requesterUser, [{ resourceId: medicine.id, quantity: 1 }]);
    await accept(emergency.id, responderToken);
    const allocation = await createAllocation(responderToken, emergency.id, inventory, medicine, 1);
    await dispatch(responderToken, allocation.body.allocation.id);

    const current = await prisma.emergencyRequest.findUnique({ where: { id: emergency.id } });
    expect(current.status).not.toBe('COMPLETED');
  });

  test('request completes only once every required resource quantity is DELIVERED', async () => {
    const requesterUser = await createRequester();
    const requesterToken = tokenFor(requesterUser);
    const responder = await createResponder('Full delivery responder');
    const responderToken = tokenFor(responder);
    const rescueBoat = await createResource('RescueBoat', 'SERVICE');
    const inventory = await enableCapability(responder, rescueBoat);

    const emergency = await createEmergency(requesterUser, [{ resourceId: rescueBoat.id, quantity: 1 }]);
    await accept(emergency.id, responderToken);
    const allocation = await createAllocation(responderToken, emergency.id, inventory, rescueBoat);
    await dispatch(responderToken, allocation.body.allocation.id);
    await received(requesterToken, allocation.body.allocation.id);

    const current = await prisma.emergencyRequest.findUnique({ where: { id: emergency.id } });
    expect(current.status).toBe('COMPLETED');
  });

  test('multi-resource request stays incomplete until every required resource is fully DELIVERED', async () => {
    const requesterUser = await createRequester();
    const requesterToken = tokenFor(requesterUser);
    const responder = await createResponder('Multi resource responder');
    const responderToken = tokenFor(responder);
    const blood = await createResource('MultiBlood', 'CONSUMABLE');
    const fireResource = await createResource('MultiFire', 'SERVICE');
    const bloodInventory = await enableCapability(responder, blood, { totalQuantity: 10, availableQuantity: 10 });
    const fireInventory = await enableCapability(responder, fireResource);

    const emergency = await createEmergency(requesterUser, [
      { resourceId: blood.id, quantity: 2 },
      { resourceId: fireResource.id, quantity: 1 },
    ]);
    await accept(emergency.id, responderToken);
    const bloodAllocation = await createAllocation(responderToken, emergency.id, bloodInventory, blood, 2);
    const fireAllocation = await createAllocation(responderToken, emergency.id, fireInventory, fireResource, 1);

    await dispatch(responderToken, bloodAllocation.body.allocation.id);
    await received(requesterToken, bloodAllocation.body.allocation.id);

    // Blood fully delivered, fire still only RESERVED -> request incomplete,
    // responder still BUSY because of the unfinished fire allocation.
    let current = await prisma.emergencyRequest.findUnique({ where: { id: emergency.id } });
    expect(current.status).not.toBe('COMPLETED');
    expect((await prisma.user.findUnique({ where: { id: responder.id } })).responderStatus).toBe('BUSY');

    await dispatch(responderToken, fireAllocation.body.allocation.id);
    await received(requesterToken, fireAllocation.body.allocation.id);

    current = await prisma.emergencyRequest.findUnique({ where: { id: emergency.id } });
    expect(current.status).toBe('COMPLETED');
    expect((await prisma.user.findUnique({ where: { id: responder.id } })).responderStatus).toBe('AVAILABLE');
  });

  test('requester cannot confirm receipt for an allocation on someone else\u2019s request', async () => {
    const requesterUser = await createRequester();
    const strangerUser = await createRequester();
    const strangerToken = tokenFor(strangerUser);
    const responder = await createResponder('Ownership responder');
    const responderToken = tokenFor(responder);
    const ambulance = await createResource('OwnershipAmbulance', 'SERVICE');
    const inventory = await enableCapability(responder, ambulance);

    const emergency = await createEmergency(requesterUser, [{ resourceId: ambulance.id, quantity: 1 }]);
    await accept(emergency.id, responderToken);
    const allocation = await createAllocation(responderToken, emergency.id, inventory, ambulance);
    await dispatch(responderToken, allocation.body.allocation.id);

    const response = await received(strangerToken, allocation.body.allocation.id);
    expect(response.statusCode).not.toBe(200);
    expect((await prisma.allocation.findUnique({ where: { id: allocation.body.allocation.id } })).status).toBe(
      'DISPATCHED'
    );
  });

  // ----------------------------------------------------------------
  // GET /api/resources/availability
  // ----------------------------------------------------------------

  test('availability endpoint reports responder counts for SERVICE and inventory for CONSUMABLE', async () => {
    const requesterUser = await createRequester();
    const requesterToken = tokenFor(requesterUser);
    const ambulance = await createResource('AvailAmbulance', 'SERVICE');
    const water = await createResource('AvailWater', 'CONSUMABLE', { totalQuantity: 18, availableQuantity: 18 });

    const r1 = await createResponder('Avail responder 1');
    const r2 = await createResponder('Avail responder 2');
    const r3 = await createResponder('Avail responder 3');
    const r4 = await createResponder('Avail responder 4');
    await enableCapability(r1, ambulance);
    await enableCapability(r2, ambulance);
    await enableCapability(r3, ambulance);
    await enableCapability(r4, ambulance);

    const response = await getAvailability(requesterToken);
    expect(response.statusCode).toBe(200);

    const ambulanceRow = response.body.resources.find((row) => row.id === ambulance.id);
    expect(ambulanceRow.mode).toBe('SERVICE');
    expect(ambulanceRow.availableResponders).toBe(4);
    expect(ambulanceRow.availableQuantity).toBeNull();

    const waterRow = response.body.resources.find((row) => row.id === water.id);
    expect(waterRow.mode).toBe('CONSUMABLE');
    expect(waterRow.availableQuantity).toBe(18);
    expect(waterRow.availableResponders).toBeNull();
  });

  test('availability count decreases on acceptance and increases again after final delivery', async () => {
    const requesterUser = await createRequester();
    const requesterToken = tokenFor(requesterUser);
    const responder = await createResponder('Countable responder');
    const responderToken = tokenFor(responder);
    const other = await createResponder('Other countable responder');
    const ambulance = await createResource('CountAmbulance', 'SERVICE');
    const inventory = await enableCapability(responder, ambulance);
    await enableCapability(other, ambulance);

    const before = await getAvailability(requesterToken);
    expect(before.body.resources.find((row) => row.id === ambulance.id).availableResponders).toBe(2);

    const emergency = await createEmergency(requesterUser, [{ resourceId: ambulance.id, quantity: 1 }]);
    await accept(emergency.id, responderToken);

    const duringAcceptance = await getAvailability(requesterToken);
    expect(duringAcceptance.body.resources.find((row) => row.id === ambulance.id).availableResponders).toBe(1);

    const allocation = await createAllocation(responderToken, emergency.id, inventory, ambulance);
    await dispatch(responderToken, allocation.body.allocation.id);
    await received(requesterToken, allocation.body.allocation.id);

    const after = await getAvailability(requesterToken);
    expect(after.body.resources.find((row) => row.id === ambulance.id).availableResponders).toBe(2);
  });

  test('availability ignores disabled capabilities, inactive responders and inactive resources', async () => {
    const requesterUser = await createRequester();
    const requesterToken = tokenFor(requesterUser);
    const enabledResponder = await createResponder('Enabled visibility responder');
    const disabledResponder = await createResponder('Disabled visibility responder');
    const inactiveResponder = await createResponder('Inactive visibility responder', { isActive: false });
    const ambulance = await createResource('VisibilityAmbulance', 'SERVICE');
    const inactiveResource = await createResource('VisibilityInactiveResource', 'SERVICE', { isActive: false });

    await enableCapability(enabledResponder, ambulance);
    await enableCapability(disabledResponder, ambulance, { isEnabled: false });
    await enableCapability(inactiveResponder, ambulance);
    await enableCapability(enabledResponder, inactiveResource);

    const response = await getAvailability(requesterToken);
    const ambulanceRow = response.body.resources.find((row) => row.id === ambulance.id);
    expect(ambulanceRow.availableResponders).toBe(1);

    const inactiveRow = response.body.resources.find((row) => row.id === inactiveResource.id);
    expect(inactiveRow).toBeUndefined();
  });

  test('availability ignores a BUSY responder even though their capability stays enabled', async () => {
    const requesterUser = await createRequester();
    const requesterToken = tokenFor(requesterUser);
    const responder = await createResponder('Busy visibility responder');
    const responderToken = tokenFor(responder);
    const ambulance = await createResource('BusyVisibilityAmbulance', 'SERVICE');
    await enableCapability(responder, ambulance);

    const emergency = await createEmergency(requesterUser, [{ resourceId: ambulance.id, quantity: 1 }]);
    await accept(emergency.id, responderToken);

    const response = await getAvailability(requesterToken);
    expect(response.body.resources.find((row) => row.id === ambulance.id).availableResponders).toBe(0);
  });

  // ----------------------------------------------------------------
  // Concurrency safety
  // ----------------------------------------------------------------

  test('a responder cannot accept two different requests concurrently for the same SERVICE capability', async () => {
    const requesterUser = await createRequester();
    const responder = await createResponder('Concurrent responder');
    const responderToken = tokenFor(responder);
    const ambulance = await createResource('ConcurrentAmbulance', 'SERVICE');
    await enableCapability(responder, ambulance);

    const first = await createEmergency(requesterUser, [{ resourceId: ambulance.id, quantity: 1 }]);
    const second = await createEmergency(requesterUser, [{ resourceId: ambulance.id, quantity: 1 }]);

    const [firstResult, secondResult] = await Promise.all([
      accept(first.id, responderToken),
      accept(second.id, responderToken),
    ]);

    const outcomes = [firstResult.statusCode, secondResult.statusCode].sort();
    expect(outcomes).toEqual([200, 400]);

    const acceptedCount = await prisma.emergencyRequest.count({
      where: { id: { in: [first.id, second.id] }, status: 'ACCEPTED' },
    });
    expect(acceptedCount).toBe(1);
  });
});
