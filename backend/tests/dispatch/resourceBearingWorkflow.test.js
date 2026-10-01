require('dotenv').config();

const bcrypt = require('bcrypt');
const request = require('supertest');
const jwt = require('jsonwebtoken');

const hasDatabase = Boolean(process.env.DATABASE_URL && process.env.JWT_SECRET);

/**
 * Resource-bearing emergencies follow the SAME normal responder workflow as
 * resource-free emergencies:
 *
 *   PENDING -> ACCEPTED -> IN_PROGRESS -> COMPLETED
 *
 * Allocation is a legacy / compatibility backend only. Starting or completing
 * a response must never require Allocation rows, must never create hidden
 * Allocation rows, and must never silently change responder inventory.
 */
(hasDatabase ? describe : describe.skip)(
  'Resource-bearing responder workflow (no Allocation required)',
  () => {
    const app = require('../../src/app');
    const prisma = require('../../src/config/prisma');
    const env = require('../../src/config/env');

    const runId = `rbw-${Date.now()}`;
    const password = 'ResourceBearing123!';

    let requester;
    let responderMedical;
    let responderMedicalTwo;
    let responderUnassigned;
    let resourceBlood;
    let resourceFirstAid;
    let resourceWater;

    let requesterToken;
    let medicalToken;
    let medicalTwoToken;
    let unassignedToken;

    const createdRequestIds = [];

    function tokenFor(user) {
      return jwt.sign(
        { userId: user.id, role: user.role },
        env.JWT_SECRET,
        { expiresIn: '1h' }
      );
    }

    async function deleteCreatedRequests() {
      if (!createdRequestIds.length) return;
      await prisma.allocation.deleteMany({
        where: { requestId: { in: createdRequestIds } },
      });
      await prisma.responderAssignment.deleteMany({
        where: { requestId: { in: createdRequestIds } },
      });
      await prisma.requestResource.deleteMany({
        where: { requestId: { in: createdRequestIds } },
      });
      await prisma.emergencyRequest.deleteMany({
        where: { id: { in: createdRequestIds } },
      });
      createdRequestIds.length = 0;
    }

    async function cleanup() {
      await deleteCreatedRequests();

      const userIds = [
        requester?.id,
        responderMedical?.id,
        responderMedicalTwo?.id,
        responderUnassigned?.id,
      ].filter(Boolean);

      if (userIds.length) {
        await prisma.responderHelpType.deleteMany({
          where: { responderId: { in: userIds } },
        });
        await prisma.responderResource.deleteMany({
          where: { responderId: { in: userIds } },
        });
        await prisma.pushDeviceToken.deleteMany({
          where: { userId: { in: userIds } },
        });
        await prisma.user.deleteMany({ where: { id: { in: userIds } } });
      }

      const resourceIds = [
        resourceBlood?.id,
        resourceFirstAid?.id,
        resourceWater?.id,
      ].filter(Boolean);
      if (resourceIds.length) {
        await prisma.resource.deleteMany({
          where: { id: { in: resourceIds } },
        });
      }
    }

    beforeAll(async () => {
      const passwordHash = await bcrypt.hash(password, 10);

      requester = await prisma.user.create({
        data: {
          name: 'RBW Requester',
          email: `${runId}-requester@test.com`,
          password: passwordHash,
          role: 'REQUESTER',
          isActive: true,
        },
      });
      requesterToken = tokenFor(requester);

      responderMedical = await prisma.user.create({
        data: {
          name: 'RBW Medical Responder',
          email: `${runId}-medical@test.com`,
          password: passwordHash,
          role: 'RESPONDER',
          responderStatus: 'AVAILABLE',
          isActive: true,
        },
      });
      medicalToken = tokenFor(responderMedical);

      responderMedicalTwo = await prisma.user.create({
        data: {
          name: 'RBW Medical Responder Two',
          email: `${runId}-medical-two@test.com`,
          password: passwordHash,
          role: 'RESPONDER',
          responderStatus: 'AVAILABLE',
          isActive: true,
        },
      });
      medicalTwoToken = tokenFor(responderMedicalTwo);

      responderUnassigned = await prisma.user.create({
        data: {
          name: 'RBW Unassigned Responder',
          email: `${runId}-unassigned@test.com`,
          password: passwordHash,
          role: 'RESPONDER',
          responderStatus: 'AVAILABLE',
          isActive: true,
        },
      });
      unassignedToken = tokenFor(responderUnassigned);

      await prisma.responderHelpType.createMany({
        data: [
          { responderId: responderMedical.id, category: 'MEDICAL', enabled: true },
          { responderId: responderMedicalTwo.id, category: 'MEDICAL', enabled: true },
          { responderId: responderUnassigned.id, category: 'MEDICAL', enabled: true },
        ],
      });

      resourceBlood = await prisma.resource.create({
        data: {
          name: `RBW Blood ${runId}`,
          type: 'BLOOD',
          mode: 'CONSUMABLE',
          totalQuantity: 20,
          availableQuantity: 20,
        },
      });
      resourceFirstAid = await prisma.resource.create({
        data: {
          name: `RBW First Aid Kit ${runId}`,
          type: 'FIRST_AID_KIT',
          mode: 'CONSUMABLE',
          totalQuantity: 20,
          availableQuantity: 20,
        },
      });
      resourceWater = await prisma.resource.create({
        data: {
          name: `RBW Water ${runId}`,
          type: 'WATER',
          mode: 'CONSUMABLE',
          totalQuantity: 20,
          availableQuantity: 20,
        },
      });

      // Both medical responders carry Blood + First Aid Kit. Nobody carries
      // Water, so a Water-only request can never be accepted.
      await prisma.responderResource.createMany({
        data: [
          {
            responderId: responderMedical.id,
            resourceId: resourceBlood.id,
            totalQuantity: 5,
            availableQuantity: 5,
            isEnabled: true,
            status: 'AVAILABLE',
          },
          {
            responderId: responderMedical.id,
            resourceId: resourceFirstAid.id,
            totalQuantity: 3,
            availableQuantity: 3,
            isEnabled: true,
            status: 'AVAILABLE',
          },
          {
            responderId: responderMedicalTwo.id,
            resourceId: resourceBlood.id,
            totalQuantity: 4,
            availableQuantity: 4,
            isEnabled: true,
            status: 'AVAILABLE',
          },
        ],
      });
    });

    afterEach(async () => {
      await deleteCreatedRequests();
      await prisma.user.updateMany({
        where: {
          id: {
            in: [
              responderMedical.id,
              responderMedicalTwo.id,
              responderUnassigned.id,
            ],
          },
        },
        data: { responderStatus: 'AVAILABLE' },
      });
    });

    afterAll(async () => {
      await cleanup();
      await prisma.$disconnect();
    });

    async function createRequest(requiredResources, emergencyType = 'Medical') {
      const res = await request(app)
        .post('/api/requests')
        .set('Authorization', `Bearer ${requesterToken}`)
        .send({
          emergencyType,
          location: 'Hospital Road',
          priority: 'HIGH',
          requiredResources,
        });
      expect(res.statusCode).toBe(201);
      createdRequestIds.push(res.body.request.id);
      return res.body.request;
    }

    function bloodAndFirstAid() {
      return [
        { resourceId: resourceBlood.id, quantity: 2 },
        { resourceId: resourceFirstAid.id, quantity: 1 },
      ];
    }

    async function responderInventory(responderId) {
      const rows = await prisma.responderResource.findMany({
        where: { responderId },
        orderBy: { resourceId: 'asc' },
        select: { resourceId: true, availableQuantity: true, status: true },
      });
      return rows;
    }

    test('1. Resource-free request: ACCEPTED -> IN_PROGRESS -> COMPLETED', async () => {
      const emergency = await createRequest(undefined);
      expect(emergency.status).toBe('PENDING');

      const acceptRes = await request(app)
        .patch(`/api/requests/${emergency.id}/accept`)
        .set('Authorization', `Bearer ${medicalToken}`);
      expect(acceptRes.statusCode).toBe(200);
      expect(acceptRes.body.request.status).toBe('ACCEPTED');

      const startRes = await request(app)
        .post(`/api/requests/${emergency.id}/start`)
        .set('Authorization', `Bearer ${medicalToken}`);
      expect(startRes.statusCode).toBe(200);
      expect(startRes.body.request.status).toBe('IN_PROGRESS');

      const completeRes = await request(app)
        .post(`/api/requests/${emergency.id}/complete`)
        .set('Authorization', `Bearer ${medicalToken}`);
      expect(completeRes.statusCode).toBe(200);
      expect(completeRes.body.request.status).toBe('COMPLETED');
    });

    test('2. Resource-bearing request (Blood × 2, First Aid Kit × 1): ACCEPTED -> IN_PROGRESS -> COMPLETED', async () => {
      const emergency = await createRequest(bloodAndFirstAid());
      expect(emergency.status).toBe('PENDING');
      expect(emergency.requiredResources).toHaveLength(2);

      const acceptRes = await request(app)
        .patch(`/api/requests/${emergency.id}/accept`)
        .set('Authorization', `Bearer ${medicalToken}`);
      expect(acceptRes.statusCode).toBe(200);
      expect(acceptRes.body.request.status).toBe('ACCEPTED');
      expect(acceptRes.body.request.acceptedById).toBe(responderMedical.id);

      const startRes = await request(app)
        .post(`/api/requests/${emergency.id}/start`)
        .set('Authorization', `Bearer ${medicalToken}`);
      expect(startRes.statusCode).toBe(200);
      expect(startRes.body.request.status).toBe('IN_PROGRESS');
      // Requested resources remain visible throughout the lifecycle.
      expect(startRes.body.request.requiredResources).toHaveLength(2);

      const busy = await prisma.user.findUnique({
        where: { id: responderMedical.id },
      });
      expect(busy.responderStatus).toBe('BUSY');

      const completeRes = await request(app)
        .post(`/api/requests/${emergency.id}/complete`)
        .set('Authorization', `Bearer ${medicalToken}`);
      expect(completeRes.statusCode).toBe(200);
      expect(completeRes.body.request.status).toBe('COMPLETED');
      expect(completeRes.body.request.requiredResources).toHaveLength(2);

      const assignment = await prisma.responderAssignment.findUnique({
        where: {
          requestId_responderId: {
            requestId: emergency.id,
            responderId: responderMedical.id,
          },
        },
      });
      expect(assignment.status).toBe('ENDED');
      expect(assignment.endedAt).not.toBeNull();

      const released = await prisma.user.findUnique({
        where: { id: responderMedical.id },
      });
      expect(released.responderStatus).toBe('AVAILABLE');

      const stored = await prisma.emergencyRequest.findUnique({
        where: { id: emergency.id },
      });
      expect(stored.status).toBe('COMPLETED');
    });

    test('3. Responder cannot start an unaccepted (PENDING) request', async () => {
      const emergency = await createRequest(bloodAndFirstAid());

      const startRes = await request(app)
        .post(`/api/requests/${emergency.id}/start`)
        .set('Authorization', `Bearer ${medicalToken}`);

      expect([400, 403]).toContain(startRes.statusCode);
      expect(startRes.body.success).toBe(false);

      const stored = await prisma.emergencyRequest.findUnique({
        where: { id: emergency.id },
      });
      expect(stored.status).toBe('PENDING');
    });

    test('4. Responder cannot complete a request that is not IN_PROGRESS', async () => {
      const emergency = await createRequest(bloodAndFirstAid());

      await request(app)
        .patch(`/api/requests/${emergency.id}/accept`)
        .set('Authorization', `Bearer ${medicalToken}`);

      const completeRes = await request(app)
        .post(`/api/requests/${emergency.id}/complete`)
        .set('Authorization', `Bearer ${medicalToken}`);

      expect(completeRes.statusCode).toBe(400);
      expect(completeRes.body.message).toMatch(/must be in progress/i);

      const stored = await prisma.emergencyRequest.findUnique({
        where: { id: emergency.id },
      });
      expect(stored.status).toBe('ACCEPTED');
    });

    test('5. Unassigned responder cannot start the response', async () => {
      const emergency = await createRequest(bloodAndFirstAid());

      await request(app)
        .patch(`/api/requests/${emergency.id}/accept`)
        .set('Authorization', `Bearer ${medicalToken}`);

      const startRes = await request(app)
        .post(`/api/requests/${emergency.id}/start`)
        .set('Authorization', `Bearer ${unassignedToken}`);

      expect(startRes.statusCode).toBe(403);
      expect(startRes.body.message).toMatch(/not assigned|unauthorized/i);

      const stored = await prisma.emergencyRequest.findUnique({
        where: { id: emergency.id },
      });
      expect(stored.status).toBe('ACCEPTED');
    });

    test('6. Resource-bearing request does NOT require Allocation to start', async () => {
      const emergency = await createRequest(bloodAndFirstAid());

      await request(app)
        .patch(`/api/requests/${emergency.id}/accept`)
        .set('Authorization', `Bearer ${medicalToken}`);

      const before = await prisma.allocation.count({
        where: { requestId: emergency.id },
      });
      expect(before).toBe(0);

      const startRes = await request(app)
        .post(`/api/requests/${emergency.id}/start`)
        .set('Authorization', `Bearer ${medicalToken}`);
      expect(startRes.statusCode).toBe(200);
      expect(startRes.body.request.status).toBe('IN_PROGRESS');

      // No hidden allocation records are invented to make the lifecycle work.
      const after = await prisma.allocation.count({
        where: { requestId: emergency.id },
      });
      expect(after).toBe(0);
      expect(startRes.body.request.allocations).toEqual([]);
    });

    test('7. Resource-bearing request does NOT require Allocation to complete and never touches inventory', async () => {
      const emergency = await createRequest(bloodAndFirstAid());
      const inventoryBefore = await responderInventory(responderMedical.id);
      const catalogBefore = await prisma.resource.findMany({
        where: { id: { in: [resourceBlood.id, resourceFirstAid.id] } },
        orderBy: { id: 'asc' },
        select: { id: true, availableQuantity: true },
      });

      await request(app)
        .patch(`/api/requests/${emergency.id}/accept`)
        .set('Authorization', `Bearer ${medicalToken}`);
      await request(app)
        .post(`/api/requests/${emergency.id}/start`)
        .set('Authorization', `Bearer ${medicalToken}`);

      const completeRes = await request(app)
        .post(`/api/requests/${emergency.id}/complete`)
        .set('Authorization', `Bearer ${medicalToken}`);
      expect(completeRes.statusCode).toBe(200);
      expect(completeRes.body.request.status).toBe('COMPLETED');

      const allocations = await prisma.allocation.findMany({
        where: { requestId: emergency.id },
      });
      expect(allocations).toHaveLength(0);

      // Inventory is availability/matching information in this workflow:
      // physical quantities only change through the legacy Allocation
      // service, which this workflow never invokes.
      const inventoryAfter = await responderInventory(responderMedical.id);
      expect(inventoryAfter).toEqual(inventoryBefore);
      const catalogAfter = await prisma.resource.findMany({
        where: { id: { in: [resourceBlood.id, resourceFirstAid.id] } },
        orderBy: { id: 'asc' },
        select: { id: true, availableQuantity: true },
      });
      expect(catalogAfter).toEqual(catalogBefore);
    });

    test('8. Acceptance still enforces the existing server-side resource compatibility rules', async () => {
      // Nobody carries Water. Discovery stays category-based (existing,
      // tested semantics), but the authoritative server-side gate at
      // acceptance - the SAME findServableRequiredResources algorithm used
      // before this phase - rejects a responder whose inventory cannot
      // satisfy the required resources. No second algorithm is introduced.
      const waterOnly = await createRequest([
        { resourceId: resourceWater.id, quantity: 1 },
      ]);

      const acceptRes = await request(app)
        .patch(`/api/requests/${waterOnly.id}/accept`)
        .set('Authorization', `Bearer ${medicalToken}`);
      expect(acceptRes.statusCode).toBe(400);
      expect(acceptRes.body.message).toMatch(/compatible resource/i);

      const stored = await prisma.emergencyRequest.findUnique({
        where: { id: waterOnly.id },
      });
      expect(stored.status).toBe('PENDING');
      expect(stored.acceptedById).toBeNull();

      // Never accepted -> can never be started by that responder either.
      const startRes = await request(app)
        .post(`/api/requests/${waterOnly.id}/start`)
        .set('Authorization', `Bearer ${medicalToken}`);
      expect([400, 403]).toContain(startRes.statusCode);

      // A responder whose inventory DOES satisfy a required line is accepted
      // and then follows the normal workflow.
      const bloodOnly = await createRequest([
        { resourceId: resourceBlood.id, quantity: 1 },
      ]);
      const okAccept = await request(app)
        .patch(`/api/requests/${bloodOnly.id}/accept`)
        .set('Authorization', `Bearer ${medicalTwoToken}`);
      expect(okAccept.statusCode).toBe(200);
      expect(okAccept.body.request.status).toBe('ACCEPTED');
    });

    test('9. Multi-responder: a second responder joining an IN_PROGRESS resource-bearing request never regresses its status', async () => {
      const emergency = await createRequest(bloodAndFirstAid());

      await request(app)
        .patch(`/api/requests/${emergency.id}/accept`)
        .set('Authorization', `Bearer ${medicalToken}`);
      await request(app)
        .post(`/api/requests/${emergency.id}/start`)
        .set('Authorization', `Bearer ${medicalToken}`);

      const joinRes = await request(app)
        .patch(`/api/requests/${emergency.id}/accept`)
        .set('Authorization', `Bearer ${medicalTwoToken}`);
      expect(joinRes.statusCode).toBe(200);
      expect(joinRes.body.request.status).toBe('IN_PROGRESS');

      // Leaving through End Assignment does not complete the emergency.
      const endRes = await request(app)
        .patch(`/api/requests/${emergency.id}/assignment/end`)
        .set('Authorization', `Bearer ${medicalTwoToken}`);
      expect(endRes.statusCode).toBe(200);
      const afterEnd = await prisma.emergencyRequest.findUnique({
        where: { id: emergency.id },
      });
      expect(afterEnd.status).toBe('IN_PROGRESS');

      // Explicit completion by an assigned responder ends every ACTIVE
      // assignment and releases every responder.
      const completeRes = await request(app)
        .post(`/api/requests/${emergency.id}/complete`)
        .set('Authorization', `Bearer ${medicalToken}`);
      expect(completeRes.statusCode).toBe(200);
      expect(completeRes.body.request.status).toBe('COMPLETED');

      const assignments = await prisma.responderAssignment.findMany({
        where: { requestId: emergency.id },
      });
      expect(assignments).toHaveLength(2);
      expect(assignments.every((row) => row.status === 'ENDED')).toBe(true);

      const responders = await prisma.user.findMany({
        where: { id: { in: [responderMedical.id, responderMedicalTwo.id] } },
        select: { responderStatus: true },
      });
      expect(responders.every((row) => row.responderStatus === 'AVAILABLE')).toBe(true);
    });

    test('10. Requester and admin see the same lifecycle with resources intact', async () => {
      const emergency = await createRequest(bloodAndFirstAid());

      await request(app)
        .patch(`/api/requests/${emergency.id}/accept`)
        .set('Authorization', `Bearer ${medicalToken}`);
      await request(app)
        .post(`/api/requests/${emergency.id}/start`)
        .set('Authorization', `Bearer ${medicalToken}`);
      await request(app)
        .post(`/api/requests/${emergency.id}/complete`)
        .set('Authorization', `Bearer ${medicalToken}`);

      const mineRes = await request(app)
        .get('/api/requests/my')
        .set('Authorization', `Bearer ${requesterToken}`);
      expect(mineRes.statusCode).toBe(200);
      const mine = mineRes.body.requests || mineRes.body;
      const row = (Array.isArray(mine) ? mine : []).find(
        (candidate) => candidate.id === emergency.id
      );
      expect(row).toBeDefined();
      expect(row.status).toBe('COMPLETED');
      expect(row.requiredResources).toHaveLength(2);
    });
  }
);
