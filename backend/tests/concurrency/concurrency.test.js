// Load backend/.env first so a locally configured PostgreSQL test database is
// detected (same pattern as the socket integration suite).
require('dotenv').config();

const request = require('supertest');
const jwt = require('jsonwebtoken');

const app = require('../../src/app');
const prisma = require('../../src/config/prisma');
const env = require('../../src/config/env');

const hasDatabase = Boolean(process.env.DATABASE_URL && process.env.JWT_SECRET);

// Concurrency tests for transactional multi-responder ACCEPTANCE (Phase C).
//
// Every race here is a genuine parallel HTTP race against real PostgreSQL:
// the accept path runs inside the existing Serializable transaction with
// SELECT ... FOR UPDATE row locks and the serialization-failure retry
// wrapper, so these tests prove the database - not the frontend - is the
// authority.
//
// ARCHITECTURE NOTE (acceptance vs reservation): acceptance never reserves
// inventory. The Allocation row is the reservation/consumption step of this
// system (its transaction decrements CONSUMABLE stock and guards the
// outstanding quantity). Case C therefore proves that two responders may
// both ACCEPT while the final unit exists, but exactly one of them can
// ALLOCATE it - no fake inventory reservation is introduced at acceptance
// time.
(hasDatabase ? describe : describe.skip)(
  'Acceptance concurrency (Phase C)',
  () => {
    const runId = `conc-${Date.now()}`;

    let requester;
    let requesterToken;
    let blood;
    let fireTruck;
    const createdRequestIds = [];
    const responderIds = [];
    const tokens = {};

    function tokenFor(user) {
      return jwt.sign(
        { userId: user.id, role: user.role },
        env.JWT_SECRET,
        { expiresIn: '1h' }
      );
    }

    async function createResponder(name) {
      const user = await prisma.user.create({
        data: {
          name,
          email: `${runId}-${name.toLowerCase().replace(/\s+/g, '-')}@test.com`,
          password: 'test-password',
          role: 'RESPONDER',
          responderStatus: 'AVAILABLE',
          isActive: true,
        },
      });
      responderIds.push(user.id);
      tokens[user.id] = tokenFor(user);
      return user;
    }

    async function enableCapability(responderId, resourceId, options = {}) {
      return prisma.responderResource.create({
        data: {
          responderId,
          resourceId,
          totalQuantity: options.totalQuantity ?? 10,
          availableQuantity: options.availableQuantity ?? 10,
          isEnabled: true,
          status: options.status ?? 'AVAILABLE',
        },
      });
    }

    async function createEmergency(lines) {
      const emergency = await prisma.emergencyRequest.create({
        data: {
          requesterId: requester.id,
          emergencyType: 'Concurrent',
          location: 'Thrissur',
          priority: 'CRITICAL',
          status: 'PENDING',
          requiredResources: {
            create: lines.map((line) => ({
              resourceId: line.resourceId,
              quantity: line.quantity,
            })),
          },
        },
      });
      createdRequestIds.push(emergency.id);
      return emergency;
    }

    function accept(emergencyId, token) {
      return request(app)
        .patch(`/api/requests/${emergencyId}/accept`)
        .set('Authorization', `Bearer ${token}`);
    }

    beforeAll(async () => {
      requester = await prisma.user.create({
        data: {
          name: 'Concurrency Requester',
          email: `${runId}-requester@test.com`,
          password: 'test-password',
          role: 'REQUESTER',
          isActive: true,
        },
      });
      requesterToken = tokenFor(requester);

      blood = await prisma.resource.create({
        data: {
          name: `Conc Blood ${runId}`,
          type: 'Medical',
          totalQuantity: 100,
          availableQuantity: 100,
          unit: 'unit',
        },
      });
      fireTruck = await prisma.resource.create({
        data: {
          name: `Conc Fire Truck ${runId}`,
          type: 'Fire',
          mode: 'SERVICE',
          totalQuantity: 0,
          availableQuantity: 0,
        },
      });
    });

    afterAll(async () => {
      await prisma.allocation.deleteMany({
        where: { requestId: { in: createdRequestIds } },
      });
      await prisma.emergencyRequest.deleteMany({
        where: { id: { in: createdRequestIds } },
      });
      await prisma.responderResource.deleteMany({
        where: { responderId: { in: responderIds } },
      });
      await prisma.resource.deleteMany({
        where: { id: { in: [blood.id, fireTruck.id] } },
      });
      await prisma.user.deleteMany({
        where: { id: { in: [...responderIds, requester.id] } },
      });
      await prisma.$disconnect();
    });

    test('A. two different compatible responders accept the same request simultaneously', async () => {
      const emergency = await createEmergency([
        { resourceId: blood.id, quantity: 5 },
        { resourceId: fireTruck.id, quantity: 1 },
      ]);

      const bloodResponder = await createResponder('Conc Blood Responder');
      await enableCapability(bloodResponder.id, blood.id);
      const fireResponder = await createResponder('Conc Fire Responder');
      await enableCapability(fireResponder.id, fireTruck.id, {
        totalQuantity: 0,
        availableQuantity: 0,
        status: 'UNAVAILABLE',
      });

      const [bloodResult, fireResult] = await Promise.all([
        accept(emergency.id, tokens[bloodResponder.id]),
        accept(emergency.id, tokens[fireResponder.id]),
      ]);

      // Both compatible responders may join - partial capability matching.
      expect(bloodResult.statusCode).toBe(200);
      expect(fireResult.statusCode).toBe(200);

      const assignments = await prisma.responderAssignment.findMany({
        where: { requestId: emergency.id },
      });
      expect(assignments).toHaveLength(2);
      expect(new Set(assignments.map((row) => row.responderId)).size).toBe(2);
      expect(assignments.every((row) => row.status === 'ACTIVE')).toBe(true);

      // Exactly one lead: acceptedById matches the first committed responder.
      const stored = await prisma.emergencyRequest.findUnique({
        where: { id: emergency.id },
        select: { acceptedById: true, acceptedAt: true, status: true },
      });
      expect([bloodResponder.id, fireResponder.id]).toContain(
        stored.acceptedById
      );
      expect(stored.acceptedAt).not.toBeNull();
      expect(stored.status).toBe('ACCEPTED');

      // No duplicate pair, no impossible state: the unique constraint held.
      const pairCounts = await prisma.$queryRaw`
        SELECT "responderId"::text AS responder_id, count(*)::int AS n
        FROM "ResponderAssignment"
        WHERE "requestId" = ${emergency.id}
        GROUP BY "responderId"
      `;
      expect(pairCounts.every((row) => row.n === 1)).toBe(true);
    });

    test('B. the same responder accepts the same request simultaneously twice', async () => {
      const emergency = await createEmergency([
        { resourceId: blood.id, quantity: 3 },
      ]);

      const responder = await createResponder('Conc Duplicate Responder');
      await enableCapability(responder.id, blood.id);

      const [first, second] = await Promise.all([
        accept(emergency.id, tokens[responder.id]),
        accept(emergency.id, tokens[responder.id]),
      ]);

      const outcomes = [first.statusCode, second.statusCode].sort();
      expect(outcomes).toEqual([200, 400]);

      // Exactly one ACTIVE assignment for this pair, and exactly one row at
      // all - the database unique constraint is the safety net.
      const assignments = await prisma.responderAssignment.findMany({
        where: { requestId: emergency.id, responderId: responder.id },
      });
      expect(assignments).toHaveLength(1);
      expect(assignments[0].status).toBe('ACTIVE');

      const totalForRequest = await prisma.responderAssignment.count({
        where: { requestId: emergency.id },
      });
      expect(totalForRequest).toBe(1);

      const stored = await prisma.emergencyRequest.findUnique({
        where: { id: emergency.id },
        select: { acceptedById: true, status: true },
      });
      expect(stored.acceptedById).toBe(responder.id);
      expect(stored.status).toBe('ACCEPTED');
    });

    test('C. two responders compete when only one compatible outstanding unit remains', async () => {
      // Required: exactly ONE unit of blood. Acceptance does not reserve
      // inventory (the Allocation row is this system's reservation step), so
      // both responders may join - but only one of them can allocate the
      // final unit.
      const emergency = await createEmergency([
        { resourceId: blood.id, quantity: 1 },
      ]);

      const first = await createResponder('Conc Final Unit First');
      await enableCapability(first.id, blood.id);
      const second = await createResponder('Conc Final Unit Second');
      await enableCapability(second.id, blood.id);

      const firstInventory = await prisma.responderResource.findFirst({
        where: { responderId: first.id, resourceId: blood.id },
      });
      const secondInventory = await prisma.responderResource.findFirst({
        where: { responderId: second.id, resourceId: blood.id },
      });

      const [firstAccept, secondAccept] = await Promise.all([
        accept(emergency.id, tokens[first.id]),
        accept(emergency.id, tokens[second.id]),
      ]);
      expect(firstAccept.statusCode).toBe(200);
      expect(secondAccept.statusCode).toBe(200);

      // Both may hold ACTIVE assignments: acceptance reserves no inventory.
      const assignments = await prisma.responderAssignment.count({
        where: { requestId: emergency.id, status: 'ACTIVE' },
      });
      expect(assignments).toBe(2);

      // Now both try to reserve the single unit at the same time.
      const allocate = (token, inventoryId) =>
        request(app)
          .post('/api/allocations')
          .set('Authorization', `Bearer ${token}`)
          .send({
            requestId: emergency.id,
            responderResourceId: inventoryId,
            resourceId: blood.id,
            quantity: 1,
          });

      const [firstAllocation, secondAllocation] = await Promise.all([
        allocate(tokens[first.id], firstInventory.id),
        allocate(tokens[second.id], secondInventory.id),
      ]);

      // The losing allocation is rejected with the allocation endpoint's
      // existing business-error convention (500 + message), exactly like the
      // pre-existing "Not enough available quantity" rejections.
      const outcomes = [firstAllocation.statusCode, secondAllocation.statusCode].sort();
      expect(outcomes).toEqual([201, 500]);
      const loserBody = firstAllocation.statusCode === 500
        ? firstAllocation.body
        : secondAllocation.body;
      expect(loserBody.message).toBe('This resource is already fully allocated');

      // No invalid duplicate claim: exactly one active allocation, total
      // allocated quantity equals the required quantity.
      const activeAllocations = await prisma.allocation.findMany({
        where: { requestId: emergency.id, status: { not: 'CANCELLED' } },
      });
      expect(activeAllocations).toHaveLength(1);
      expect(
        activeAllocations.reduce((sum, row) => sum + row.quantity, 0)
      ).toBe(1);

      // Inventory never goes negative: the winner's stock was decremented
      // once, the loser's was never touched.
      const winnerId = activeAllocations[0].responderId;
      const inventories = await prisma.responderResource.findMany({
        where: {
          id: { in: [firstInventory.id, secondInventory.id] },
        },
      });
      for (const inventory of inventories) {
        expect(inventory.availableQuantity).toBeGreaterThanOrEqual(0);
        expect(inventory.availableQuantity).toBe(
          inventory.responderId === winnerId ? 9 : 10
        );
      }

      // The request status stays consistent (reserved, not delivered).
      const stored = await prisma.emergencyRequest.findUnique({
        where: { id: emergency.id },
        select: { status: true },
      });
      expect(stored.status).toBe('IN_PROGRESS');

      // Once the final unit is allocated, further acceptance of this
      // emergency is impossible - nothing is outstanding anymore.
      const third = await createResponder('Conc Final Unit Third');
      await enableCapability(third.id, blood.id);
      const lateAccept = await accept(emergency.id, tokens[third.id]);
      expect(lateAccept.statusCode).toBe(400);
      expect(lateAccept.body.message).toBe(
        'Responder has no compatible resource with outstanding quantity'
      );
    });
  }
);

