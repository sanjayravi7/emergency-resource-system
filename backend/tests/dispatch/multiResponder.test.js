// Load backend/.env first so a locally configured PostgreSQL test database is
// detected (same pattern as the socket integration suite).
require('dotenv').config();

const request = require('supertest');
const jwt = require('jsonwebtoken');

const app = require('../../src/app');
const prisma = require('../../src/config/prisma');
const env = require('../../src/config/env');

const hasDatabase = Boolean(process.env.DATABASE_URL && process.env.JWT_SECRET);

// PHASE C: transactional multi-responder acceptance.
//
// These tests exercise PATCH /api/requests/:id/accept (route + controller +
// service + Serializable transaction) against real PostgreSQL:
//   - multiple responders per emergency via ResponderAssignment
//   - acceptedById stays the FIRST/lead responder, never overwritten
//   - PARTIAL capability matching (at least one required resource line with
//     outstanding quantity the responder can serve under the mode rules)
//   - duplicate / incompatible / unavailable / terminal-state rejections
//   - assignment-aware responder availability
(hasDatabase ? describe : describe.skip)(
  'Multi-responder acceptance (Phase C)',
  () => {
    const runId = `mresp-${Date.now()}`;

    let requester;
    let requesterToken;
    // Capability matrix:
    //   responderBlood   -> Blood (CONSUMABLE)
    //   responderFire    -> Fire Truck (SERVICE)
    //   responderBoat    -> Rescue Boat (SERVICE, zero overlap with the
    //                       blood+fire emergencies)
    //   responderBlood2  -> Blood (second consumable responder)
    //   responderFull    -> Blood + Fire (fully capable)
    //   responderNone    -> no capabilities at all
    let responderBlood;
    let responderFire;
    let responderBoat;
    let responderBlood2;
    let responderFull;
    let responderNone;
    let tokens = {};

    let blood;
    let fireTruck;
    let rescueBoat;

    const createdRequestIds = [];
    const responderIds = [];

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
          email: `${runId}-${name.toLowerCase().replace(/\s+/g, '-')}@test.com`,
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
          emergencyType: options.emergencyType ?? 'Multi',
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
      const bearer = token || tokens[responderBlood.id];
      return request(app)
        .patch(`/api/requests/${emergencyId}/accept`)
        .set('Authorization', `Bearer ${bearer}`);
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

    beforeAll(async () => {
      requester = await prisma.user.create({
        data: {
          name: 'Multi Responder Requester',
          email: `${runId}-requester@test.com`,
          password: 'test-password',
          role: 'REQUESTER',
          isActive: true,
        },
      });
      requesterToken = tokenFor(requester);

      responderBlood = await createResponder('Blood Responder');
      responderFire = await createResponder('Fire Responder');
      responderBoat = await createResponder('Boat Responder');
      responderBlood2 = await createResponder('Blood Responder Two');
      responderFull = await createResponder('Full Responder');
      responderNone = await createResponder('No Capability Responder');

      blood = await prisma.resource.create({
        data: {
          name: `MR Blood ${runId}`,
          type: 'Medical',
          totalQuantity: 100,
          availableQuantity: 100,
          unit: 'unit',
        },
      });
      fireTruck = await prisma.resource.create({
        data: {
          name: `MR Fire Truck ${runId}`,
          type: 'Fire',
          mode: 'SERVICE',
          totalQuantity: 0,
          availableQuantity: 0,
        },
      });
      rescueBoat = await prisma.resource.create({
        data: {
          name: `MR Rescue Boat ${runId}`,
          type: 'Rescue',
          mode: 'SERVICE',
          totalQuantity: 0,
          availableQuantity: 0,
        },
      });

      await enableCapability(responderBlood.id, blood.id);
      await enableCapability(responderFire.id, fireTruck.id, {
        totalQuantity: 0,
        availableQuantity: 0,
        status: 'UNAVAILABLE', // SERVICE rows never depend on stock status
      });
      await enableCapability(responderBoat.id, rescueBoat.id, {
        totalQuantity: 0,
        availableQuantity: 0,
        status: 'UNAVAILABLE',
      });
      await enableCapability(responderBlood2.id, blood.id);
      await enableCapability(responderFull.id, blood.id);
      await enableCapability(responderFull.id, fireTruck.id, {
        totalQuantity: 0,
        availableQuantity: 0,
        status: 'UNAVAILABLE',
      });
    });

    afterAll(async () => {
      // Allocation rows reference requests with ON DELETE RESTRICT, so they
      // go first; assignments cascade with their request.
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
        where: { id: { in: [blood.id, fireTruck.id, rescueBoat.id] } },
      });
      await prisma.user.deleteMany({
        where: { id: { in: [...responderIds, requester.id] } },
      });
      await prisma.$disconnect();
    });

    // The shared emergency used by tests 1-9: Blood (CONSUMABLE, qty 5) +
    // Fire Truck (SERVICE, qty 1). Nobody can cover both except
    // responderFull, so every acceptance below is a PARTIAL acceptance.
    let sharedEmergency;

    // ------------------------------------------------------------------
    // 1-4: first acceptance
    // ------------------------------------------------------------------

    test('1. first responder can accept a PENDING compatible request', async () => {
      sharedEmergency = await createEmergency([
        { resourceId: blood.id, quantity: 5 },
        { resourceId: fireTruck.id, quantity: 1 },
      ]);

      const response = await accept(sharedEmergency.id);
      expect(response.statusCode).toBe(200);
      expect(response.body.success).toBe(true);
      expect(response.body.request.status).toBe('ACCEPTED');
    });

    test('2. first acceptance creates exactly one ACTIVE assignment', async () => {
      const assignments = await prisma.responderAssignment.findMany({
        where: { requestId: sharedEmergency.id },
      });
      expect(assignments).toHaveLength(1);
      expect(assignments[0].responderId).toBe(responderBlood.id);
      expect(assignments[0].status).toBe('ACTIVE');
      expect(assignments[0].endedAt).toBeNull();
      expect(assignments[0].acceptedAt).not.toBeNull();
    });

    test('3. acceptedById is set to the first responder', async () => {
      const stored = await prisma.emergencyRequest.findUnique({
        where: { id: sharedEmergency.id },
        select: { acceptedById: true },
      });
      expect(stored.acceptedById).toBe(responderBlood.id);
    });

    test('4. acceptedAt is set on the request and matches the assignment window', async () => {
      const stored = await prisma.emergencyRequest.findUnique({
        where: { id: sharedEmergency.id },
        select: { acceptedAt: true },
      });
      const assignment = await prisma.responderAssignment.findFirst({
        where: { requestId: sharedEmergency.id, responderId: responderBlood.id },
      });

      expect(stored.acceptedAt).not.toBeNull();
      expect(assignment.acceptedAt).not.toBeNull();
      // Both timestamps were written by the same transaction.
      expect(stored.acceptedAt.getTime()).toBe(assignment.acceptedAt.getTime());
    });

    // ------------------------------------------------------------------
    // 5-8: additional responders
    // ------------------------------------------------------------------

    test('5. second PARTIAL-capability responder can accept the same request', async () => {
      // responderFire can only serve the Fire Truck line - partial coverage.
      const response = await accept(sharedEmergency.id, tokens[responderFire.id]);
      expect(response.statusCode).toBe(200);
      expect(response.body.request.status).toBe('ACCEPTED');
    });

    test('6. second acceptance creates another ACTIVE assignment', async () => {
      const assignments = await prisma.responderAssignment.findMany({
        where: { requestId: sharedEmergency.id, status: 'ACTIVE' },
        orderBy: { id: 'asc' },
      });
      expect(assignments).toHaveLength(2);
      expect(assignments.map((row) => row.responderId)).toEqual(
        expect.arrayContaining([responderBlood.id, responderFire.id])
      );
    });

    test('7. acceptedById remains the FIRST responder after later acceptances', async () => {
      const stored = await prisma.emergencyRequest.findUnique({
        where: { id: sharedEmergency.id },
        select: { acceptedById: true },
      });
      expect(stored.acceptedById).toBe(responderBlood.id);
    });

    test('8. a third compatible responder can also be assigned', async () => {
      const response = await accept(sharedEmergency.id, tokens[responderBlood2.id]);
      expect(response.statusCode).toBe(200);

      const assignments = await prisma.responderAssignment.findMany({
        where: { requestId: sharedEmergency.id, status: 'ACTIVE' },
      });
      expect(assignments).toHaveLength(3);
      expect(assignments.map((row) => row.responderId)).toEqual(
        expect.arrayContaining([
          responderBlood.id,
          responderFire.id,
          responderBlood2.id,
        ])
      );

      const stored = await prisma.emergencyRequest.findUnique({
        where: { id: sharedEmergency.id },
        select: { acceptedById: true, status: true },
      });
      expect(stored.acceptedById).toBe(responderBlood.id);
      expect(stored.status).toBe('ACCEPTED');
    });

    // ------------------------------------------------------------------
    // 9-11: rejections
    // ------------------------------------------------------------------

    test('9. duplicate responder assignment is rejected', async () => {
      // responderBlood2 already holds an ACTIVE assignment; normally their
      // BUSY status hides this behind the availability check, so simulate the
      // stale-availability race the duplicate check exists for.
      await prisma.user.update({
        where: { id: responderBlood2.id },
        data: { responderStatus: 'AVAILABLE' },
      });

      const response = await accept(sharedEmergency.id, tokens[responderBlood2.id]);
      expect(response.statusCode).toBe(400);
      expect(response.body.message).toBe('Responder is already assigned to this request');

      // Still exactly one ACTIVE assignment for this pair.
      const assignments = await prisma.responderAssignment.findMany({
        where: {
          requestId: sharedEmergency.id,
          responderId: responderBlood2.id,
        },
      });
      expect(assignments).toHaveLength(1);
    });

    test('10. incompatible responder (wrong capability) is rejected', async () => {
      // responderBoat only has Rescue Boat - zero overlap with Blood+Fire.
      const response = await accept(sharedEmergency.id, tokens[responderBoat.id]);
      expect(response.statusCode).toBe(400);
      expect(response.body.message).toBe(
        'Responder has no compatible resource with outstanding quantity'
      );
    });

    test('11. responder with zero matching capabilities is rejected', async () => {
      const response = await accept(sharedEmergency.id, tokens[responderNone.id]);
      expect(response.statusCode).toBe(400);
      expect(response.body.message).toBe(
        'Responder has no compatible resource with outstanding quantity'
      );
    });

    // ------------------------------------------------------------------
    // 12-13: partial vs full capability
    // ------------------------------------------------------------------

    test('12. partial-capability responder is accepted on a fresh emergency', async () => {
      const emergency = await createEmergency([
        { resourceId: blood.id, quantity: 2 },
        { resourceId: fireTruck.id, quantity: 1 },
      ]);

      // Fire-only responder joins a Blood+Fire emergency.
      const partial = await createResponder('Partial Fire Responder');
      await enableCapability(partial.id, fireTruck.id, {
        totalQuantity: 0,
        availableQuantity: 0,
        status: 'UNAVAILABLE',
      });

      const response = await accept(emergency.id, tokens[partial.id]);
      expect(response.statusCode).toBe(200);

      const stored = await prisma.emergencyRequest.findUnique({
        where: { id: emergency.id },
        select: { status: true, acceptedById: true },
      });
      expect(stored.status).toBe('ACCEPTED');
      expect(stored.acceptedById).toBe(partial.id);
    });

    test('13. fully capable responder is accepted', async () => {
      const emergency = await createEmergency([
        { resourceId: blood.id, quantity: 2 },
        { resourceId: fireTruck.id, quantity: 1 },
      ]);

      const response = await accept(emergency.id, tokens[responderFull.id]);
      expect(response.statusCode).toBe(200);
      expect(response.body.request.status).toBe('ACCEPTED');
      expect(response.body.request.acceptedById).toBe(responderFull.id);
    });

    // ------------------------------------------------------------------
    // 14: outstanding quantity
    // ------------------------------------------------------------------

    test('14. request with all relevant quantity already satisfied is not accepted', async () => {
      const emergency = await createEmergency([
        { resourceId: blood.id, quantity: 2 },
      ]);

      const allocator = await createResponder('Satisfied Allocator');
      await enableCapability(allocator.id, blood.id);
      const candidate = await createResponder('Satisfied Candidate');
      await enableCapability(candidate.id, blood.id);

      // Fully allocate the required quantity (the existing
      // allocate-without-accepting flow stays available).
      const inventory = await prisma.responderResource.findFirst({
        where: { responderId: allocator.id, resourceId: blood.id },
      });
      const allocationResponse = await request(app)
        .post('/api/allocations')
        .set('Authorization', `Bearer ${tokens[allocator.id]}`)
        .send({
          requestId: emergency.id,
          responderResourceId: inventory.id,
          resourceId: blood.id,
          quantity: 2,
        });
      expect(allocationResponse.statusCode).toBe(201);

      // The candidate is compatible with Blood, but nothing is outstanding.
      const response = await accept(emergency.id, tokens[candidate.id]);
      expect(response.statusCode).toBe(400);
      expect(response.body.message).toBe(
        'Responder has no compatible resource with outstanding quantity'
      );
    });

    // ------------------------------------------------------------------
    // 15-18: responder/request state rejections
    // ------------------------------------------------------------------

    test('15. inactive responder is rejected', async () => {
      const inactive = await createResponder('Inactive Responder');
      await enableCapability(inactive.id, blood.id);
      await prisma.user.update({
        where: { id: inactive.id },
        data: { isActive: false },
      });

      const emergency = await createEmergency([{ resourceId: blood.id, quantity: 1 }]);
      const response = await accept(emergency.id, tokens[inactive.id]);
      expect(response.statusCode).toBe(401);
    });

    test('16. non-RESPONDER cannot accept (role authorization)', async () => {
      const emergency = await createEmergency([{ resourceId: blood.id, quantity: 1 }]);
      const response = await accept(emergency.id, requesterToken);
      expect(response.statusCode).toBe(403);
    });

    test('17. CANCELLED request is rejected', async () => {
      const emergency = await createEmergency([{ resourceId: blood.id, quantity: 1 }]);
      const cancelResponse = await request(app)
        .patch(`/api/requests/${emergency.id}/cancel`)
        .set('Authorization', `Bearer ${requesterToken}`);
      expect(cancelResponse.statusCode).toBe(200);

      const responder = await createResponder('Cancelled Target Responder');
      await enableCapability(responder.id, blood.id);
      const response = await accept(emergency.id, tokens[responder.id]);
      expect(response.statusCode).toBe(400);
      expect(response.body.message).toBe('Request has already been cancelled');
    });

    test('18. COMPLETED request is rejected', async () => {
      const emergency = await createEmergency([{ resourceId: blood.id, quantity: 1 }]);

      // Drive the full lifecycle to COMPLETED with fresh responders.
      const driver = await createResponder('Completion Driver');
      await enableCapability(driver.id, blood.id);
      const candidate = await createResponder('Completion Candidate');
      await enableCapability(candidate.id, blood.id);

      await accept(emergency.id, tokens[driver.id]);
      const inventory = await prisma.responderResource.findFirst({
        where: { responderId: driver.id, resourceId: blood.id },
      });
      const allocation = await request(app)
        .post('/api/allocations')
        .set('Authorization', `Bearer ${tokens[driver.id]}`)
        .send({
          requestId: emergency.id,
          responderResourceId: inventory.id,
          resourceId: blood.id,
          quantity: 1,
        });
      expect(allocation.statusCode).toBe(201);

      await request(app)
        .patch(`/api/allocations/${allocation.body.allocation.id}/status`)
        .set('Authorization', `Bearer ${tokens[driver.id]}`)
        .send({ status: 'DISPATCHED' });
      await request(app)
        .patch(`/api/allocations/${allocation.body.allocation.id}/status`)
        .set('Authorization', `Bearer ${tokens[driver.id]}`)
        .send({ status: 'DELIVERED' });

      const completed = await prisma.emergencyRequest.findUnique({
        where: { id: emergency.id },
        select: { status: true },
      });
      expect(completed.status).toBe('COMPLETED');

      const response = await accept(emergency.id, tokens[candidate.id]);
      expect(response.statusCode).toBe(400);
      expect(response.body.message).toBe('Request has already been completed');
    });

    // ------------------------------------------------------------------
    // 19: one active emergency per responder (existing rule)
    // ------------------------------------------------------------------

    test('19. existing conflicting active-emergency rule is enforced', async () => {
      const first = await createEmergency([{ resourceId: blood.id, quantity: 1 }]);
      const second = await createEmergency([{ resourceId: blood.id, quantity: 1 }]);

      const responder = await createResponder('Conflict Responder');
      await enableCapability(responder.id, blood.id);

      const firstResponse = await accept(first.id, tokens[responder.id]);
      expect(firstResponse.statusCode).toBe(200);

      // The availability check normally rejects the second attempt; force
      // the stale-availability path so the conflict rule itself is what
      // rejects it (the assignment table is authoritative).
      await prisma.user.update({
        where: { id: responder.id },
        data: { responderStatus: 'AVAILABLE' },
      });

      const secondResponse = await accept(second.id, tokens[responder.id]);
      expect(secondResponse.statusCode).toBe(400);
      expect(secondResponse.body.message).toBe(
        'Responder already has an active emergency'
      );

      // No assignment leaked onto the second request.
      const assignmentsOnSecond = await prisma.responderAssignment.findMany({
        where: { requestId: second.id, responderId: responder.id },
      });
      expect(assignmentsOnSecond).toHaveLength(0);
    });

    // ------------------------------------------------------------------
    // 20-21: assigned endpoint
    // ------------------------------------------------------------------

    test('20. assigned endpoint returns requests with an ACTIVE assignment', async () => {
      const response = await assignedFor(tokens[responderFire.id]);
      expect(response.statusCode).toBe(200);

      const ids = response.body.requests.map((row) => row.id);
      expect(ids).toContain(sharedEmergency.id);
    });

    test('21. assigned endpoint still returns unfinished-allocation-only requests', async () => {
      // Legacy flow: a responder allocates on a PENDING request without
      // accepting it. The request must stay on their board.
      const emergency = await createEmergency([{ resourceId: blood.id, quantity: 1 }]);
      const inventory = await prisma.responderResource.findFirst({
        where: { responderId: responderBlood.id, resourceId: blood.id },
      });
      const allocation = await request(app)
        .post('/api/allocations')
        .set('Authorization', `Bearer ${tokens[responderBlood.id]}`)
        .send({
          requestId: emergency.id,
          responderResourceId: inventory.id,
          resourceId: blood.id,
          quantity: 1,
        });
      expect(allocation.statusCode).toBe(201);

      const response = await assignedFor(tokens[responderBlood.id]);
      const ids = response.body.requests.map((row) => row.id);
      expect(ids).toContain(emergency.id);

      // No duplicate rows for the same request.
      const duplicates = response.body.requests.filter(
        (row) => row.id === emergency.id
      );
      expect(duplicates).toHaveLength(1);
    });

    // ------------------------------------------------------------------
    // 22-23: compatible endpoint
    // ------------------------------------------------------------------

    test('22. compatible endpoint excludes requests the responder is already assigned to', async () => {
      // responderFire holds an ACTIVE assignment on sharedEmergency. Even
      // with a stale AVAILABLE status (which normally hides everything via
      // the one-active-emergency rule), the assignment itself must keep the
      // request off their compatible list.
      await prisma.user.update({
        where: { id: responderFire.id },
        data: { responderStatus: 'AVAILABLE' },
      });

      const response = await compatibleFor(tokens[responderFire.id]);
      expect(response.statusCode).toBe(200);

      // The one-active-emergency rule means nothing else is compatible
      // either; the important part is sharedEmergency is NOT offered again.
      expect(response.body.requests.map((row) => row.id)).not.toContain(
        sharedEmergency.id
      );
    });

    test('23. compatible endpoint exposes remaining compatible work on active requests', async () => {
      // An ACCEPTED emergency whose Blood line is fully allocated still has
      // a Fire Truck line outstanding: a fire-capable AVAILABLE responder
      // must still see it (multi-responder dispatch).
      const emergency = await createEmergency([
        { resourceId: blood.id, quantity: 1 },
        { resourceId: fireTruck.id, quantity: 1 },
      ]);

      const lead = await createResponder('Remaining Work Lead');
      await enableCapability(lead.id, blood.id);
      await enableCapability(lead.id, fireTruck.id, {
        totalQuantity: 0,
        availableQuantity: 0,
        status: 'UNAVAILABLE',
      });

      await accept(emergency.id, tokens[lead.id]);

      const inventory = await prisma.responderResource.findFirst({
        where: { responderId: lead.id, resourceId: blood.id },
      });
      const allocation = await request(app)
        .post('/api/allocations')
        .set('Authorization', `Bearer ${tokens[lead.id]}`)
        .send({
          requestId: emergency.id,
          responderResourceId: inventory.id,
          resourceId: blood.id,
          quantity: 1,
        });
      expect(allocation.statusCode).toBe(201);

      // responderFire2: fresh AVAILABLE fire-only responder.
      const responderFire2 = await createResponder('Fire Responder Two');
      await enableCapability(responderFire2.id, fireTruck.id, {
        totalQuantity: 0,
        availableQuantity: 0,
        status: 'UNAVAILABLE',
      });

      const response = await compatibleFor(tokens[responderFire2.id]);
      expect(response.statusCode).toBe(200);
      expect(response.body.requests.map((row) => row.id)).toContain(emergency.id);

      // And the same responder CAN accept it afterwards.
      const acceptResponse = await accept(emergency.id, tokens[responderFire2.id]);
      expect(acceptResponse.statusCode).toBe(200);
    });

    // ------------------------------------------------------------------
    // 24-25: assignment ending integrity
    // ------------------------------------------------------------------

    test('24. ending one assignment does not delete another assignment', async () => {
      const before = await prisma.responderAssignment.findMany({
        where: { requestId: sharedEmergency.id, status: 'ACTIVE' },
      });
      expect(before.length).toBeGreaterThanOrEqual(2);

      // End the fire responder's assignment directly (no ending API exists
      // yet; later phases will own that transition).
      await prisma.responderAssignment.updateMany({
        where: {
          requestId: sharedEmergency.id,
          responderId: responderFire.id,
        },
        data: { status: 'ENDED', endedAt: new Date() },
      });

      const after = await prisma.responderAssignment.findMany({
        where: { requestId: sharedEmergency.id, status: 'ACTIVE' },
      });
      expect(after.map((row) => row.responderId)).not.toContain(responderFire.id);
      expect(after.length).toBe(before.length - 1);

      // The ENDED row is retained (history), not deleted.
      const endedRow = await prisma.responderAssignment.findFirst({
        where: {
          requestId: sharedEmergency.id,
          responderId: responderFire.id,
          status: 'ENDED',
        },
      });
      expect(endedRow).not.toBeNull();
      expect(endedRow.endedAt).not.toBeNull();
    });

    test('25. ending the lead responder assignment does not overwrite acceptedById', async () => {
      await prisma.responderAssignment.updateMany({
        where: {
          requestId: sharedEmergency.id,
          responderId: responderBlood.id,
        },
        data: { status: 'ENDED', endedAt: new Date() },
      });

      const stored = await prisma.emergencyRequest.findUnique({
        where: { id: sharedEmergency.id },
        select: { acceptedById: true, acceptedAt: true, status: true },
      });

      // The lead responder identity and timestamp are preserved exactly.
      expect(stored.acceptedById).toBe(responderBlood.id);
      expect(stored.acceptedAt).not.toBeNull();
      expect(stored.status).not.toBe('PENDING');
    });

    // ------------------------------------------------------------------
    // Part 8 availability regressions
    // ------------------------------------------------------------------

    test('26. responder with an ACTIVE assignment is BUSY even without allocations', async () => {
      const responder = await createResponder('Availability Responder');
      await enableCapability(responder.id, blood.id);
      const emergency = await createEmergency([{ resourceId: blood.id, quantity: 1 }]);

      const response = await accept(emergency.id, tokens[responder.id]);
      expect(response.statusCode).toBe(200);

      const stored = await prisma.user.findUnique({
        where: { id: responder.id },
        select: { responderStatus: true },
      });
      expect(stored.responderStatus).toBe('BUSY');
    });

    test('27. ENDED assignment with an unfinished allocation still keeps the responder BUSY', async () => {
      const responder = await createResponder('Allocation Busy Responder');
      await enableCapability(responder.id, blood.id);
      const emergency = await createEmergency([{ resourceId: blood.id, quantity: 1 }]);

      await accept(emergency.id, tokens[responder.id]);
      const inventory = await prisma.responderResource.findFirst({
        where: { responderId: responder.id, resourceId: blood.id },
      });
      const allocation = await request(app)
        .post('/api/allocations')
        .set('Authorization', `Bearer ${tokens[responder.id]}`)
        .send({
          requestId: emergency.id,
          responderResourceId: inventory.id,
          resourceId: blood.id,
          quantity: 1,
        });
      expect(allocation.statusCode).toBe(201);

      // End the assignment while the allocation is still unfinished.
      await prisma.responderAssignment.updateMany({
        where: { requestId: emergency.id, responderId: responder.id },
        data: { status: 'ENDED', endedAt: new Date() },
      });

      // Logout re-runs the authoritative availability sync: the RESERVED
      // allocation must keep the responder BUSY, never OFFLINE/AVAILABLE.
      const logout = await request(app)
        .post('/api/responders/logout')
        .set('Authorization', `Bearer ${tokens[responder.id]}`);
      expect(logout.statusCode).toBe(200);

      const afterLogout = await prisma.user.findUnique({
        where: { id: responder.id },
        select: { responderStatus: true },
      });
      expect(afterLogout.responderStatus).toBe('BUSY');
    });

    test('28. responder becomes AVAILABLE only with no active assignment and no unfinished allocation', async () => {
      const responder = await createResponder('Free Responder');
      await enableCapability(responder.id, blood.id);
      // Blood + Fire: delivering the Blood line leaves the request
      // PARTIALLY_ALLOCATED (still active) while this responder's own work
      // is finished.
      const emergency = await createEmergency([
        { resourceId: blood.id, quantity: 1 },
        { resourceId: fireTruck.id, quantity: 1 },
      ]);

      await accept(emergency.id, tokens[responder.id]);
      const inventory = await prisma.responderResource.findFirst({
        where: { responderId: responder.id, resourceId: blood.id },
      });
      const allocation = await request(app)
        .post('/api/allocations')
        .set('Authorization', `Bearer ${tokens[responder.id]}`)
        .send({
          requestId: emergency.id,
          responderResourceId: inventory.id,
          resourceId: blood.id,
          quantity: 1,
        });
      expect(allocation.statusCode).toBe(201);

      // Assignment still ACTIVE + allocation DISPATCHED -> still BUSY.
      await request(app)
        .patch(`/api/allocations/${allocation.body.allocation.id}/status`)
        .set('Authorization', `Bearer ${tokens[responder.id]}`)
        .send({ status: 'DISPATCHED' });

      let stored = await prisma.user.findUnique({
        where: { id: responder.id },
        select: { responderStatus: true },
      });
      expect(stored.responderStatus).toBe('BUSY');

      // Deliver the Blood line: the responder's own allocation is finished,
      // but their assignment is still ACTIVE on a PARTIALLY_ALLOCATED
      // (active) request, so they must remain BUSY - never AVAILABLE just
      // because one allocation finished.
      await request(app)
        .patch(`/api/allocations/${allocation.body.allocation.id}/status`)
        .set('Authorization', `Bearer ${tokens[responder.id]}`)
        .send({ status: 'DELIVERED' });

      stored = await prisma.user.findUnique({
        where: { id: responder.id },
        select: { responderStatus: true },
      });
      expect(stored.responderStatus).toBe('BUSY');

      const requestState = await prisma.emergencyRequest.findUnique({
        where: { id: emergency.id },
        select: { status: true },
      });
      expect(requestState.status).toBe('PARTIALLY_ALLOCATED');

      // End the assignment: no active assignment on an active request and
      // no unfinished allocation remain, and the capability still has stock,
      // so the responder is freed even though the emergency stays open for
      // other responders (the Fire line is still outstanding).
      await prisma.responderAssignment.updateMany({
        where: { requestId: emergency.id, responderId: responder.id },
        data: { status: 'ENDED', endedAt: new Date() },
      });
      await prisma.user.update({
        where: { id: responder.id },
        data: { responderStatus: 'OFFLINE' },
      });
      const logout = await request(app)
        .post('/api/responders/logout')
        .set('Authorization', `Bearer ${tokens[responder.id]}`);
      expect(logout.statusCode).toBe(200);

      const afterLogout = await prisma.user.findUnique({
        where: { id: responder.id },
        select: { responderStatus: true },
      });
      expect(afterLogout.responderStatus).toBe('AVAILABLE');
    });
  }
);
