// Load backend/.env first so a locally configured PostgreSQL test database is
// detected (same pattern as the multi-responder and concurrency suites).
require('dotenv').config();

const request = require('supertest');
const jwt = require('jsonwebtoken');

const app = require('../../src/app');
const prisma = require('../../src/config/prisma');
const env = require('../../src/config/env');
const requestService = require('../../src/services/requestService');

const hasDatabase = Boolean(process.env.DATABASE_URL && process.env.JWT_SECRET);

// ===========================================================================
// PHASE G: responder assignment lifecycle cleanup and rejoin.
//
// These tests exercise the assignment lifecycle end-to-end against real
// PostgreSQL (route + controller + service + Serializable transaction with
// SELECT ... FOR UPDATE row locks), never a mock:
//
//   - terminal (COMPLETED / CANCELLED) transitions END every ACTIVE assignment
//   - endedAt is populated and acceptedById (the legacy lead) is preserved
//   - ending one responder never touches another responder's assignment
//   - ownership / role authorization on the end transition
//   - an ENDED assignment can be reactivated by reusing the SAME row (the
//     unique (requestId, responderId) pair is never duplicated)
//   - an ACTIVE assignment cannot be duplicated and a terminal request cannot
//     be rejoined
//   - assignment-aware availability synchronisation (BUSY vs AVAILABLE)
//   - the /assigned and /compatible endpoints reflect ended vs active rows
//
// A separate describe block runs the REQUIRED concurrency races with real
// parallel HTTP requests (Promise.all) so the database - not the frontend -
// is proven to be the authority.
// ===========================================================================
(hasDatabase ? describe : describe.skip)(
  'Assignment lifecycle cleanup and rejoin (Phase G)',
  () => {
    const runId = `alc-${Date.now()}`;

    let requester;
    let requesterToken;
    let admin;
    let adminToken;

    let blood; // CONSUMABLE
    let fireTruck; // SERVICE

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

    async function createResponder(name, responderStatus = 'AVAILABLE') {
      const user = await prisma.user.create({
        data: {
          name,
          email: `${runId}-${name.toLowerCase().replace(/\s+/g, '-')}-${responderIds.length}@test.com`,
          password: 'test-password',
          role: 'RESPONDER',
          responderStatus,
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

    async function createEmergency(lines, options = {}) {
      const emergency = await prisma.emergencyRequest.create({
        data: {
          requesterId: requester.id,
          emergencyType: options.emergencyType ?? 'Lifecycle',
          location: options.location ?? 'Thrissur',
          priority: options.priority ?? 'HIGH',
          status: options.status ?? 'PENDING',
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

    // Responder ends their OWN assignment (the only responder-facing route).
    function endOwn(emergencyId, token) {
      return request(app)
        .patch(`/api/requests/${emergencyId}/assignment/end`)
        .set('Authorization', `Bearer ${token}`);
    }

    // Admin ends any responder's assignment on a request.
    function adminEnd(emergencyId, responderId, token = adminToken) {
      return request(app)
        .patch(`/api/admin/requests/${emergencyId}/assignments/${responderId}/end`)
        .set('Authorization', `Bearer ${token}`);
    }

    function adminSetStatus(emergencyId, status, token = adminToken) {
      return request(app)
        .patch(`/api/admin/requests/${emergencyId}/status`)
        .set('Authorization', `Bearer ${token}`)
        .send({ status });
    }

    function cancel(emergencyId, token = requesterToken) {
      return request(app)
        .patch(`/api/requests/${emergencyId}/cancel`)
        .set('Authorization', `Bearer ${token}`);
    }

    function allocate(token, body) {
      return request(app)
        .post('/api/allocations')
        .set('Authorization', `Bearer ${token}`)
        .send(body);
    }

    function compatibleFor(token) {
      return request(app)
        .get('/api/requests/compatible')
        .set('Authorization', `Bearer ${token}`);
    }

    function assignedFor(token) {
      return request(app)
        .get('/api/requests/assigned')
        .set('Authorization', `Bearer ${token}`);
    }

    async function assignmentRow(requestId, responderId) {
      return prisma.responderAssignment.findUnique({
        where: {
          requestId_responderId: { requestId, responderId },
        },
      });
    }

    async function responderStatus(responderId) {
      const row = await prisma.user.findUnique({
        where: { id: responderId },
        select: { responderStatus: true },
      });
      return row.responderStatus;
    }

    beforeAll(async () => {
      requester = await prisma.user.create({
        data: {
          name: 'Lifecycle Requester',
          email: `${runId}-requester@test.com`,
          password: 'test-password',
          role: 'REQUESTER',
          isActive: true,
        },
      });
      requesterToken = tokenFor(requester);

      admin = await prisma.user.create({
        data: {
          name: 'Lifecycle Admin',
          email: `${runId}-admin@test.com`,
          password: 'test-password',
          role: 'ADMIN',
          isActive: true,
        },
      });
      adminToken = tokenFor(admin);

      blood = await prisma.resource.create({
        data: {
          name: `ALC Blood ${runId}`,
          type: 'Medical',
          totalQuantity: 100,
          availableQuantity: 100,
          unit: 'unit',
        },
      });
      fireTruck = await prisma.resource.create({
        data: {
          name: `ALC Fire Truck ${runId}`,
          type: 'Fire',
          mode: 'SERVICE',
          totalQuantity: 0,
          availableQuantity: 0,
        },
      });
    });

    afterAll(async () => {
      // Allocation rows reference requests with ON DELETE RESTRICT, so they go
      // first; assignments cascade with their request.
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
        where: { id: { in: [...responderIds, requester.id, admin.id] } },
      });
      await prisma.$disconnect();
    });

    // ------------------------------------------------------------------
    // 1-4, 22-24: terminal cleanup on a shared multi-responder emergency
    // ------------------------------------------------------------------
    describe('Terminal cleanup', () => {
      test('1. COMPLETED ends every ACTIVE assignment on the request', async () => {
        const emergency = await createEmergency([
          { resourceId: blood.id, quantity: 5 },
          { resourceId: fireTruck.id, quantity: 1 },
        ]);
        const lead = await createResponder('Complete Lead');
        await enableCapability(lead.id, blood.id);
        const second = await createResponder('Complete Second');
        await enableCapability(second.id, fireTruck.id, {
          totalQuantity: 0,
          availableQuantity: 0,
          status: 'UNAVAILABLE',
        });

        expect((await accept(emergency.id, tokens[lead.id])).statusCode).toBe(200);
        expect((await accept(emergency.id, tokens[second.id])).statusCode).toBe(200);

        const activeBefore = await prisma.responderAssignment.count({
          where: { requestId: emergency.id, status: 'ACTIVE' },
        });
        expect(activeBefore).toBe(2);

        const done = await adminSetStatus(emergency.id, 'COMPLETED');
        expect(done.statusCode).toBe(200);

        const activeAfter = await prisma.responderAssignment.count({
          where: { requestId: emergency.id, status: 'ACTIVE' },
        });
        expect(activeAfter).toBe(0);

        const rows = await prisma.responderAssignment.findMany({
          where: { requestId: emergency.id },
        });
        expect(rows).toHaveLength(2);
        expect(rows.every((row) => row.status === 'ENDED')).toBe(true);
      });

      test('2. CANCELLED ends every ACTIVE assignment on the request', async () => {
        const emergency = await createEmergency([
          { resourceId: blood.id, quantity: 5 },
          { resourceId: fireTruck.id, quantity: 1 },
        ]);
        const lead = await createResponder('Cancel Lead');
        await enableCapability(lead.id, blood.id);
        const second = await createResponder('Cancel Second');
        await enableCapability(second.id, fireTruck.id, {
          totalQuantity: 0,
          availableQuantity: 0,
          status: 'UNAVAILABLE',
        });

        await accept(emergency.id, tokens[lead.id]);
        await accept(emergency.id, tokens[second.id]);
        expect(
          await prisma.responderAssignment.count({
            where: { requestId: emergency.id, status: 'ACTIVE' },
          })
        ).toBe(2);

        const cancelled = await cancel(emergency.id);
        expect(cancelled.statusCode).toBe(200);
        expect(cancelled.body.request.status).toBe('CANCELLED');

        expect(
          await prisma.responderAssignment.count({
            where: { requestId: emergency.id, status: 'ACTIVE' },
          })
        ).toBe(0);
      });

      test('3. endedAt is populated on every assignment ended by a terminal transition', async () => {
        const emergency = await createEmergency([{ resourceId: blood.id, quantity: 2 }]);
        const responder = await createResponder('EndedAt Responder');
        await enableCapability(responder.id, blood.id);
        await accept(emergency.id, tokens[responder.id]);

        await adminSetStatus(emergency.id, 'COMPLETED');

        const row = await assignmentRow(emergency.id, responder.id);
        expect(row.status).toBe('ENDED');
        expect(row.endedAt).not.toBeNull();
        expect(row.endedAt.getTime()).toBeGreaterThanOrEqual(row.acceptedAt.getTime());
      });

      test('4. acceptedById (legacy lead) is preserved through a terminal transition', async () => {
        const emergency = await createEmergency([{ resourceId: blood.id, quantity: 2 }]);
        const lead = await createResponder('Preserved Lead');
        await enableCapability(lead.id, blood.id);
        await accept(emergency.id, tokens[lead.id]);

        const before = await prisma.emergencyRequest.findUnique({
          where: { id: emergency.id },
          select: { acceptedById: true, acceptedAt: true },
        });
        expect(before.acceptedById).toBe(lead.id);

        await cancel(emergency.id);

        const after = await prisma.emergencyRequest.findUnique({
          where: { id: emergency.id },
          select: { acceptedById: true, acceptedAt: true, status: true },
        });
        expect(after.status).toBe('CANCELLED');
        expect(after.acceptedById).toBe(lead.id);
        expect(after.acceptedAt.getTime()).toBe(before.acceptedAt.getTime());
      });

      test('23. all ACTIVE assignments are cleaned exactly once on a terminal transition', async () => {
        const emergency = await createEmergency([
          { resourceId: blood.id, quantity: 3 },
          { resourceId: fireTruck.id, quantity: 1 },
        ]);
        const a = await createResponder('Cleanup A');
        await enableCapability(a.id, blood.id);
        const b = await createResponder('Cleanup B');
        await enableCapability(b.id, fireTruck.id, {
          totalQuantity: 0,
          availableQuantity: 0,
          status: 'UNAVAILABLE',
        });
        await accept(emergency.id, tokens[a.id]);
        await accept(emergency.id, tokens[b.id]);

        await adminSetStatus(emergency.id, 'COMPLETED');

        const rows = await prisma.responderAssignment.findMany({
          where: { requestId: emergency.id },
        });
        // No ACTIVE rows remain, and no duplicate rows were created.
        expect(rows.filter((row) => row.status === 'ACTIVE')).toHaveLength(0);
        expect(rows).toHaveLength(2);
        expect(new Set(rows.map((row) => row.responderId)).size).toBe(2);
        expect(rows.every((row) => row.endedAt !== null)).toBe(true);

        // Both responders are released by the terminal transition.
        expect(await responderStatus(a.id)).toBe('AVAILABLE');
        expect(await responderStatus(b.id)).toBe('AVAILABLE');
      });

      test('24. legacy acceptedById compatibility remains correct after cleanup', async () => {
        // A legacy pair: acceptedById is set with NO assignment row (rows
        // written before assignments existed). The assignment table is
        // authoritative for pairs that HAVE a row; legacy pairs fall back to
        // acceptedById.
        const legacyResponder = await createResponder('Legacy Lead');
        await enableCapability(legacyResponder.id, blood.id);
        const emergency = await createEmergency([{ resourceId: blood.id, quantity: 2 }], {
          status: 'ACCEPTED',
        });
        await prisma.emergencyRequest.update({
          where: { id: emergency.id },
          data: { acceptedById: legacyResponder.id, acceptedAt: new Date() },
        });
        await prisma.user.update({
          where: { id: legacyResponder.id },
          data: { responderStatus: 'BUSY' },
        });

        // Legacy lead (no assignment row) still shows the request as assigned.
        const assigned = await assignedFor(tokens[legacyResponder.id]);
        expect(assigned.statusCode).toBe(200);
        expect(assigned.body.requests.map((r) => r.id)).toContain(emergency.id);

        // ...and is excluded from compatible (one active emergency at a time),
        // proving the legacy fallback still counts as an active engagement.
        await prisma.user.update({
          where: { id: legacyResponder.id },
          data: { responderStatus: 'AVAILABLE' },
        });
        const compatible = await compatibleFor(tokens[legacyResponder.id]);
        expect(compatible.statusCode).toBe(200);
        expect(compatible.body.requests.map((r) => r.id)).not.toContain(emergency.id);

        // Cancelling preserves the legacy lead identity.
        await cancel(emergency.id);
        const stored = await prisma.emergencyRequest.findUnique({
          where: { id: emergency.id },
          select: { acceptedById: true, status: true },
        });
        expect(stored.status).toBe('CANCELLED');
        expect(stored.acceptedById).toBe(legacyResponder.id);
      });
    });

    // ------------------------------------------------------------------
    // 5, 6, 22: single-assignment end vs sibling assignments
    // ------------------------------------------------------------------
    describe('Ending a single assignment', () => {
      test('6. a responder can end their own ACTIVE assignment', async () => {
        const emergency = await createEmergency([{ resourceId: blood.id, quantity: 2 }]);
        const responder = await createResponder('End Own Responder');
        await enableCapability(responder.id, blood.id);
        await accept(emergency.id, tokens[responder.id]);

        const response = await endOwn(emergency.id, tokens[responder.id]);
        expect(response.statusCode).toBe(200);

        const row = await assignmentRow(emergency.id, responder.id);
        expect(row.status).toBe('ENDED');
        expect(row.endedAt).not.toBeNull();
      });

      test('5 & 22. ending responder A does not end responder B (B stays ACTIVE)', async () => {
        const emergency = await createEmergency([
          { resourceId: blood.id, quantity: 3 },
          { resourceId: fireTruck.id, quantity: 1 },
        ]);
        const a = await createResponder('Sibling A');
        await enableCapability(a.id, blood.id);
        const b = await createResponder('Sibling B');
        await enableCapability(b.id, fireTruck.id, {
          totalQuantity: 0,
          availableQuantity: 0,
          status: 'UNAVAILABLE',
        });
        await accept(emergency.id, tokens[a.id]);
        await accept(emergency.id, tokens[b.id]);

        // A ends via the admin route (targeting a specific responder).
        const response = await adminEnd(emergency.id, a.id);
        expect(response.statusCode).toBe(200);

        const rowA = await assignmentRow(emergency.id, a.id);
        const rowB = await assignmentRow(emergency.id, b.id);
        expect(rowA.status).toBe('ENDED');
        expect(rowA.endedAt).not.toBeNull();
        // B is untouched: still ACTIVE, no endedAt.
        expect(rowB.status).toBe('ACTIVE');
        expect(rowB.endedAt).toBeNull();

        // The request is still active (B is working it) and B is still BUSY.
        const stored = await prisma.emergencyRequest.findUnique({
          where: { id: emergency.id },
          select: { status: true },
        });
        expect(['ACCEPTED', 'IN_PROGRESS', 'PARTIALLY_ALLOCATED']).toContain(
          stored.status
        );
        expect(await responderStatus(b.id)).toBe('BUSY');
      });
    });

    // ------------------------------------------------------------------
    // 7, 8, 9: authorization on the end transition
    // ------------------------------------------------------------------
    describe('End authorization', () => {
      test('7. a responder cannot end another responder\'s assignment', async () => {
        const emergency = await createEmergency([{ resourceId: blood.id, quantity: 2 }]);
        const owner = await createResponder('Auth Owner');
        await enableCapability(owner.id, blood.id);
        const intruder = await createResponder('Auth Intruder');
        await enableCapability(intruder.id, blood.id);
        await accept(emergency.id, tokens[owner.id]);

        // No responder-facing route accepts a foreign responderId, so this is
        // enforced at the service layer against real PostgreSQL.
        await expect(
          requestService.endResponderAssignment(
            { id: intruder.id, role: 'RESPONDER' },
            emergency.id,
            owner.id
          )
        ).rejects.toThrow('You may only end your own assignment');

        // The owner's assignment is untouched.
        const row = await assignmentRow(emergency.id, owner.id);
        expect(row.status).toBe('ACTIVE');
      });

      test('8. a requester cannot end an assignment', async () => {
        const emergency = await createEmergency([{ resourceId: blood.id, quantity: 2 }]);
        const responder = await createResponder('Auth Requester Target');
        await enableCapability(responder.id, blood.id);
        await accept(emergency.id, tokens[responder.id]);

        // Route-level: the responder end route rejects a REQUESTER role (403).
        const routeResponse = await request(app)
          .patch(`/api/requests/${emergency.id}/assignment/end`)
          .set('Authorization', `Bearer ${requesterToken}`);
        expect(routeResponse.statusCode).toBe(403);

        // Service-level: a REQUESTER actor is rejected regardless of route.
        await expect(
          requestService.endResponderAssignment(
            { id: requester.id, role: 'REQUESTER' },
            emergency.id,
            responder.id
          )
        ).rejects.toThrow('Only responders or admins may end assignments');

        const row = await assignmentRow(emergency.id, responder.id);
        expect(row.status).toBe('ACTIVE');
      });

      test('9. an admin can end any responder\'s assignment', async () => {
        const emergency = await createEmergency([{ resourceId: blood.id, quantity: 2 }]);
        const responder = await createResponder('Admin Target');
        await enableCapability(responder.id, blood.id);
        await accept(emergency.id, tokens[responder.id]);

        const response = await adminEnd(emergency.id, responder.id);
        expect(response.statusCode).toBe(200);

        const row = await assignmentRow(emergency.id, responder.id);
        expect(row.status).toBe('ENDED');
        expect(row.endedAt).not.toBeNull();
      });
    });

    // ------------------------------------------------------------------
    // 10-15: re-ending, reactivation and rejoin rules
    // ------------------------------------------------------------------
    describe('Reactivation and rejoin', () => {
      test('10. an already ENDED assignment cannot be ended again', async () => {
        const emergency = await createEmergency([{ resourceId: blood.id, quantity: 2 }]);
        const responder = await createResponder('Double End Responder');
        await enableCapability(responder.id, blood.id);
        await accept(emergency.id, tokens[responder.id]);

        const first = await endOwn(emergency.id, tokens[responder.id]);
        expect(first.statusCode).toBe(200);

        const second = await endOwn(emergency.id, tokens[responder.id]);
        // The service throws 'Assignment has already ended'; the responder
        // route surfaces it through the error middleware (HTTP 500).
        expect(second.statusCode).toBe(500);
        expect(second.body.message).toBe('Assignment has already ended');

        // Still exactly one row, still ENDED, endedAt unchanged (idempotent).
        const rows = await prisma.responderAssignment.findMany({
          where: { requestId: emergency.id, responderId: responder.id },
        });
        expect(rows).toHaveLength(1);
        expect(rows[0].status).toBe('ENDED');
      });

      test('11, 12 & 13. an ENDED assignment reactivates by reusing the SAME row (no duplicate)', async () => {
        const emergency = await createEmergency([{ resourceId: blood.id, quantity: 3 }]);
        const responder = await createResponder('Reactivate Responder');
        await enableCapability(responder.id, blood.id);

        await accept(emergency.id, tokens[responder.id]);
        const originalRow = await assignmentRow(emergency.id, responder.id);
        expect(originalRow.status).toBe('ACTIVE');

        // End, then rejoin.
        expect((await endOwn(emergency.id, tokens[responder.id])).statusCode).toBe(200);
        const endedRow = await assignmentRow(emergency.id, responder.id);
        expect(endedRow.status).toBe('ENDED');
        expect(endedRow.id).toBe(originalRow.id);

        const rejoin = await accept(emergency.id, tokens[responder.id]);
        expect(rejoin.statusCode).toBe(200);

        const reactivated = await assignmentRow(emergency.id, responder.id);
        // 11: reactivated to ACTIVE with endedAt cleared.
        expect(reactivated.status).toBe('ACTIVE');
        expect(reactivated.endedAt).toBeNull();
        // 12: same physical row is reused.
        expect(reactivated.id).toBe(originalRow.id);
        // 13: no duplicate row for the pair.
        const rows = await prisma.responderAssignment.findMany({
          where: { requestId: emergency.id, responderId: responder.id },
        });
        expect(rows).toHaveLength(1);
      });

      test('14. an ACTIVE assignment cannot be duplicated', async () => {
        const emergency = await createEmergency([{ resourceId: blood.id, quantity: 3 }]);
        const responder = await createResponder('Duplicate Active Responder');
        await enableCapability(responder.id, blood.id);

        expect((await accept(emergency.id, tokens[responder.id])).statusCode).toBe(200);

        // A second acceptance while already ACTIVE is rejected (the responder
        // is now BUSY / already assigned) - the (requestId, responderId)
        // unique constraint is the final safety net.
        const dup = await accept(emergency.id, tokens[responder.id]);
        expect(dup.statusCode).toBe(400);

        const rows = await prisma.responderAssignment.findMany({
          where: { requestId: emergency.id, responderId: responder.id },
        });
        expect(rows).toHaveLength(1);
        expect(rows[0].status).toBe('ACTIVE');
      });

      test('15. a terminal request cannot be reactivated/rejoined', async () => {
        const emergency = await createEmergency([{ resourceId: blood.id, quantity: 2 }]);
        const responder = await createResponder('Terminal Rejoin Responder');
        await enableCapability(responder.id, blood.id);

        await accept(emergency.id, tokens[responder.id]);
        await endOwn(emergency.id, tokens[responder.id]);
        await cancel(emergency.id); // terminal

        const rejoin = await accept(emergency.id, tokens[responder.id]);
        expect(rejoin.statusCode).toBe(400);
        expect(rejoin.body.message).toBe('Request has already been cancelled');

        // The ENDED row is never reactivated on a terminal request.
        const row = await assignmentRow(emergency.id, responder.id);
        expect(row.status).toBe('ENDED');
      });
    });

    // ------------------------------------------------------------------
    // 16, 17: availability synchronisation after an assignment ends
    // ------------------------------------------------------------------
    describe('Availability synchronisation', () => {
      test('16. ENDED assignment + unfinished allocation keeps the responder BUSY', async () => {
        const emergency = await createEmergency([{ resourceId: blood.id, quantity: 2 }]);
        const responder = await createResponder('Busy Alloc Responder');
        const inventory = await enableCapability(responder.id, blood.id);
        await accept(emergency.id, tokens[responder.id]);

        const allocation = await allocate(tokens[responder.id], {
          requestId: emergency.id,
          responderResourceId: inventory.id,
          resourceId: blood.id,
          quantity: 2,
        });
        expect(allocation.statusCode).toBe(201);

        // End the assignment while the RESERVED allocation is still unfinished.
        expect((await endOwn(emergency.id, tokens[responder.id])).statusCode).toBe(200);

        const row = await assignmentRow(emergency.id, responder.id);
        expect(row.status).toBe('ENDED');
        // The unfinished allocation keeps the responder BUSY.
        expect(await responderStatus(responder.id)).toBe('BUSY');
      });

      test('17. ENDED assignment + no unfinished allocation frees the responder (AVAILABLE)', async () => {
        const emergency = await createEmergency([{ resourceId: blood.id, quantity: 2 }]);
        const responder = await createResponder('Free Alloc Responder');
        await enableCapability(responder.id, blood.id);
        await accept(emergency.id, tokens[responder.id]);
        expect(await responderStatus(responder.id)).toBe('BUSY');

        expect((await endOwn(emergency.id, tokens[responder.id])).statusCode).toBe(200);

        const row = await assignmentRow(emergency.id, responder.id);
        expect(row.status).toBe('ENDED');
        expect(await responderStatus(responder.id)).toBe('AVAILABLE');
      });
    });

    // ------------------------------------------------------------------
    // 18-21: endpoint visibility of ended vs active assignments
    // ------------------------------------------------------------------
    describe('Endpoint visibility', () => {
      test('18. /assigned excludes a request the responder only has an ENDED assignment on', async () => {
        const emergency = await createEmergency([{ resourceId: blood.id, quantity: 2 }]);
        const responder = await createResponder('Assigned Ended Responder');
        await enableCapability(responder.id, blood.id);
        await accept(emergency.id, tokens[responder.id]);
        await endOwn(emergency.id, tokens[responder.id]);

        const response = await assignedFor(tokens[responder.id]);
        expect(response.statusCode).toBe(200);
        expect(response.body.requests.map((r) => r.id)).not.toContain(emergency.id);
      });

      test('19. /assigned retains a request while the responder has an unfinished allocation', async () => {
        const emergency = await createEmergency([{ resourceId: blood.id, quantity: 2 }]);
        const responder = await createResponder('Assigned Alloc Responder');
        const inventory = await enableCapability(responder.id, blood.id);
        await accept(emergency.id, tokens[responder.id]);
        const allocation = await allocate(tokens[responder.id], {
          requestId: emergency.id,
          responderResourceId: inventory.id,
          resourceId: blood.id,
          quantity: 2,
        });
        expect(allocation.statusCode).toBe(201);

        // Even with the assignment ENDED, an unfinished allocation keeps the
        // request on the responder's board.
        await endOwn(emergency.id, tokens[responder.id]);

        const response = await assignedFor(tokens[responder.id]);
        expect(response.statusCode).toBe(200);
        expect(response.body.requests.map((r) => r.id)).toContain(emergency.id);
      });

      test('20. /compatible permits a valid rejoin after an assignment ended', async () => {
        // Fire + Blood: after the blood responder ends, the request stays
        // active (lead preserved) with outstanding work, so a rejoin is valid.
        const emergency = await createEmergency([
          { resourceId: blood.id, quantity: 2 },
          { resourceId: fireTruck.id, quantity: 1 },
        ]);
        const responder = await createResponder('Rejoin Compatible Responder');
        await enableCapability(responder.id, blood.id);

        await accept(emergency.id, tokens[responder.id]);
        await endOwn(emergency.id, tokens[responder.id]);
        expect(await responderStatus(responder.id)).toBe('AVAILABLE');

        const compatible = await compatibleFor(tokens[responder.id]);
        expect(compatible.statusCode).toBe(200);
        expect(compatible.body.requests.map((r) => r.id)).toContain(emergency.id);

        // And the rejoin actually succeeds.
        const rejoin = await accept(emergency.id, tokens[responder.id]);
        expect(rejoin.statusCode).toBe(200);
      });

      test('21. /compatible excludes a request the responder is ACTIVE on (no duplicate join)', async () => {
        const emergency = await createEmergency([
          { resourceId: blood.id, quantity: 2 },
          { resourceId: fireTruck.id, quantity: 1 },
        ]);
        const responder = await createResponder('Active Compatible Responder');
        await enableCapability(responder.id, blood.id);

        await accept(emergency.id, tokens[responder.id]);

        const compatible = await compatibleFor(tokens[responder.id]);
        expect(compatible.statusCode).toBe(200);
        // While ACTIVE on this request the responder is already engaged, so it
        // must never be offered again as a compatible (joinable) request.
        expect(compatible.body.requests.map((r) => r.id)).not.toContain(emergency.id);
      });
    });
  }
);

// ===========================================================================
// PHASE G REQUIRED CONCURRENCY TESTS (real PostgreSQL + Promise.all).
//
// Every race below is a genuine parallel HTTP race against real PostgreSQL:
// the acceptance / end / cancel paths run inside the Serializable transaction
// with SELECT ... FOR UPDATE row locks and the serialization-failure retry
// wrapper, so exactly-one-transition and no-duplicate-row guarantees are
// proven by the database, not the client.
// ===========================================================================
(hasDatabase ? describe : describe.skip)(
  'Assignment lifecycle concurrency (Phase G)',
  () => {
    const runId = `alcc-${Date.now()}`;

    let requester;
    let requesterToken;
    let blood;

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
          emergencyType: 'Lifecycle Concurrent',
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

    function endOwn(emergencyId, token) {
      return request(app)
        .patch(`/api/requests/${emergencyId}/assignment/end`)
        .set('Authorization', `Bearer ${token}`);
    }

    function cancel(emergencyId) {
      return request(app)
        .patch(`/api/requests/${emergencyId}/cancel`)
        .set('Authorization', `Bearer ${requesterToken}`);
    }

    beforeAll(async () => {
      requester = await prisma.user.create({
        data: {
          name: 'Lifecycle Concurrency Requester',
          email: `${runId}-requester@test.com`,
          password: 'test-password',
          role: 'REQUESTER',
          isActive: true,
        },
      });
      requesterToken = tokenFor(requester);

      blood = await prisma.resource.create({
        data: {
          name: `ALCC Blood ${runId}`,
          type: 'Medical',
          totalQuantity: 100,
          availableQuantity: 100,
          unit: 'unit',
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
      await prisma.resource.deleteMany({ where: { id: blood.id } });
      await prisma.user.deleteMany({
        where: { id: { in: [...responderIds, requester.id] } },
      });
      await prisma.$disconnect();
    });

    test('A. same responder concurrently reactivates an ENDED assignment -> exactly one ACTIVE row', async () => {
      const emergency = await createEmergency([{ resourceId: blood.id, quantity: 5 }]);
      const responder = await createResponder('ConcA Reactivator');
      await enableCapability(responder.id, blood.id);

      // Establish an ENDED assignment to race the reactivation on.
      expect((await accept(emergency.id, tokens[responder.id])).statusCode).toBe(200);
      expect((await endOwn(emergency.id, tokens[responder.id])).statusCode).toBe(200);
      const endedRow = await prisma.responderAssignment.findUnique({
        where: {
          requestId_responderId: {
            requestId: emergency.id,
            responderId: responder.id,
          },
        },
      });
      expect(endedRow.status).toBe('ENDED');

      const [first, second] = await Promise.all([
        accept(emergency.id, tokens[responder.id]),
        accept(emergency.id, tokens[responder.id]),
      ]);

      // Exactly one reactivation may win; the loser is rejected (400).
      const outcomes = [first.statusCode, second.statusCode].sort();
      expect(outcomes).toEqual([200, 400]);

      // Exactly one ACTIVE row, and still only ONE row for the pair - the
      // ENDED row was reused, never duplicated.
      const rows = await prisma.responderAssignment.findMany({
        where: { requestId: emergency.id, responderId: responder.id },
      });
      expect(rows).toHaveLength(1);
      expect(rows[0].id).toBe(endedRow.id);
      expect(rows[0].status).toBe('ACTIVE');
      expect(rows[0].endedAt).toBeNull();

      const activeCount = await prisma.responderAssignment.count({
        where: { requestId: emergency.id, status: 'ACTIVE' },
      });
      expect(activeCount).toBe(1);
    });

    test('B. one responder ends while another accepts -> valid final state', async () => {
      const emergency = await createEmergency([{ resourceId: blood.id, quantity: 5 }]);
      const a = await createResponder('ConcB Ender');
      await enableCapability(a.id, blood.id);
      const b = await createResponder('ConcB Joiner');
      await enableCapability(b.id, blood.id);

      // A is already ACTIVE; B has not joined yet.
      expect((await accept(emergency.id, tokens[a.id])).statusCode).toBe(200);

      const [endResult, acceptResult] = await Promise.all([
        endOwn(emergency.id, tokens[a.id]),
        accept(emergency.id, tokens[b.id]),
      ]);

      expect(endResult.statusCode).toBe(200);
      expect(acceptResult.statusCode).toBe(200);

      const rowA = await prisma.responderAssignment.findUnique({
        where: {
          requestId_responderId: { requestId: emergency.id, responderId: a.id },
        },
      });
      const rowB = await prisma.responderAssignment.findUnique({
        where: {
          requestId_responderId: { requestId: emergency.id, responderId: b.id },
        },
      });

      // Final state is consistent regardless of interleaving: A ended, B active.
      expect(rowA.status).toBe('ENDED');
      expect(rowA.endedAt).not.toBeNull();
      expect(rowB.status).toBe('ACTIVE');
      expect(rowB.endedAt).toBeNull();

      // Exactly one ACTIVE assignment remains and the request stays active.
      const activeCount = await prisma.responderAssignment.count({
        where: { requestId: emergency.id, status: 'ACTIVE' },
      });
      expect(activeCount).toBe(1);
      const stored = await prisma.emergencyRequest.findUnique({
        where: { id: emergency.id },
        select: { status: true },
      });
      expect(['ACCEPTED', 'IN_PROGRESS', 'PARTIALLY_ALLOCATED']).toContain(
        stored.status
      );
    });

    test('C. a terminal transition races a reactivation -> terminal request, zero ACTIVE assignments', async () => {
      const emergency = await createEmergency([{ resourceId: blood.id, quantity: 5 }]);
      const responder = await createResponder('ConcC Reactivator');
      await enableCapability(responder.id, blood.id);

      // ENDED assignment on an otherwise active request.
      expect((await accept(emergency.id, tokens[responder.id])).statusCode).toBe(200);
      expect((await endOwn(emergency.id, tokens[responder.id])).statusCode).toBe(200);

      const [cancelResult, reactivateResult] = await Promise.all([
        cancel(emergency.id),
        accept(emergency.id, tokens[responder.id]),
      ]);

      // The cancellation always wins its own race.
      expect(cancelResult.statusCode).toBe(200);
      // The reactivation either lost the lock race (request already terminal ->
      // 400) or briefly reactivated before the cancellation ENDED it again.
      expect([200, 400]).toContain(reactivateResult.statusCode);

      const stored = await prisma.emergencyRequest.findUnique({
        where: { id: emergency.id },
        select: { status: true },
      });
      expect(stored.status).toBe('CANCELLED');

      // Whatever the interleaving, the terminal transition leaves NO ACTIVE
      // assignment behind.
      const activeCount = await prisma.responderAssignment.count({
        where: { requestId: emergency.id, status: 'ACTIVE' },
      });
      expect(activeCount).toBe(0);

      // ...and the responder is freed.
      const stateAfter = await prisma.user.findUnique({
        where: { id: responder.id },
        select: { responderStatus: true },
      });
      expect(stateAfter.responderStatus).toBe('AVAILABLE');
    });

    test('D. two concurrent end requests for the same assignment -> one effective transition', async () => {
      const emergency = await createEmergency([{ resourceId: blood.id, quantity: 5 }]);
      const responder = await createResponder('ConcD Double Ender');
      await enableCapability(responder.id, blood.id);
      expect((await accept(emergency.id, tokens[responder.id])).statusCode).toBe(200);

      const [first, second] = await Promise.all([
        endOwn(emergency.id, tokens[responder.id]),
        endOwn(emergency.id, tokens[responder.id]),
      ]);

      // Exactly one effective transition: one succeeds, the other observes the
      // already-ENDED state (surfaced as HTTP 500 by the error middleware).
      const outcomes = [first.statusCode, second.statusCode].sort();
      expect(outcomes).toEqual([200, 500]);
      const loser = [first, second].find((r) => r.statusCode === 500);
      expect(loser.body.message).toBe('Assignment has already ended');

      // No duplicate side effects: one row, ENDED, a single endedAt.
      const rows = await prisma.responderAssignment.findMany({
        where: { requestId: emergency.id, responderId: responder.id },
      });
      expect(rows).toHaveLength(1);
      expect(rows[0].status).toBe('ENDED');
      expect(rows[0].endedAt).not.toBeNull();
    });
  }
);