// ============================================================================
// Phase D: allocation + cancellation concurrency.
//
// Every race below is a genuine parallel HTTP race against real PostgreSQL
// under the existing Serializable transactions with SELECT ... FOR UPDATE row
// locks and the serialization-failure retry wrapper. Where two orders are
// both legal, the assertions pin the INVARIANTS (never the interleaving):
// the consumable inventory formula, the SERVICE no-inventory rule, restore-
// exactly-once on cancellation, completion correctness and responder
// availability consistency.
//
// The full acceptance A-G matrix is formalized in Phase G; cases D-I here
// continue the lettering from the Phase C acceptance races A-C.
// ============================================================================
(hasDatabase ? describe : describe.skip)(
  'Allocation and cancellation concurrency (Phase D)',
  () => {
    const runId = `concd-${Date.now()}`;

    let requester;
    let requesterToken;
    let blood;
    let fireTruck;
    const createdRequestIds = [];
    const responderIds = [];
    const tokens = {};

    function tokenFor(user) {
      return jwt.sign(
        { userId: user.id, role: user.role },
        env.JWT_SECRET,
        { expiresIn: '1h' }
      );
    }

    async function createResponder(name) {
      const user = await prisma.user.create({
        data: {
          name,
          email: `${runId}-${name.toLowerCase().replace(/\s+/g, '-')}-${responderIds.length}@test.com`,
          password: 'test-password',
          role: 'RESPONDER',
          responderStatus: 'AVAILABLE',
          isActive: true,
        },
      });
      responderIds.push(user.id);
      tokens[user.id] = tokenFor(user);
      return user;
    }

    async function enableCapability(responderId, resourceId, options = {}) {
      return prisma.responderResource.create({
        data: {
          responderId,
          resourceId,
          totalQuantity: options.totalQuantity ?? 5,
          availableQuantity: options.availableQuantity ?? 5,
          isEnabled: true,
          status: options.status ?? 'AVAILABLE',
        },
      });
    }

    async function createEmergency(lines) {
      const emergency = await prisma.emergencyRequest.create({
        data: {
          requesterId: requester.id,
          emergencyType: 'Concurrent',
          location: 'Thrissur',
          priority: 'CRITICAL',
          status: 'PENDING',
          requiredResources: {
            create: lines.map((line) => ({
              resourceId: line.resourceId,
              quantity: line.quantity,
            })),
          },
        },
      });
      createdRequestIds.push(emergency.id);
      return emergency;
    }

    function auth(token) {
      return { Authorization: `Bearer ${token}` };
    }

    function allocate(token, body) {
      return request(app)
        .post('/api/allocations')
        .set(auth(token))
        .send(body);
    }

    function setAllocationStatus(token, id, status) {
      return request(app)
        .patch(`/api/allocations/${id}/status`)
        .set(auth(token))
        .send({ status });
    }

    function acceptRequest(token, id) {
      return request(app)
        .patch(`/api/requests/${id}/accept`)
        .set(auth(token));
    }

    function cancelRequest(id) {
      return request(app)
        .patch(`/api/requests/${id}/cancel`)
        .set(auth(requesterToken));
    }

    async function responderStatus(userId) {
      const row = await prisma.user.findUnique({
        where: { id: userId },
        select: { responderStatus: true },
      });
      return row.responderStatus;
    }

    async function expectConsumableInvariant(responderResourceId) {
      const row = await prisma.responderResource.findUnique({
        where: { id: responderResourceId },
      });
      const committed = await prisma.allocation.aggregate({
        _sum: { quantity: true },
        where: {
          responderResourceId,
          status: { not: 'CANCELLED' },
        },
      });
      const committedQuantity = committed._sum.quantity ?? 0;
      expect(row.availableQuantity).toBeGreaterThanOrEqual(0);
      expect(row.availableQuantity).toBe(
        row.totalQuantity - committedQuantity
      );
      return row;
    }

    beforeAll(async () => {
      requester = await prisma.user.create({
        data: {
          name: 'Phase D Concurrency Requester',
          email: `${runId}-requester@test.com`,
          password: 'test-password',
          role: 'REQUESTER',
          isActive: true,
        },
      });
      requesterToken = tokenFor(requester);

      blood = await prisma.resource.create({
        data: {
          name: `ConcD Blood ${runId}`,
          type: 'Medical',
          totalQuantity: 100,
          availableQuantity: 100,
          unit: 'unit',
        },
      });
      fireTruck = await prisma.resource.create({
        data: {
          name: `ConcD Fire Truck ${runId}`,
          type: 'Fire',
          mode: 'SERVICE',
          totalQuantity: 0,
          availableQuantity: 0,
        },
      });
    });

    afterAll(async () => {
      await prisma.allocation.deleteMany({
        where: { requestId: { in: createdRequestIds } },
      });
      await prisma.emergencyRequest.deleteMany({
        where: { id: { in: createdRequestIds } },
      });
      await prisma.responderResource.deleteMany({
        where: { responderId: { in: responderIds } },
      });
      await prisma.resource.deleteMany({
        where: { id: { in: [blood.id, fireTruck.id] } },
      });
      await prisma.user.deleteMany({
        where: { id: { in: [...responderIds, requester.id] } },
      });
      await prisma.$disconnect();
    });

    test('D. two responders race to allocate the same required CONSUMABLE line', async () => {
      // Required: 3 units of blood. Each responder tries to reserve 2, so
      // the combined demand (4) exceeds the requirement (3): the request row
      // lock serializes them and the second commit must see the exact
      // remaining outstanding quantity.
      const emergency = await createEmergency([
        { resourceId: blood.id, quantity: 3 },
      ]);

      const first = await createResponder('ConcD Line First');
      const firstInventory = await enableCapability(first.id, blood.id);
      const second = await createResponder('ConcD Line Second');
      const secondInventory = await enableCapability(second.id, blood.id);

      const [firstResult, secondResult] = await Promise.all([
        allocate(tokens[first.id], {
          requestId: emergency.id,
          responderResourceId: firstInventory.id,
          resourceId: blood.id,
          quantity: 2,
        }),
        allocate(tokens[second.id], {
          requestId: emergency.id,
          responderResourceId: secondInventory.id,
          resourceId: blood.id,
          quantity: 2,
        }),
      ]);

      const outcomes = [firstResult.statusCode, secondResult.statusCode].sort();
      expect(outcomes).toEqual([201, 500]);

      const loserBody =
        firstResult.statusCode === 500 ? firstResult.body : secondResult.body;
      expect(loserBody.message).toBe(
        'Allocation exceeds the remaining required quantity (1 left)'
      );

      // Exactly one active allocation; committed quantity within the
      // requirement; stock never overspent.
      const active = await prisma.allocation.findMany({
        where: { requestId: emergency.id, status: { not: 'CANCELLED' } },
      });
      expect(active).toHaveLength(1);
      expect(active[0].quantity).toBe(2);

      const winnerInventory =
        active[0].responderResourceId === firstInventory.id
          ? firstInventory
          : secondInventory;
      const loserInventory =
        winnerInventory.id === firstInventory.id
          ? secondInventory
          : firstInventory;

      expect(await expectConsumableInvariant(winnerInventory.id))
        .toMatchObject({ availableQuantity: 3 });
      expect(await expectConsumableInvariant(loserInventory.id))
        .toMatchObject({ availableQuantity: 5 });

      const stored = await prisma.emergencyRequest.findUnique({
        where: { id: emergency.id },
        select: { status: true },
      });
      expect(stored.status).toBe('IN_PROGRESS');
    });

    test('E. two responders race for the final SERVICE unit with no inventory to spend', async () => {
      // Required: exactly one fire truck. SERVICE capacity is not inventory:
      // both responders hold zero stock, and whichever allocation commits
      // first wins the outstanding quantity. NO inventory row may change.
      const emergency = await createEmergency([
        { resourceId: fireTruck.id, quantity: 1 },
      ]);

      const first = await createResponder('ConcD Service First');
      const firstInventory = await enableCapability(first.id, fireTruck.id, {
        totalQuantity: 0,
        availableQuantity: 0,
        status: 'UNAVAILABLE',
      });
      const second = await createResponder('ConcD Service Second');
      const secondInventory = await enableCapability(second.id, fireTruck.id, {
        totalQuantity: 0,
        availableQuantity: 0,
        status: 'UNAVAILABLE',
      });

      const [firstResult, secondResult] = await Promise.all([
        allocate(tokens[first.id], {
          requestId: emergency.id,
          responderResourceId: firstInventory.id,
          resourceId: fireTruck.id,
          quantity: 1,
        }),
        allocate(tokens[second.id], {
          requestId: emergency.id,
          responderResourceId: secondInventory.id,
          resourceId: fireTruck.id,
          quantity: 1,
        }),
      ]);

      const outcomes = [firstResult.statusCode, secondResult.statusCode].sort();
      expect(outcomes).toEqual([201, 500]);
      const loserBody =
        firstResult.statusCode === 500 ? firstResult.body : secondResult.body;
      expect(loserBody.message).toBe(
        'This resource is already fully allocated'
      );

      // SERVICE rows are untouched in BOTH outcomes: allocation never
      // decrements and rejection never fabricates stock.
      for (const inventory of [firstInventory, secondInventory]) {
        const row = await prisma.responderResource.findUnique({
          where: { id: inventory.id },
        });
        expect(row.totalQuantity).toBe(0);
        expect(row.availableQuantity).toBe(0);
        expect(row.status).toBe('UNAVAILABLE');
      }

      // The winner is BUSY through the unfinished allocation; the loser (no
      // assignment, no allocation) remains AVAILABLE despite zero stock -
      // SERVICE capacity is availability-driven, never stock-driven.
      const winnerId =
        firstResult.statusCode === 201 ? first.id : second.id;
      const loserId = winnerId === first.id ? second.id : first.id;
      expect(await responderStatus(winnerId)).toBe('BUSY');
      expect(await responderStatus(loserId)).toBe('AVAILABLE');

      const stored = await prisma.emergencyRequest.findUnique({
        where: { id: emergency.id },
        select: { status: true },
      });
      expect(stored.status).toBe('IN_PROGRESS');
    });

    test('F. the request is cancelled while a responder concurrently allocates', async () => {
      const emergency = await createEmergency([
        { resourceId: blood.id, quantity: 4 },
      ]);

      const responder = await createResponder('ConcD Cancel Allocate');
      const inventory = await enableCapability(responder.id, blood.id);

      const [cancelResult, allocateResult] = await Promise.all([
        cancelRequest(emergency.id),
        allocate(tokens[responder.id], {
          requestId: emergency.id,
          responderResourceId: inventory.id,
          resourceId: blood.id,
          quantity: 2,
        }),
      ]);

      // The cancellation always wins its own race (it only conflicts with
      // the allocation, which either committed before it - and is then
      // cleaned up - or was rejected after it).
      expect(cancelResult.statusCode).toBe(200);
      expect([201, 500]).toContain(allocateResult.statusCode);
      if (allocateResult.statusCode === 500) {
        expect(allocateResult.body.message).toBe(
          'Request is invalid or already closed'
        );
      }

      // Final state is identical in both interleavings.
      const stored = await prisma.emergencyRequest.findUnique({
        where: { id: emergency.id },
        select: { status: true },
      });
      expect(stored.status).toBe('CANCELLED');

      const live = await prisma.allocation.findMany({
        where: { requestId: emergency.id, status: { not: 'CANCELLED' } },
      });
      expect(live).toHaveLength(0);

      // Inventory fully restored exactly once (either the allocation was
      // never committed, or the cancellation restored it).
      const row = await expectConsumableInvariant(inventory.id);
      expect(row.availableQuantity).toBe(5);
      expect(row.status).toBe('AVAILABLE');
      expect(await responderStatus(responder.id)).toBe('AVAILABLE');
    });

    test('G. one allocation is cancelled while another responder allocates the same line', async () => {
      const emergency = await createEmergency([
        { resourceId: blood.id, quantity: 3 },
      ]);

      const holder = await createResponder('ConcD Restore Holder');
      const holderInventory = await enableCapability(holder.id, blood.id);
      const competitor = await createResponder('ConcD Restore Competitor');
      const competitorInventory = await enableCapability(competitor.id, blood.id);

      // The holder reserves the whole line first (sequential setup).
      const holderAllocation = await allocate(tokens[holder.id], {
        requestId: emergency.id,
        responderResourceId: holderInventory.id,
        resourceId: blood.id,
        quantity: 3,
      });
      expect(holderAllocation.statusCode).toBe(201);

      // Now the holder cancels while the competitor tries to take 2 units.
      const [cancelResult, allocateResult] = await Promise.all([
        setAllocationStatus(
          tokens[holder.id],
          holderAllocation.body.allocation.id,
          'CANCELLED'
        ),
        allocate(tokens[competitor.id], {
          requestId: emergency.id,
          responderResourceId: competitorInventory.id,
          resourceId: blood.id,
          quantity: 2,
        }),
      ]);

      expect(cancelResult.statusCode).toBe(200);
      expect([201, 500]).toContain(allocateResult.statusCode);

      // Invariants, whichever way the restore-vs-spend race resolved:
      // - the holder's allocation is cancelled and their stock restored once
      // - the total committed quantity never exceeds the requirement
      // - no inventory row goes negative or breaks the formula
      const holderRow = await expectConsumableInvariant(holderInventory.id);
      expect(holderRow.availableQuantity).toBe(5);

      const active = await prisma.allocation.findMany({
        where: { requestId: emergency.id, status: { not: 'CANCELLED' } },
      });
      const committed = active.reduce((sum, row) => sum + row.quantity, 0);
      expect(committed).toBeLessThanOrEqual(3);
      expect(committed).toBe(allocateResult.statusCode === 201 ? 2 : 0);

      await expectConsumableInvariant(competitorInventory.id);

      const stored = await prisma.emergencyRequest.findUnique({
        where: { id: emergency.id },
        select: { status: true },
      });
      expect(['PENDING', 'IN_PROGRESS']).toContain(stored.status);

      // The holder is freed by their own cancellation; the competitor is
      // BUSY only if their allocation committed.
      expect(await responderStatus(holder.id)).toBe('AVAILABLE');
      expect(await responderStatus(competitor.id)).toBe(
        allocateResult.statusCode === 201 ? 'BUSY' : 'AVAILABLE'
      );
    });

    test('H. the request is cancelled while a responder concurrently accepts it', async () => {
      const emergency = await createEmergency([
        { resourceId: blood.id, quantity: 3 },
      ]);

      const responder = await createResponder('ConcD Cancel Accept');
      const inventory = await enableCapability(responder.id, blood.id);

      const [cancelResult, acceptResult] = await Promise.all([
        cancelRequest(emergency.id),
        acceptRequest(tokens[responder.id], emergency.id),
      ]);

      expect(cancelResult.statusCode).toBe(200);
      expect([200, 400]).toContain(acceptResult.statusCode);
      if (acceptResult.statusCode === 400) {
        expect(acceptResult.body.message).toBe(
          'Request has already been cancelled'
        );
      }

      const stored = await prisma.emergencyRequest.findUnique({
        where: { id: emergency.id },
        select: { status: true },
      });
      expect(stored.status).toBe('CANCELLED');

      // Either the acceptance lost the race (no assignment at all) or it
      // committed first and the assignment row remains ACTIVE - ending
      // assignment rows on terminal requests is deliberately deferred to a
      // later phase - but in BOTH cases the responder must be freed: the
      // cancellation re-derives availability for every attached responder,
      // including assignment-only ones.
      const assignments = await prisma.responderAssignment.findMany({
        where: { requestId: emergency.id, responderId: responder.id },
      });
      expect(assignments.length).toBe(
        acceptResult.statusCode === 200 ? 1 : 0
      );
      if (assignments.length === 1) {
        expect(assignments[0].status).toBe('ACTIVE');
      }

      expect(await responderStatus(responder.id)).toBe('AVAILABLE');

      // Acceptance never touched inventory.
      const row = await expectConsumableInvariant(inventory.id);
      expect(row.availableQuantity).toBe(5);
    });

    test('I. concurrent deliveries by two responders complete the request exactly once', async () => {
      const emergency = await createEmergency([
        { resourceId: blood.id, quantity: 3 },
        { resourceId: fireTruck.id, quantity: 1 },
      ]);

      const medic = await createResponder('ConcD Done Medic');
      const medicInventory = await enableCapability(medic.id, blood.id);
      const pilot = await createResponder('ConcD Done Pilot');
      const pilotInventory = await enableCapability(pilot.id, fireTruck.id, {
        totalQuantity: 0,
        availableQuantity: 0,
        status: 'UNAVAILABLE',
      });

      const medicAllocation = await allocate(tokens[medic.id], {
        requestId: emergency.id,
        responderResourceId: medicInventory.id,
        resourceId: blood.id,
        quantity: 3,
      });
      const pilotAllocation = await allocate(tokens[pilot.id], {
        requestId: emergency.id,
        responderResourceId: pilotInventory.id,
        resourceId: fireTruck.id,
        quantity: 1,
      });
      expect(medicAllocation.statusCode).toBe(201);
      expect(pilotAllocation.statusCode).toBe(201);

      for (const allocation of [
        medicAllocation.body.allocation,
        pilotAllocation.body.allocation,
      ]) {
        const dispatch = await setAllocationStatus(
          allocation.responderId === medic.id
            ? tokens[medic.id]
            : tokens[pilot.id],
          allocation.id,
          'DISPATCHED'
        );
        expect(dispatch.statusCode).toBe(200);
      }

      // Both responders deliver concurrently. Each delivery recomputes the
      // request status under the Serializable transaction; the loser of the
      // status race retries and observes the sibling delivery, so the
      // terminal COMPLETED state is reached exactly once and consistently.
      const [medicDelivery, pilotDelivery] = await Promise.all([
        setAllocationStatus(
          tokens[medic.id],
          medicAllocation.body.allocation.id,
          'DELIVERED'
        ),
        setAllocationStatus(
          tokens[pilot.id],
          pilotAllocation.body.allocation.id,
          'DELIVERED'
        ),
      ]);
      expect(medicDelivery.statusCode).toBe(200);
      expect(pilotDelivery.statusCode).toBe(200);

      const stored = await prisma.emergencyRequest.findUnique({
        where: { id: emergency.id },
        select: { status: true },
      });
      expect(stored.status).toBe('COMPLETED');

      const allocations = await prisma.allocation.findMany({
        where: { requestId: emergency.id },
      });
      expect(allocations.every((row) => row.status === 'DELIVERED')).toBe(
        true
      );

      // Completion releases both responders and never restores delivered
      // consumables; the SERVICE row stays untouched.
      expect(await responderStatus(medic.id)).toBe('AVAILABLE');
      expect(await responderStatus(pilot.id)).toBe('AVAILABLE');
      expect(await expectConsumableInvariant(medicInventory.id))
        .toMatchObject({ availableQuantity: 2 });
      // SERVICE row: the consumable formula does not apply - assert the
      // quantities are simply untouched.
      const pilotRow = await prisma.responderResource.findUnique({
        where: { id: pilotInventory.id },
      });
      expect(pilotRow.availableQuantity).toBe(0);
      expect(pilotRow.totalQuantity).toBe(0);
    });
  }
);
