const request = require('supertest');
const jwt = require('jsonwebtoken');

const app = require('../../src/app');
const prisma = require('../../src/config/prisma');
const env = require('../../src/config/env');
const allocationService = require('../../src/services/allocationService');
const requestService = require('../../src/services/requestService');

/**
 * Regression suite for the two connected catalog-resource bugs.
 *
 * Bug 1 - dashboard visibility:
 *   A catalog CONSUMABLE emergency (e.g. Oxygen Cylinder) is created but never
 *   reaches an eligible responder's board. Cases 1-4 pin the existing matching
 *   gates end to end (help-type responders, legacy inventory-only responders,
 *   category exclusion, and the BUSY -> released re-visibility path). Eligibility
 *   stays entirely server-side; nothing is broadcast to every responder.
 *
 * Bug 2 - delivery consumption:
 *   ResponderResource.totalQuantity was never decremented after delivery.
 *   Cases 5-12 pin the lifecycle
 *     2/2 -> reserve 1 -> 2/1 -> deliver -> 1/1
 *     2/2 -> reserve 2 -> 2/0 -> deliver -> 0/0
 *   across both legal delivery paths, with exactly-once consumption, cancel
 *   semantics that never touch total, SERVICE resources that are never spent,
 *   and outstanding-quantity gating.
 */
