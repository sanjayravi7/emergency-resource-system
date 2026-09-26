// Load backend/.env first so a locally configured PostgreSQL test database is
// detected (same pattern as the concurrency and socket integration suites).
require('dotenv').config();

const request = require('supertest');
const jwt = require('jsonwebtoken');

const app = require('../../src/app');
const prisma = require('../../src/config/prisma');
const env = require('../../src/config/env');

const hasDatabase = Boolean(process.env.DATABASE_URL && process.env.JWT_SECRET);

// Phase D sequential suite: multi-responder, multi-allocation lifecycle.
//
// These tests pin the allocation subsystem's invariants when SEVERAL
// responders and SEVERAL allocations share one emergency:
//
// CONSUMABLE invariant (per ResponderResource row):
//   availableQuantity === totalQuantity - sum(non-CANCELLED allocation
//   quantities of that row) at every lifecycle step, and never negative.
//   DELIVERED stays committed (units were consumed); only cancellation of a
//   non-delivered allocation restores stock.
//
// SERVICE invariant:
//   allocation, delivery and cancellation NEVER touch a SERVICE resource's
//   quantities - capacity is governed by responder availability (BUSY), not
//   by stock. SERVICE resources must never decay into consumables.
//
// Completion correctness:
//   a request is COMPLETED only when EVERY required line is fully DELIVERED;
//   any partial delivery keeps it PARTIALLY_ALLOCATED and responders with
//   unfinished work stay BUSY.
//
// Responder availability consistency:
//   every responder attached to a request (assignment holder, allocation
//   owner, lead) is re-synced when the request is cancelled or completed -
//   including responders who never acted in the final transaction.
(hasDatabase ? describe : describe.skip)(
  'Multi-responder allocation lifecycle (Phase D)',
  () => {
    const runId = `multialloc-${Date.now()}`;

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
          emergencyType: 'Multi',
          location: 'Thrissur',
          priority: 'HIGH',
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
      return request(app).post('/api/allocations').set(auth(token)).send(body);
    }

    function setAllocationStatus(token, id, status) {
      return request(app)
        .patch(`/api/allocations/${id}/status`)
        .set(auth(token))
        .send({ status });
    }

    function confirmReceived(token, id) {
      return request(app)
        .patch(`/api/allocations/${id}/received`)
        .set(auth(token));
    }

    function acceptRequest(token, id) {
      return request(app)
        .patch(`/api/requests/${id}/accept`)
        .set(auth(token));
    }

    function cancelRequest(token, id) {
      return request(app)
        .patch(`/api/requests/${id}/cancel`)
        .set(auth(token));
    }

    async function responderStatus(userId) {
      const row = await prisma.user.findUnique({
        where: { id: userId },
        select: { responderStatus: true },
      });
      return row.responderStatus;
    }

    /**
     * The explicit Phase D CONSUMABLE invariant: availableQuantity is always
     * totalQuantity minus the currently committed (non-CANCELLED) allocation
     * quantity of THIS inventory row, and never negative.
     */
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
      expect(row.availableQuantity).toBe(row.totalQuantity - committedQuantity);
      return row;
    }

    beforeAll(async () => {
      requester = await prisma.user.create({
        data: {
          name: 'Multi Allocation Requester',
          email: `${runId}-requester@test.com`,
          password: 'test-password',
          role: 'REQUESTER',
          isActive: true,
        },
      });
      requesterToken = tokenFor(requester);

      blood = await prisma.resource.create({
        data: {
          name: `MultiAlloc Blood ${runId}`,
          type: 'Medical',
          totalQuantity: 100,
          availableQuantity: 100,
          unit: 'unit',
        },
      });

      fireTruck = await prisma.resource.create({
        data: {
          name: `MultiAlloc Fire Truck ${runId}`,
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
        where: {
          id: { in: [...responderIds, requester.id] },
        },
      });
      await prisma.$disconnect();
    });

    test('two responders allocate different required lines of one request', async () => {
      const emergency = await createEmergency([
        { resourceId: blood.id, quantity: 3 },
        { resourceId: fireTruck.id, quantity: 1 },
      ]);

      const medic = await createResponder('Line Medic');
      const medicInventory = await enableCapability(medic.id, blood.id);
      const pilot = await createResponder('Line Pilot');
      const pilotInventory = await enableCapability(pilot.id, fireTruck.id, {
        totalQuantity: 0,
        availableQuantity: 0,
        status: 'UNAVAILABLE',
      });

      const medicResult = await allocate(tokens[medic.id], {
        requestId: emergency.id,
        responderResourceId: medicInventory.id,
        resourceId: blood.id,
        quantity: 3,
      });
      const pilotResult = await allocate(tokens[pilot.id], {
        requestId: emergency.id,
        responderResourceId: pilotInventory.id,
        resourceId: fireTruck.id,
        quantity: 1,
      });

      expect(medicResult.statusCode).toBe(201);
      expect(pilotResult.statusCode).toBe(201);

      const allocations = await prisma.allocation.findMany({
        where: { requestId: emergency.id },
      });
      expect(allocations).toHaveLength(2);
      expect(
        new Set(allocations.map((row) => row.responderId)).size
      ).toBe(2);
      expect(allocations.every((row) => row.status === 'RESERVED')).toBe(true);

      const stored = await prisma.emergencyRequest.findUnique({
        where: { id: emergency.id },
        select: { status: true },
      });
      expect(stored.status).toBe('IN_PROGRESS');

      // Both responders hold unfinished work: BUSY.
      expect(await responderStatus(medic.id)).toBe('BUSY');
      expect(await responderStatus(pilot.id)).toBe('BUSY');

      // CONSUMABLE decremented, SERVICE untouched.
      const medicRow = await expectConsumableInvariant(medicInventory.id);
      expect(medicRow.availableQuantity).toBe(2);
      const pilotRow = await prisma.responderResource.findUnique({
        where: { id: pilotInventory.id },
      });
      expect(pilotRow.availableQuantity).toBe(0);
      expect(pilotRow.totalQuantity).toBe(0);
      expect(pilotRow.status).toBe('UNAVAILABLE');
    });

    test('one required line is split across two responders and cannot be over-allocated', async () => {
      const emergency = await createEmergency([
        { resourceId: blood.id, quantity: 5 },
      ]);

      const first = await createResponder('Split First');
      const firstInventory = await enableCapability(first.id, blood.id);
      const second = await createResponder('Split Second');
      const secondInventory = await enableCapability(second.id, blood.id);
      const third = await createResponder('Split Third');
      const thirdInventory = await enableCapability(third.id, blood.id);

      const firstResult = await allocate(tokens[first.id], {
        requestId: emergency.id,
        responderResourceId: firstInventory.id,
        resourceId: blood.id,
        quantity: 3,
      });
      const secondResult = await allocate(tokens[second.id], {
        requestId: emergency.id,
        responderResourceId: secondInventory.id,
        resourceId: blood.id,
        quantity: 2,
      });
      // The line is now fully allocated (3 + 2 = 5): no more reservations.
      const overflowResult = await allocate(tokens[third.id], {
        requestId: emergency.id,
        responderResourceId: thirdInventory.id,
        resourceId: blood.id,
        quantity: 1,
      });
      // And a quantity larger than the outstanding remainder is rejected
      // with the exact remaining amount before anything is committed.
      const excessResult = await allocate(tokens[third.id], {
        requestId: emergency.id,
        responderResourceId: thirdInventory.id,
        resourceId: blood.id,
        quantity: 1,
      });

      expect(firstResult.statusCode).toBe(201);
      expect(secondResult.statusCode).toBe(201);
      expect(overflowResult.statusCode).toBe(500);
      expect(overflowResult.body.message).toBe(
        'This resource is already fully allocated'
      );
      expect(excessResult.statusCode).toBe(500);
      expect(excessResult.body.message).toBe(
        'This resource is already fully allocated'
      );

      expect(await expectConsumableInvariant(firstInventory.id)).toMatchObject({
        availableQuantity: 2,
      });
      expect(
        await expectConsumableInvariant(secondInventory.id)
      ).toMatchObject({ availableQuantity: 3 });
      expect(await expectConsumableInvariant(thirdInventory.id))
        .toMatchObject({ availableQuantity: 5 });

      const stored = await prisma.emergencyRequest.findUnique({
        where: { id: emergency.id },
        select: { status: true },
      });
      expect(stored.status).toBe('IN_PROGRESS');
    });

    test('deliveries by two responders complete the request and free both responders', async () => {
      const emergency = await createEmergency([
        { resourceId: blood.id, quantity: 3 },
        { resourceId: fireTruck.id, quantity: 1 },
      ]);

      const medic = await createResponder('Complete Medic');
      const medicInventory = await enableCapability(medic.id, blood.id);
      const pilot = await createResponder('Complete Pilot');
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

      // Medic path: dispatch, then the responder-side delivery fallback.
      expect(
        (
          await setAllocationStatus(
            tokens[medic.id],
            medicAllocation.body.allocation.id,
            'DISPATCHED'
          )
        ).statusCode
      ).toBe(200);
      expect(
        (
          await setAllocationStatus(
            tokens[medic.id],
            medicAllocation.body.allocation.id,
            'DELIVERED'
          )
        ).statusCode
      ).toBe(200);

      // Pilot path: dispatch, then the requester confirms receipt.
      expect(
        (
          await setAllocationStatus(
            tokens[pilot.id],
            pilotAllocation.body.allocation.id,
            'DISPATCHED'
          )
        ).statusCode
      ).toBe(200);
      expect(
        (
          await confirmReceived(
            requesterToken,
            pilotAllocation.body.allocation.id
          )
        ).statusCode
      ).toBe(200);

      const stored = await prisma.emergencyRequest.findUnique({
        where: { id: emergency.id },
        select: { status: true },
      });
      expect(stored.status).toBe('COMPLETED');

      const allocations = await prisma.allocation.findMany({
        where: { requestId: emergency.id },
      });
      expect(allocations.every((row) => row.status === 'DELIVERED')).toBe(true);

      // Completion releases every attached responder: no unfinished
      // allocation remains and both were re-synced in the final transaction.
      expect(await responderStatus(medic.id)).toBe('AVAILABLE');
      expect(await responderStatus(pilot.id)).toBe('AVAILABLE');

      // Delivered consumables stay committed; SERVICE inventory untouched
      // (the consumable formula does not apply to SERVICE rows - their
      // allocations commit no inventory at all).
      expect(
        await expectConsumableInvariant(medicInventory.id)
      ).toMatchObject({ availableQuantity: 2 });
      const pilotRow = await prisma.responderResource.findUnique({
        where: { id: pilotInventory.id },
      });
      expect(pilotRow.availableQuantity).toBe(0);
      expect(pilotRow.totalQuantity).toBe(0);
    });

    test('partial delivery keeps the request PARTIALLY_ALLOCATED until the second line completes', async () => {
      const emergency = await createEmergency([
        { resourceId: blood.id, quantity: 3 },
        { resourceId: fireTruck.id, quantity: 1 },
      ]);

      const medic = await createResponder('Partial Medic');
      const medicInventory = await enableCapability(medic.id, blood.id);
      const pilot = await createResponder('Partial Pilot');
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

      await setAllocationStatus(
        tokens[medic.id],
        medicAllocation.body.allocation.id,
        'DISPATCHED'
      );
      await setAllocationStatus(
        tokens[medic.id],
        medicAllocation.body.allocation.id,
        'DELIVERED'
      );

      // One of two required lines delivered: partially allocated, not
      // completed. The pilot still holds an unfinished allocation: BUSY.
      let stored = await prisma.emergencyRequest.findUnique({
        where: { id: emergency.id },
        select: { status: true },
      });
      expect(stored.status).toBe('PARTIALLY_ALLOCATED');
      expect(await responderStatus(pilot.id)).toBe('BUSY');

      await setAllocationStatus(
        tokens[pilot.id],
        pilotAllocation.body.allocation.id,
        'DISPATCHED'
      );
      await setAllocationStatus(
        tokens[pilot.id],
        pilotAllocation.body.allocation.id,
        'DELIVERED'
      );

      stored = await prisma.emergencyRequest.findUnique({
        where: { id: emergency.id },
        select: { status: true },
      });
      expect(stored.status).toBe('COMPLETED');
      expect(await responderStatus(medic.id)).toBe('AVAILABLE');
      expect(await responderStatus(pilot.id)).toBe('AVAILABLE');
    });

    test('cancelling one allocation frees the outstanding quantity for another responder', async () => {
      const emergency = await createEmergency([
        { resourceId: blood.id, quantity: 5 },
      ]);

      const first = await createResponder('Free First');
      const firstInventory = await enableCapability(first.id, blood.id);
      const second = await createResponder('Free Second');
      const secondInventory = await enableCapability(second.id, blood.id);
      const third = await createResponder('Free Third');
      const thirdInventory = await enableCapability(third.id, blood.id);

      const firstAllocation = await allocate(tokens[first.id], {
        requestId: emergency.id,
        responderResourceId: firstInventory.id,
        resourceId: blood.id,
        quantity: 3,
      });
      const secondAllocation = await allocate(tokens[second.id], {
        requestId: emergency.id,
        responderResourceId: secondInventory.id,
        resourceId: blood.id,
        quantity: 2,
      });
      expect(firstAllocation.statusCode).toBe(201);
      expect(secondAllocation.statusCode).toBe(201);

      // Line fully allocated: the third responder cannot reserve anything.
      const blocked = await allocate(tokens[third.id], {
        requestId: emergency.id,
        responderResourceId: thirdInventory.id,
        resourceId: blood.id,
        quantity: 1,
      });
      expect(blocked.statusCode).toBe(500);
      expect(blocked.body.message).toBe(
        'This resource is already fully allocated'
      );

      // The first responder cancels: the inventory is restored exactly once
      // and the outstanding quantity becomes available again.
      const cancelResult = await setAllocationStatus(
        tokens[first.id],
        firstAllocation.body.allocation.id,
        'CANCELLED'
      );
      expect(cancelResult.statusCode).toBe(200);
      expect(
        await expectConsumableInvariant(firstInventory.id)
      ).toMatchObject({ availableQuantity: 5 });

      // The third responder can now cover the freed quantity.
      const takeover = await allocate(tokens[third.id], {
        requestId: emergency.id,
        responderResourceId: thirdInventory.id,
        resourceId: blood.id,
        quantity: 3,
      });
      expect(takeover.statusCode).toBe(201);

      const active = await prisma.allocation.findMany({
        where: { requestId: emergency.id, status: { not: 'CANCELLED' } },
      });
      expect(
        active.reduce((sum, row) => sum + row.quantity, 0)
      ).toBe(5);

      expect(
        await expectConsumableInvariant(secondInventory.id)
      ).toMatchObject({ availableQuantity: 3 });
      expect(
        await expectConsumableInvariant(thirdInventory.id)
      ).toMatchObject({ availableQuantity: 2 });

      const stored = await prisma.emergencyRequest.findUnique({
        where: { id: emergency.id },
        select: { status: true },
      });
      expect(stored.status).toBe('IN_PROGRESS');
      expect(await responderStatus(first.id)).toBe('AVAILABLE');
    });

    test('request cancellation restores only the RESERVED sibling, never the DELIVERED allocation', async () => {
      const emergency = await createEmergency([
        { resourceId: blood.id, quantity: 3 },
      ]);

      const first = await createResponder('Mixed First');
      const firstInventory = await enableCapability(first.id, blood.id);
      const second = await createResponder('Mixed Second');
      const secondInventory = await enableCapability(second.id, blood.id);

      const firstAllocation = await allocate(tokens[first.id], {
        requestId: emergency.id,
        responderResourceId: firstInventory.id,
        resourceId: blood.id,
        quantity: 2,
      });
      const secondAllocation = await allocate(tokens[second.id], {
        requestId: emergency.id,
        responderResourceId: secondInventory.id,
        resourceId: blood.id,
        quantity: 1,
      });
      expect(firstAllocation.statusCode).toBe(201);
      expect(secondAllocation.statusCode).toBe(201);

      // First responder delivers (units genuinely consumed).
      await setAllocationStatus(
        tokens[first.id],
        firstAllocation.body.allocation.id,
        'DISPATCHED'
      );
      await setAllocationStatus(
        tokens[first.id],
        firstAllocation.body.allocation.id,
        'DELIVERED'
      );

      const cancelResult = await cancelRequest(requesterToken, emergency.id);
      expect(cancelResult.statusCode).toBe(200);
      expect(cancelResult.body.request.status).toBe('CANCELLED');

      const allocations = await prisma.allocation.findMany({
        where: { requestId: emergency.id },
      });
      const delivered = allocations.find(
        (row) => row.id === firstAllocation.body.allocation.id
      );
      const cancelled = allocations.find(
        (row) => row.id === secondAllocation.body.allocation.id
      );
      expect(delivered.status).toBe('DELIVERED');
      expect(cancelled.status).toBe('CANCELLED');

      // Delivered stays committed (no fabricated stock); reserved restored.
      expect(
        await expectConsumableInvariant(firstInventory.id)
      ).toMatchObject({ availableQuantity: 3 });
      expect(
        await expectConsumableInvariant(secondInventory.id)
      ).toMatchObject({ availableQuantity: 5 });

      expect(await responderStatus(first.id)).toBe('AVAILABLE');
      expect(await responderStatus(second.id)).toBe('AVAILABLE');
    });

    test('request cancellation restores every responder inventory exactly once and frees everyone', async () => {
      const emergency = await createEmergency([
        { resourceId: blood.id, quantity: 3 },
      ]);

      const first = await createResponder('Restore First');
      const firstInventory = await enableCapability(first.id, blood.id);
      const second = await createResponder('Restore Second');
      const secondInventory = await enableCapability(second.id, blood.id);

      const firstAllocation = await allocate(tokens[first.id], {
        requestId: emergency.id,
        responderResourceId: firstInventory.id,
        resourceId: blood.id,
        quantity: 2,
      });
      const secondAllocation = await allocate(tokens[second.id], {
        requestId: emergency.id,
        responderResourceId: secondInventory.id,
        resourceId: blood.id,
        quantity: 1,
      });
      expect(firstAllocation.statusCode).toBe(201);
      expect(secondAllocation.statusCode).toBe(201);
      expect(await responderStatus(first.id)).toBe('BUSY');
      expect(await responderStatus(second.id)).toBe('BUSY');

      const cancelResult = await cancelRequest(requesterToken, emergency.id);
      expect(cancelResult.statusCode).toBe(200);

      const stored = await prisma.emergencyRequest.findUnique({
        where: { id: emergency.id },
        select: { status: true },
      });
      expect(stored.status).toBe('CANCELLED');

      const allocations = await prisma.allocation.findMany({
        where: { requestId: emergency.id },
      });
      expect(allocations).toHaveLength(2);
      expect(allocations.every((row) => row.status === 'CANCELLED')).toBe(
        true
      );

      const firstRow = await expectConsumableInvariant(firstInventory.id);
      expect(firstRow.availableQuantity).toBe(5);
      expect(firstRow.status).toBe('AVAILABLE');
      const secondRow = await expectConsumableInvariant(secondInventory.id);
      expect(secondRow.availableQuantity).toBe(5);
      expect(secondRow.status).toBe('AVAILABLE');

      expect(await responderStatus(first.id)).toBe('AVAILABLE');
      expect(await responderStatus(second.id)).toBe('AVAILABLE');
    });

    test('an assignment-only responder is freed when the request is cancelled', async () => {
      const emergency = await createEmergency([
        { resourceId: blood.id, quantity: 3 },
      ]);

      const lead = await createResponder('Cancel Lead');
      await enableCapability(lead.id, blood.id);
      const joiner = await createResponder('Cancel Joiner');
      await enableCapability(joiner.id, blood.id);

      const leadAccept = await acceptRequest(tokens[lead.id], emergency.id);
      const joinerAccept = await acceptRequest(tokens[joiner.id], emergency.id);
      expect(leadAccept.statusCode).toBe(200);
      expect(joinerAccept.statusCode).toBe(200);

      const leadInventory = await prisma.responderResource.findFirst({
        where: { responderId: lead.id, resourceId: blood.id },
      });
      const leadAllocation = await allocate(tokens[lead.id], {
        requestId: emergency.id,
        responderResourceId: leadInventory.id,
        resourceId: blood.id,
        quantity: 3,
      });
      expect(leadAllocation.statusCode).toBe(201);

      // Both responders are working the emergency: one through an
      // allocation, the other through an ACTIVE assignment only.
      expect(await responderStatus(lead.id)).toBe('BUSY');
      expect(await responderStatus(joiner.id)).toBe('BUSY');

      const cancelResult = await cancelRequest(requesterToken, emergency.id);
      expect(cancelResult.statusCode).toBe(200);

      // The joiner never created an allocation: cancelling the request must
      // still re-derive their availability, otherwise they would stay BUSY
      // forever (they are not part of the allocation-cleanup candidate set).
      expect(await responderStatus(joiner.id)).toBe('AVAILABLE');
      expect(await responderStatus(lead.id)).toBe('AVAILABLE');

      // Ending assignment rows when a request reaches a terminal state is
      // deliberately deferred to a later phase: the rows stay ACTIVE and
      // simply stop counting for availability once the request is terminal.
      const assignments = await prisma.responderAssignment.findMany({
        where: { requestId: emergency.id },
        orderBy: { responderId: 'asc' },
      });
      expect(assignments).toHaveLength(2);
      expect(assignments.every((row) => row.status === 'ACTIVE')).toBe(true);

      const stored = await prisma.emergencyRequest.findUnique({
        where: { id: emergency.id },
        select: { status: true, acceptedById: true },
      });
      expect(stored.status).toBe('CANCELLED');
      // acceptedById is never cleared when work ends.
      expect(stored.acceptedById).toBe(lead.id);
    });

    test('an assignment-only responder is freed when another responder completes the request', async () => {
      const emergency = await createEmergency([
        { resourceId: blood.id, quantity: 3 },
        { resourceId: fireTruck.id, quantity: 1 },
      ]);

      // Joins first (qualifies via the blood line), but never allocates.
      const spectator = await createResponder('Done Spectator');
      await enableCapability(spectator.id, blood.id);

      // Covers both required lines and delivers everything.
      const worker = await createResponder('Done Worker');
      const workerBlood = await enableCapability(worker.id, blood.id);
      const workerFire = await enableCapability(worker.id, fireTruck.id, {
        totalQuantity: 0,
        availableQuantity: 0,
        status: 'UNAVAILABLE',
      });

      const spectatorAccept = await acceptRequest(
        tokens[spectator.id],
        emergency.id
      );
      const workerAccept = await acceptRequest(tokens[worker.id], emergency.id);
      expect(spectatorAccept.statusCode).toBe(200);
      expect(workerAccept.statusCode).toBe(200);
      expect(await responderStatus(spectator.id)).toBe('BUSY');

      const bloodAllocation = await allocate(tokens[worker.id], {
        requestId: emergency.id,
        responderResourceId: workerBlood.id,
        resourceId: blood.id,
        quantity: 3,
      });
      const fireAllocation = await allocate(tokens[worker.id], {
        requestId: emergency.id,
        responderResourceId: workerFire.id,
        resourceId: fireTruck.id,
        quantity: 1,
      });
      expect(bloodAllocation.statusCode).toBe(201);
      expect(fireAllocation.statusCode).toBe(201);

      for (const allocation of [
        bloodAllocation.body.allocation,
        fireAllocation.body.allocation,
      ]) {
        await setAllocationStatus(
          tokens[worker.id],
          allocation.id,
          'DISPATCHED'
        );
        await setAllocationStatus(
          tokens[worker.id],
          allocation.id,
          'DELIVERED'
        );
      }

      const stored = await prisma.emergencyRequest.findUnique({
        where: { id: emergency.id },
        select: { status: true },
      });
      expect(stored.status).toBe('COMPLETED');

      // The completion happened inside the WORKER's transaction, but it must
      // re-sync every responder attached to the request - including the
      // spectator, whose only BUSY basis was the now-terminal assignment.
      expect(await responderStatus(spectator.id)).toBe('AVAILABLE');
      expect(await responderStatus(worker.id)).toBe('AVAILABLE');

      expect(
        await expectConsumableInvariant(workerBlood.id)
      ).toMatchObject({ availableQuantity: 2 });
      const workerFireRow = await prisma.responderResource.findUnique({
        where: { id: workerFire.id },
      });
      expect(workerFireRow.availableQuantity).toBe(0);
      expect(workerFireRow.totalQuantity).toBe(0);
      expect(workerFireRow.status).toBe('UNAVAILABLE');
    });

    test('CONSUMABLE invariant holds at every step of the full lifecycle', async () => {
      const emergency = await createEmergency([
        { resourceId: blood.id, quantity: 4 },
      ]);

      const solo = await createResponder('Invariant Solo');
      const inventory = await enableCapability(solo.id, blood.id, {
        totalQuantity: 6,
        availableQuantity: 6,
      });

      const first = await allocate(tokens[solo.id], {
        requestId: emergency.id,
        responderResourceId: inventory.id,
        resourceId: blood.id,
        quantity: 2,
      });
      expect(first.statusCode).toBe(201);
      expect(
        await expectConsumableInvariant(inventory.id)
      ).toMatchObject({ availableQuantity: 4 });

      const second = await allocate(tokens[solo.id], {
        requestId: emergency.id,
        responderResourceId: inventory.id,
        resourceId: blood.id,
        quantity: 2,
      });
      expect(second.statusCode).toBe(201);
      expect(
        await expectConsumableInvariant(inventory.id)
      ).toMatchObject({ availableQuantity: 2 });

      await setAllocationStatus(
        tokens[solo.id],
        second.body.allocation.id,
        'DISPATCHED'
      );
      expect(
        await expectConsumableInvariant(inventory.id)
      ).toMatchObject({ availableQuantity: 2 });

      // Cancelling the RESERVED allocation returns its stock; the DISPATCHED
      // sibling stays committed.
      await setAllocationStatus(
        tokens[solo.id],
        first.body.allocation.id,
        'CANCELLED'
      );
      expect(
        await expectConsumableInvariant(inventory.id)
      ).toMatchObject({ availableQuantity: 4 });

      await setAllocationStatus(
        tokens[solo.id],
        second.body.allocation.id,
        'DELIVERED'
      );
      expect(
        await expectConsumableInvariant(inventory.id)
      ).toMatchObject({ availableQuantity: 4 });

      // Request-wide cancellation must not "restore" delivered units.
      const cancelResult = await cancelRequest(requesterToken, emergency.id);
      expect(cancelResult.statusCode).toBe(200);
      expect(
        await expectConsumableInvariant(inventory.id)
      ).toMatchObject({ availableQuantity: 4 });

      const stored = await prisma.emergencyRequest.findUnique({
        where: { id: emergency.id },
        select: { status: true },
      });
      expect(stored.status).toBe('CANCELLED');
      expect(await responderStatus(solo.id)).toBe('AVAILABLE');
    });

    test('SERVICE invariant: allocation, delivery and cancellation never touch SERVICE quantities', async () => {
      const emergency = await createEmergency([
        { resourceId: fireTruck.id, quantity: 2 },
      ]);

      const first = await createResponder('Service First');
      const firstInventory = await enableCapability(first.id, fireTruck.id, {
        totalQuantity: 0,
        availableQuantity: 0,
        status: 'UNAVAILABLE',
      });
      const second = await createResponder('Service Second');
      const secondInventory = await enableCapability(
        second.id,
        fireTruck.id,
        {
          totalQuantity: 0,
          availableQuantity: 0,
          status: 'UNAVAILABLE',
        }
      );

      const firstAllocation = await allocate(tokens[first.id], {
        requestId: emergency.id,
        responderResourceId: firstInventory.id,
        resourceId: fireTruck.id,
        quantity: 1,
      });
      expect(firstAllocation.statusCode).toBe(201);

      // SERVICE allocation: no stock check, no decrement, no status change.
      let row = await prisma.responderResource.findUnique({
        where: { id: firstInventory.id },
      });
      expect(row.totalQuantity).toBe(0);
      expect(row.availableQuantity).toBe(0);
      expect(row.status).toBe('UNAVAILABLE');

      // The responder is BUSY through the unfinished allocation, not stock.
      expect(await responderStatus(first.id)).toBe('BUSY');

      await setAllocationStatus(
        tokens[first.id],
        firstAllocation.body.allocation.id,
        'DISPATCHED'
      );
      await setAllocationStatus(
        tokens[first.id],
        firstAllocation.body.allocation.id,
        'DELIVERED'
      );

      row = await prisma.responderResource.findUnique({
        where: { id: firstInventory.id },
      });
      expect(row.totalQuantity).toBe(0);
      expect(row.availableQuantity).toBe(0);
      expect(row.status).toBe('UNAVAILABLE');

      // Delivery released the responder even though their SERVICE stock is
      // zero: SERVICE capacity is availability-driven, never stock-driven.
      expect(await responderStatus(first.id)).toBe('AVAILABLE');

      // Cancelling a SERVICE allocation must never fabricate stock.
      const secondAllocation = await allocate(tokens[second.id], {
        requestId: emergency.id,
        responderResourceId: secondInventory.id,
        resourceId: fireTruck.id,
        quantity: 1,
      });
      expect(secondAllocation.statusCode).toBe(201);
      const cancelResult = await setAllocationStatus(
        tokens[second.id],
        secondAllocation.body.allocation.id,
        'CANCELLED'
      );
      expect(cancelResult.statusCode).toBe(200);

      const secondRow = await prisma.responderResource.findUnique({
        where: { id: secondInventory.id },
      });
      expect(secondRow.totalQuantity).toBe(0);
      expect(secondRow.availableQuantity).toBe(0);
      expect(secondRow.status).toBe('UNAVAILABLE');
      expect(await responderStatus(second.id)).toBe('AVAILABLE');

      const stored = await prisma.emergencyRequest.findUnique({
        where: { id: emergency.id },
        select: { status: true },
      });
      // One of two SERVICE units delivered: partially allocated, still open.
      expect(stored.status).toBe('PARTIALLY_ALLOCATED');
    });

    test('a split line completes only when every split allocation is delivered', async () => {
      const emergency = await createEmergency([
        { resourceId: blood.id, quantity: 3 },
      ]);

      const first = await createResponder('Split Done First');
      const firstInventory = await enableCapability(first.id, blood.id);
      const second = await createResponder('Split Done Second');
      const secondInventory = await enableCapability(second.id, blood.id);

      const firstAllocation = await allocate(tokens[first.id], {
        requestId: emergency.id,
        responderResourceId: firstInventory.id,
        resourceId: blood.id,
        quantity: 2,
      });
      const secondAllocation = await allocate(tokens[second.id], {
        requestId: emergency.id,
        responderResourceId: secondInventory.id,
        resourceId: blood.id,
        quantity: 1,
      });
      expect(firstAllocation.statusCode).toBe(201);
      expect(secondAllocation.statusCode).toBe(201);

      await setAllocationStatus(
        tokens[first.id],
        firstAllocation.body.allocation.id,
        'DISPATCHED'
      );
      await setAllocationStatus(
        tokens[first.id],
        firstAllocation.body.allocation.id,
        'DELIVERED'
      );

      // 2 of 3 units delivered: the remaining DISPATCHED/RESERVED split
      // allocation keeps the request open and its owner BUSY.
      let stored = await prisma.emergencyRequest.findUnique({
        where: { id: emergency.id },
        select: { status: true },
      });
      expect(stored.status).toBe('PARTIALLY_ALLOCATED');
      expect(await responderStatus(second.id)).toBe('BUSY');

      await setAllocationStatus(
        tokens[second.id],
        secondAllocation.body.allocation.id,
        'DISPATCHED'
      );
      await confirmReceived(
        requesterToken,
        secondAllocation.body.allocation.id
      );

      stored = await prisma.emergencyRequest.findUnique({
        where: { id: emergency.id },
        select: { status: true },
      });
      expect(stored.status).toBe('COMPLETED');
      expect(await responderStatus(first.id)).toBe('AVAILABLE');
      expect(await responderStatus(second.id)).toBe('AVAILABLE');
    });
  }
);