describe('Catalog resource inventory request/fulfilment/delivery regression', () => {
  const emails = [
    'cir-requester@test.com',
    'cir-modern@test.com',
    'cir-legacy@test.com',
    'cir-fire@test.com',
  ];
  const resourceNames = ['CIR Oxygen Cylinder', 'CIR Ambulance Service'];

  let requester;
  let modernResponder; // MEDICAL help type + oxygen stock + ambulance capability
  let legacyResponder; // no help types, inventory-only matching
  let fireResponder; // FIRE help type only (negative case)

  let tokens;
  let oxygen; // CONSUMABLE catalog resource
  let ambulance; // SERVICE catalog resource
  let oxygenRowModern;
  let oxygenRowLegacy;
  let ambulanceRow;

  function tokenFor(user) {
    return jwt.sign(
      { userId: user.id, role: user.role },
      env.JWT_SECRET,
      { expiresIn: '1h' }
    );
  }

  async function cleanup() {
    await prisma.allocation.deleteMany({
      where: {
        OR: [
          { responder: { email: { in: emails } } },
          { request: { requester: { email: emails[0] } } },
        ],
      },
    });
    await prisma.responderAssignment.deleteMany({
      where: { responder: { email: { in: emails } } },
    });
    await prisma.requestResource.deleteMany({
      where: { request: { requester: { email: emails[0] } } },
    });
    await prisma.emergencyRequest.deleteMany({
      where: { requester: { email: emails[0] } },
    });
    await prisma.responderResource.deleteMany({
      where: { responder: { email: { in: emails } } },
    });
    await prisma.responderHelpType.deleteMany({
      where: { responder: { email: { in: emails } } },
    });
    await prisma.resource.deleteMany({ where: { name: { in: resourceNames } } });
    await prisma.user.deleteMany({ where: { email: { in: emails } } });
  }

  beforeAll(async () => {
    await cleanup();

    requester = await prisma.user.create({
      data: {
        name: 'CIR Requester',
        email: emails[0],
        password: 'test-password',
        role: 'REQUESTER',
        isActive: true,
      },
    });
    modernResponder = await prisma.user.create({
      data: {
        name: 'CIR Modern Responder',
        email: emails[1],
        password: 'test-password',
        role: 'RESPONDER',
        isActive: true,
        responderStatus: 'AVAILABLE',
      },
    });
    legacyResponder = await prisma.user.create({
      data: {
        name: 'CIR Legacy Responder',
        email: emails[2],
        password: 'test-password',
        role: 'RESPONDER',
        isActive: true,
        responderStatus: 'AVAILABLE',
      },
    });
    fireResponder = await prisma.user.create({
      data: {
        name: 'CIR Fire Responder',
        email: emails[3],
        password: 'test-password',
        role: 'RESPONDER',
        isActive: true,
        responderStatus: 'AVAILABLE',
      },
    });

    tokens = {
      requester: tokenFor(requester),
      modern: tokenFor(modernResponder),
      legacy: tokenFor(legacyResponder),
      fire: tokenFor(fireResponder),
    };

    await prisma.responderHelpType.createMany({
      data: [
        { responderId: modernResponder.id, category: 'MEDICAL', enabled: true },
        { responderId: fireResponder.id, category: 'FIRE', enabled: true },
      ],
    });

    // Catalog quantities are administrative only; responder inventory is the
    // real stock. Both modes are exercised below.
    oxygen = await prisma.resource.create({
      data: {
        name: resourceNames[0],
        type: 'OXYGEN',
        mode: 'CONSUMABLE',
        totalQuantity: 0,
        availableQuantity: 0,
        unit: 'cylinder',
        isActive: true,
      },
    });
    ambulance = await prisma.resource.create({
      data: {
        name: resourceNames[1],
        type: 'AMBULANCE',
        mode: 'SERVICE',
        totalQuantity: 0,
        availableQuantity: 0,
        unit: 'trip',
        isActive: true,
      },
    });

    oxygenRowModern = await prisma.responderResource.create({
      data: {
        responderId: modernResponder.id,
        resourceId: oxygen.id,
        totalQuantity: 5,
        availableQuantity: 5,
        isEnabled: true,
        status: 'AVAILABLE',
      },
    });
    oxygenRowLegacy = await prisma.responderResource.create({
      data: {
        responderId: legacyResponder.id,
        resourceId: oxygen.id,
        totalQuantity: 5,
        availableQuantity: 5,
        isEnabled: true,
        status: 'AVAILABLE',
      },
    });
    ambulanceRow = await prisma.responderResource.create({
      data: {
        responderId: modernResponder.id,
        resourceId: ambulance.id,
        totalQuantity: 0,
        availableQuantity: 0,
        isEnabled: true,
        status: 'UNAVAILABLE',
      },
    });
  });

  afterEach(async () => {
    await prisma.allocation.deleteMany({
      where: { request: { requester: { email: emails[0] } } },
    });
    await prisma.responderAssignment.deleteMany({
      where: { responder: { email: { in: emails } } },
    });
    await prisma.requestResource.deleteMany({
      where: { request: { requester: { email: emails[0] } } },
    });
    await prisma.emergencyRequest.deleteMany({
      where: { requester: { email: emails[0] } },
    });

    await prisma.responderResource.update({
      where: { id: oxygenRowModern.id },
      data: { totalQuantity: 5, availableQuantity: 5, status: 'AVAILABLE' },
    });
    await prisma.responderResource.update({
      where: { id: oxygenRowLegacy.id },
      data: { totalQuantity: 5, availableQuantity: 5, status: 'AVAILABLE' },
    });
    await prisma.responderResource.update({
      where: { id: ambulanceRow.id },
      data: { totalQuantity: 0, availableQuantity: 0, status: 'UNAVAILABLE' },
    });
    await prisma.user.updateMany({
      where: { email: { in: emails.slice(1) } },
      data: { responderStatus: 'AVAILABLE' },
    });
  });

  afterAll(async () => {
    await cleanup();
    await prisma.$disconnect();
  });

  // -------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------
  async function createOxygenEmergency(quantity = 1) {
    const res = await request(app)
      .post('/api/requests')
      .set('Authorization', `Bearer ${tokens.requester}`)
      .send({
        emergencyType: 'Medical',
        description: 'CIR oxygen emergency',
        location: 'Kochi',
        priority: 'HIGH',
        requiredResources: [{ resourceId: oxygen.id, quantity }],
      });
    expect(res.statusCode).toBe(201);
    return res.body.request;
  }

  async function compatibleIds(token) {
    const res = await request(app)
      .get('/api/requests/compatible')
      .set('Authorization', `Bearer ${token}`);
    expect(res.statusCode).toBe(200);
    return res.body.requests.map((row) => row.id);
  }

  async function stockOf(rowId) {
    const row = await prisma.responderResource.findUnique({
      where: { id: rowId },
    });
    return {
      total: row.totalQuantity,
      available: row.availableQuantity,
      status: row.status,
    };
  }

  async function createPendingRequest(quantity) {
    return prisma.emergencyRequest.create({
      data: {
        requesterId: requester.id,
        emergencyType: 'Medical',
        description: 'CIR service-level emergency',
        location: 'Kochi',
        priority: 'HIGH',
        status: 'PENDING',
        requiredResources: {
          create: [{ resourceId: oxygen.id, quantity }],
        },
      },
    });
  }

  async function expectRejects(promise, message) {
    await expect(promise).rejects.toThrow(message);
  }

  // =============================================================
  // BUG 1: eligible responder dashboards (cases 1-4)
  // =============================================================
  test('1: help-type responder sees a new catalog CONSUMABLE emergency on their board', async () => {
    const emergency = await createOxygenEmergency(1);
    const ids = await compatibleIds(tokens.modern);
    expect(ids).toContain(emergency.id);
  });

  test('2: legacy inventory-only responder sees the same emergency via stock matching', async () => {
    const emergency = await createOxygenEmergency(1);
    const ids = await compatibleIds(tokens.legacy);
    expect(ids).toContain(emergency.id);
  });

  test('3: a responder whose help categories do not match never sees the emergency', async () => {
    const emergency = await createOxygenEmergency(1);
    const ids = await compatibleIds(tokens.fire);
    expect(ids).not.toContain(emergency.id);
  });

  test('4: BUSY responder is excluded, then regains the pending emergency after their assignment ends', async () => {
    // A prior, already-accepted emergency keeps the legacy responder BUSY.
    const prior = await prisma.emergencyRequest.create({
      data: {
        requesterId: requester.id,
        emergencyType: 'Medical',
        description: 'CIR prior emergency',
        location: 'Kochi',
        priority: 'HIGH',
        status: 'IN_PROGRESS',
        acceptedById: legacyResponder.id,
      },
    });
    await prisma.responderAssignment.create({
      data: {
        requestId: prior.id,
        responderId: legacyResponder.id,
        status: 'ACTIVE',
        acceptedAt: new Date(),
      },
    });
    await prisma.user.update({
      where: { id: legacyResponder.id },
      data: { responderStatus: 'BUSY' },
    });

    const emergency = await createOxygenEmergency(1);
    expect(await compatibleIds(tokens.legacy)).not.toContain(emergency.id);

    // Ending the assignment re-derives AVAILABLE (never a client-forced flag).
    const end = await request(app)
      .patch(`/api/requests/${prior.id}/assignment/end`)
      .set('Authorization', `Bearer ${tokens.legacy}`);
    expect(end.statusCode).toBe(200);

    const freed = await prisma.user.findUnique({
      where: { id: legacyResponder.id },
    });
    expect(freed.responderStatus).toBe('AVAILABLE');
    expect(await compatibleIds(tokens.legacy)).toContain(emergency.id);
  });

  // =============================================================
  // BUG 2: delivery consumption lifecycle (cases 5-12)
  // =============================================================
  test('5: 2/2 -> reserve 1 -> 2/1 -> responder delivers -> 1/1', async () => {
    await prisma.responderResource.update({
      where: { id: oxygenRowModern.id },
      data: { totalQuantity: 2, availableQuantity: 2, status: 'AVAILABLE' },
    });
    const emergency = await createPendingRequest(1);

    const reserved = await allocationService.createAllocation(
      modernResponder.id,
      {
        requestId: emergency.id,
        responderResourceId: oxygenRowModern.id,
        resourceId: oxygen.id,
        quantity: 1,
      }
    );
    await expect(stockOf(oxygenRowModern.id)).resolves.toMatchObject({
      total: 2,
      available: 1,
    });

    const dispatched = await allocationService.updateAllocationStatus(
      modernResponder.id,
      reserved.id,
      'DISPATCHED'
    );
    // Dispatch moves no inventory at all.
    await expect(stockOf(oxygenRowModern.id)).resolves.toMatchObject({
      total: 2,
      available: 1,
    });

    await allocationService.updateAllocationStatus(
      modernResponder.id,
      dispatched.id,
      'DELIVERED'
    );
    await expect(stockOf(oxygenRowModern.id)).resolves.toMatchObject({
      total: 1,
      available: 1,
    });
  });

  test('6: reserving and delivering the full 2 units ends at 0/0 with UNAVAILABLE stock', async () => {
    await prisma.responderResource.update({
      where: { id: oxygenRowModern.id },
      data: { totalQuantity: 2, availableQuantity: 2, status: 'AVAILABLE' },
    });
    const emergency = await createPendingRequest(2);

    const reserved = await allocationService.createAllocation(
      modernResponder.id,
      {
        requestId: emergency.id,
        responderResourceId: oxygenRowModern.id,
        resourceId: oxygen.id,
        quantity: 2,
      }
    );
    expect(await stockOf(oxygenRowModern.id)).toMatchObject({
      total: 2,
      available: 0,
      status: 'UNAVAILABLE',
    });

    const dispatched = await allocationService.updateAllocationStatus(
      modernResponder.id,
      reserved.id,
      'DISPATCHED'
    );
    await allocationService.updateAllocationStatus(
      modernResponder.id,
      dispatched.id,
      'DELIVERED'
    );
    expect(await stockOf(oxygenRowModern.id)).toMatchObject({
      total: 0,
      available: 0,
      status: 'UNAVAILABLE',
    });
  });

  test('7: requester receipt path consumes total identically and never restores available', async () => {
    const emergency = await createPendingRequest(1);

    const reserved = await allocationService.createAllocation(
      modernResponder.id,
      {
        requestId: emergency.id,
        responderResourceId: oxygenRowModern.id,
        resourceId: oxygen.id,
        quantity: 1,
      }
    );
    const dispatched = await allocationService.updateAllocationStatus(
      modernResponder.id,
      reserved.id,
      'DISPATCHED'
    );
    expect(await stockOf(oxygenRowModern.id)).toMatchObject({
      total: 5,
      available: 4,
    });

    await allocationService.confirmAllocationReceived(
      requester.id,
      dispatched.id
    );
    expect(await stockOf(oxygenRowModern.id)).toMatchObject({
      total: 4,
      available: 4,
    });
  });

  test('8: repeated responder delivery is rejected and deducts exactly once', async () => {
    await prisma.responderResource.update({
      where: { id: oxygenRowModern.id },
      data: { totalQuantity: 2, availableQuantity: 2, status: 'AVAILABLE' },
    });
    const emergency = await createPendingRequest(1);

    const reserved = await allocationService.createAllocation(
      modernResponder.id,
      {
        requestId: emergency.id,
        responderResourceId: oxygenRowModern.id,
        resourceId: oxygen.id,
        quantity: 1,
      }
    );
    const dispatched = await allocationService.updateAllocationStatus(
      modernResponder.id,
      reserved.id,
      'DISPATCHED'
    );
    await allocationService.updateAllocationStatus(
      modernResponder.id,
      dispatched.id,
      'DELIVERED'
    );

    await expectRejects(
      allocationService.updateAllocationStatus(
        modernResponder.id,
        dispatched.id,
        'DELIVERED'
      ),
      'Already delivered'
    );
    expect(await stockOf(oxygenRowModern.id)).toMatchObject({
      total: 1,
      available: 1,
    });
  });

  test('9: cross-path confirmation (receipt then responder delivery) consumes only once', async () => {
    await prisma.responderResource.update({
      where: { id: oxygenRowModern.id },
      data: { totalQuantity: 2, availableQuantity: 2, status: 'AVAILABLE' },
    });
    const emergency = await createPendingRequest(1);

    const reserved = await allocationService.createAllocation(
      modernResponder.id,
      {
        requestId: emergency.id,
        responderResourceId: oxygenRowModern.id,
        resourceId: oxygen.id,
        quantity: 1,
      }
    );
    const dispatched = await allocationService.updateAllocationStatus(
      modernResponder.id,
      reserved.id,
      'DISPATCHED'
    );
    await allocationService.confirmAllocationReceived(
      requester.id,
      dispatched.id
    );

    await expectRejects(
      allocationService.updateAllocationStatus(
        modernResponder.id,
        dispatched.id,
        'DELIVERED'
      ),
      'Already delivered'
    );
    expect(await stockOf(oxygenRowModern.id)).toMatchObject({
      total: 1,
      available: 1,
    });
  });

  test('10: cancellation restores available quantity but never touches total', async () => {
    const emergency = await createPendingRequest(1);

    const reserved = await allocationService.createAllocation(
      modernResponder.id,
      {
        requestId: emergency.id,
        responderResourceId: oxygenRowModern.id,
        resourceId: oxygen.id,
        quantity: 1,
      }
    );
    expect(await stockOf(oxygenRowModern.id)).toMatchObject({
      total: 5,
      available: 4,
    });

    await allocationService.updateAllocationStatus(
      modernResponder.id,
      reserved.id,
      'CANCELLED'
    );
    expect(await stockOf(oxygenRowModern.id)).toMatchObject({
      total: 5,
      available: 5,
      status: 'AVAILABLE',
    });
  });

  test('11: SERVICE capabilities are never consumed by reserve, dispatch, or delivery', async () => {
    const emergency = await prisma.emergencyRequest.create({
      data: {
        requesterId: requester.id,
        emergencyType: 'Medical',
        description: 'CIR service emergency',
        location: 'Kochi',
        priority: 'HIGH',
        status: 'PENDING',
        requiredResources: {
          create: [{ resourceId: ambulance.id, quantity: 1 }],
        },
      },
    });

    const reserved = await allocationService.createAllocation(
      modernResponder.id,
      {
        requestId: emergency.id,
        responderResourceId: ambulanceRow.id,
        resourceId: ambulance.id,
        quantity: 1,
      }
    );
    const dispatched = await allocationService.updateAllocationStatus(
      modernResponder.id,
      reserved.id,
      'DISPATCHED'
    );
    await allocationService.updateAllocationStatus(
      modernResponder.id,
      dispatched.id,
      'DELIVERED'
    );

    expect(await stockOf(ambulanceRow.id)).toMatchObject({
      total: 0,
      available: 0,
    });
  });

  test('12: create/accept/reserve/dispatch never deduct total and outstanding quantity gates allocation', async () => {
    const emergency = await createOxygenEmergency(2);
    // Creating the request spends no responder stock.
    expect(await stockOf(oxygenRowModern.id)).toMatchObject({
      total: 5,
      available: 5,
    });

    await requestService.acceptEmergencyRequest(modernResponder.id, emergency.id);
    expect(await stockOf(oxygenRowModern.id)).toMatchObject({
      total: 5,
      available: 5,
    });

    const first = await allocationService.createAllocation(modernResponder.id, {
      requestId: emergency.id,
      responderResourceId: oxygenRowModern.id,
      resourceId: oxygen.id,
      quantity: 1,
    });
    await allocationService.updateAllocationStatus(
      modernResponder.id,
      first.id,
      'DISPATCHED'
    );
    // Only reservation moved available; total is still untouched pre-delivery.
    expect(await stockOf(oxygenRowModern.id)).toMatchObject({
      total: 5,
      available: 4,
    });

    await expectRejects(
      allocationService.createAllocation(modernResponder.id, {
        requestId: emergency.id,
        responderResourceId: oxygenRowModern.id,
        resourceId: oxygen.id,
        quantity: 2,
      }),
      'Allocation exceeds the remaining required quantity (1 left)'
    );

    await allocationService.createAllocation(modernResponder.id, {
      requestId: emergency.id,
      responderResourceId: oxygenRowModern.id,
      resourceId: oxygen.id,
      quantity: 1,
    });
    await expectRejects(
      allocationService.createAllocation(modernResponder.id, {
        requestId: emergency.id,
        responderResourceId: oxygenRowModern.id,
        resourceId: oxygen.id,
        quantity: 1,
      }),
      'This resource is already fully allocated'
    );

    // Rejected allocations must not have moved any inventory.
    expect(await stockOf(oxygenRowModern.id)).toMatchObject({
      total: 5,
      available: 3,
    });
  });
});
