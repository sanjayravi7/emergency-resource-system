require('dotenv').config();

const bcrypt = require('bcrypt');
const request = require('supertest');
const jwt = require('jsonwebtoken');

const hasDatabase = Boolean(process.env.DATABASE_URL && process.env.JWT_SECRET);

(hasDatabase ? describe : describe.skip)(
  'Resource-free responder emergency workflow and help-type authorization',
  () => {
    const app = require('../../src/app');
    const prisma = require('../../src/config/prisma');
    const env = require('../../src/config/env');

    const runId = `rfw-${Date.now()}`;
    const password = 'ResourceFree123!';

    let requester;
    let responderFire;
    let responderMedical;
    let responderOther;
    let resourceAmbulance;

    let requesterToken;
    let fireToken;
    let medicalToken;
    let otherToken;

    const createdRequestIds = [];

    function tokenFor(user) {
      return jwt.sign(
        { userId: user.id, role: user.role },
        env.JWT_SECRET,
        { expiresIn: '1h' }
      );
    }

    async function cleanup() {
      const userIds = [
        requester?.id,
        responderFire?.id,
        responderMedical?.id,
        responderOther?.id,
      ].filter(Boolean);

      if (createdRequestIds.length) {
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
      }

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
        await prisma.user.deleteMany({
          where: { id: { in: userIds } },
        });
      }

      if (resourceAmbulance) {
        await prisma.resource.deleteMany({
          where: { id: resourceAmbulance.id },
        });
      }
    }

    beforeAll(async () => {
      await cleanup();
      const passwordHash = await bcrypt.hash(password, 10);

      requester = await prisma.user.create({
        data: {
          name: 'RFW Requester',
          email: `${runId}-requester@test.com`,
          password: passwordHash,
          role: 'REQUESTER',
          isActive: true,
        },
      });
      requesterToken = tokenFor(requester);

      responderFire = await prisma.user.create({
        data: {
          name: 'RFW Fire Responder',
          email: `${runId}-fire@test.com`,
          password: passwordHash,
          role: 'RESPONDER',
          responderStatus: 'AVAILABLE',
          isActive: true,
        },
      });
      fireToken = tokenFor(responderFire);

      responderMedical = await prisma.user.create({
        data: {
          name: 'RFW Medical Responder',
          email: `${runId}-medical@test.com`,
          password: passwordHash,
          role: 'RESPONDER',
          responderStatus: 'AVAILABLE',
          isActive: true,
        },
      });
      medicalToken = tokenFor(responderMedical);

      responderOther = await prisma.user.create({
        data: {
          name: 'RFW Other Responder',
          email: `${runId}-other@test.com`,
          password: passwordHash,
          role: 'RESPONDER',
          responderStatus: 'AVAILABLE',
          isActive: true,
        },
      });
      otherToken = tokenFor(responderOther);

      // Set up help types: Fire -> FIRE, Medical -> MEDICAL
      await prisma.responderHelpType.createMany({
        data: [
          { responderId: responderFire.id, category: 'FIRE', enabled: true },
          { responderId: responderMedical.id, category: 'MEDICAL', enabled: true },
        ],
      });

      // Create a consumable resource for resource-bearing test
      resourceAmbulance = await prisma.resource.create({
        data: {
          name: `RFW Ambulance ${runId}`,
          type: 'AMBULANCE',
          mode: 'CONSUMABLE',
          totalQuantity: 10,
          availableQuantity: 10,
        },
      });

      await prisma.responderResource.create({
        data: {
          responderId: responderMedical.id,
          resourceId: resourceAmbulance.id,
          totalQuantity: 5,
          availableQuantity: 5,
          isEnabled: true,
          status: 'AVAILABLE',
        },
      });
    });

    afterEach(async () => {
      if (createdRequestIds.length) {
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

      await prisma.user.updateMany({
        where: {
          id: {
            in: [
              responderFire.id,
              responderMedical.id,
              responderOther.id,
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

    async function createResourceFreeRequest(emergencyType = 'Fire') {
      const res = await request(app)
        .post('/api/requests')
        .set('Authorization', `Bearer ${requesterToken}`)
        .send({
          emergencyType,
          location: 'Test Location',
          priority: 'HIGH',
        });
      expect(res.statusCode).toBe(201);
      createdRequestIds.push(res.body.request.id);
      return res.body.request;
    }

    test('1. Responder with FIRE help type can accept resource-free FIRE request', async () => {
      const emergency = await createResourceFreeRequest('Fire');

      const acceptRes = await request(app)
        .patch(`/api/requests/${emergency.id}/accept`)
        .set('Authorization', `Bearer ${fireToken}`);

      expect(acceptRes.statusCode).toBe(200);
      expect(acceptRes.body.request.status).toBe('ACCEPTED');
      expect(acceptRes.body.request.acceptedById).toBe(responderFire.id);

      const responder = await prisma.user.findUnique({
        where: { id: responderFire.id },
      });
      expect(responder.responderStatus).toBe('BUSY');
    });

    test('2. Responder with FIRE help type cannot accept MEDICAL request', async () => {
      const emergency = await createResourceFreeRequest('Medical');

      const acceptRes = await request(app)
        .patch(`/api/requests/${emergency.id}/accept`)
        .set('Authorization', `Bearer ${fireToken}`);

      expect(acceptRes.statusCode).toBe(400);
      expect(acceptRes.body.message).toMatch(/help type/i);
    });

    test('3. Resource-free accepted request can transition ACCEPTED → IN_PROGRESS through the responder endpoint', async () => {
      const emergency = await createResourceFreeRequest('Fire');

      await request(app)
        .patch(`/api/requests/${emergency.id}/accept`)
        .set('Authorization', `Bearer ${fireToken}`);

      const startRes = await request(app)
        .post(`/api/requests/${emergency.id}/start`)
        .set('Authorization', `Bearer ${fireToken}`);

      expect(startRes.statusCode).toBe(200);
      expect(startRes.body.request.status).toBe('IN_PROGRESS');

      const responder = await prisma.user.findUnique({
        where: { id: responderFire.id },
      });
      expect(responder.responderStatus).toBe('BUSY');
    });

    test('4. Only the assigned responder can start the response', async () => {
      const emergency = await createResourceFreeRequest('Fire');

      await request(app)
        .patch(`/api/requests/${emergency.id}/accept`)
        .set('Authorization', `Bearer ${fireToken}`);

      // Medical responder is not assigned to this fire emergency
      const startRes = await request(app)
        .post(`/api/requests/${emergency.id}/start`)
        .set('Authorization', `Bearer ${medicalToken}`);

      expect([400, 403]).toContain(startRes.statusCode);
      expect(startRes.body.message).toMatch(/not assigned|unauthorized/i);
    });

    test('5. Resource-free IN_PROGRESS request can transition to COMPLETED', async () => {
      const emergency = await createResourceFreeRequest('Fire');

      await request(app)
        .patch(`/api/requests/${emergency.id}/accept`)
        .set('Authorization', `Bearer ${fireToken}`);

      await request(app)
        .post(`/api/requests/${emergency.id}/start`)
        .set('Authorization', `Bearer ${fireToken}`);

      const completeRes = await request(app)
        .post(`/api/requests/${emergency.id}/complete`)
        .set('Authorization', `Bearer ${fireToken}`);

      expect(completeRes.statusCode).toBe(200);
      expect(completeRes.body.request.status).toBe('COMPLETED');
    });

    test('6. Completing resource-free request ends active assignment', async () => {
      const emergency = await createResourceFreeRequest('Fire');

      await request(app)
        .patch(`/api/requests/${emergency.id}/accept`)
        .set('Authorization', `Bearer ${fireToken}`);

      await request(app)
        .post(`/api/requests/${emergency.id}/start`)
        .set('Authorization', `Bearer ${fireToken}`);

      await request(app)
        .post(`/api/requests/${emergency.id}/complete`)
        .set('Authorization', `Bearer ${fireToken}`);

      const assignment = await prisma.responderAssignment.findUnique({
        where: {
          requestId_responderId: {
            requestId: emergency.id,
            responderId: responderFire.id,
          },
        },
      });

      expect(assignment.status).toBe('ENDED');
      expect(assignment.endedAt).not.toBeNull();
    });

    test('7. Completing resource-free request makes responder AVAILABLE', async () => {
      const emergency = await createResourceFreeRequest('Fire');

      await request(app)
        .patch(`/api/requests/${emergency.id}/accept`)
        .set('Authorization', `Bearer ${fireToken}`);

      await request(app)
        .post(`/api/requests/${emergency.id}/start`)
        .set('Authorization', `Bearer ${fireToken}`);

      await request(app)
        .post(`/api/requests/${emergency.id}/complete`)
        .set('Authorization', `Bearer ${fireToken}`);

      const responder = await prisma.user.findUnique({
        where: { id: responderFire.id },
      });
      expect(responder.responderStatus).toBe('AVAILABLE');
    });

    test('8. Resource-free completion does not create Allocation rows', async () => {
      const emergency = await createResourceFreeRequest('Fire');

      await request(app)
        .patch(`/api/requests/${emergency.id}/accept`)
        .set('Authorization', `Bearer ${fireToken}`);

      const allocateRes = await request(app)
        .post('/api/allocations')
        .set('Authorization', `Bearer ${fireToken}`)
        .send({
          requestId: emergency.id,
          resourceId: 999999,
          responderResourceId: 999999,
          quantity: 1,
        });
      expect(allocateRes.statusCode).toBe(400);
      expect(allocateRes.body.message).toMatch(/does not require physical/i);

      await request(app)
        .post(`/api/requests/${emergency.id}/start`)
        .set('Authorization', `Bearer ${fireToken}`);

      await request(app)
        .post(`/api/requests/${emergency.id}/complete`)
        .set('Authorization', `Bearer ${fireToken}`);

      const allocations = await prisma.allocation.findMany({
        where: { requestId: emergency.id },
      });
      expect(allocations).toHaveLength(0);
    });

    test('9. Resource-bearing allocation workflow remains unchanged', async () => {
      const createRes = await request(app)
        .post('/api/requests')
        .set('Authorization', `Bearer ${requesterToken}`)
        .send({
          emergencyType: 'Medical',
          location: 'Hospital Road',
          priority: 'HIGH',
          requiredResources: [{ resourceId: resourceAmbulance.id, quantity: 2 }],
        });

      expect(createRes.statusCode).toBe(201);
      const emergencyId = createRes.body.request.id;
      createdRequestIds.push(emergencyId);

      // Medical responder accepts
      const acceptRes = await request(app)
        .patch(`/api/requests/${emergencyId}/accept`)
        .set('Authorization', `Bearer ${medicalToken}`);
      expect(acceptRes.statusCode).toBe(200);

      // Medical responder allocates inventory
      const responderResource = await prisma.responderResource.findUnique({
        where: {
          responderId_resourceId: {
            responderId: responderMedical.id,
            resourceId: resourceAmbulance.id,
          },
        },
      });

      const allocRes = await request(app)
        .post('/api/allocations')
        .set('Authorization', `Bearer ${medicalToken}`)
        .send({
          requestId: emergencyId,
          resourceId: resourceAmbulance.id,
          responderResourceId: responderResource.id,
          quantity: 2,
        });
      expect(allocRes.statusCode).toBe(201);
      expect(allocRes.body.allocation.status).toBe('RESERVED');

      // Dispatch allocation
      const dispatchRes = await request(app)
        .patch(`/api/allocations/${allocRes.body.allocation.id}/status`)
        .set('Authorization', `Bearer ${medicalToken}`)
        .send({ status: 'DISPATCHED' });
      expect(dispatchRes.statusCode).toBe(200);

      // Confirm received (delivery)
      const deliverRes = await request(app)
        .patch(`/api/allocations/${allocRes.body.allocation.id}/received`)
        .set('Authorization', `Bearer ${requesterToken}`);
      expect(deliverRes.statusCode).toBe(200);

      const requestAfterDelivery = await prisma.emergencyRequest.findUnique({
        where: { id: emergencyId },
      });
      expect(requestAfterDelivery.status).toBe('COMPLETED');
    });

    test('10. Resource-bearing request follows the same ACCEPTED → IN_PROGRESS → COMPLETED workflow without Allocation', async () => {
      const createRes = await request(app)
        .post('/api/requests')
        .set('Authorization', `Bearer ${requesterToken}`)
        .send({
          emergencyType: 'Medical',
          location: 'Hospital Road',
          priority: 'HIGH',
          requiredResources: [{ resourceId: resourceAmbulance.id, quantity: 1 }],
        });

      const emergencyId = createRes.body.request.id;
      createdRequestIds.push(emergencyId);

      await request(app)
        .patch(`/api/requests/${emergencyId}/accept`)
        .set('Authorization', `Bearer ${medicalToken}`);

      const startRes = await request(app)
        .post(`/api/requests/${emergencyId}/start`)
        .set('Authorization', `Bearer ${medicalToken}`);
      expect(startRes.statusCode).toBe(200);
      expect(startRes.body.request.status).toBe('IN_PROGRESS');

      const completeRes = await request(app)
        .post(`/api/requests/${emergencyId}/complete`)
        .set('Authorization', `Bearer ${medicalToken}`);
      expect(completeRes.statusCode).toBe(200);
      expect(completeRes.body.request.status).toBe('COMPLETED');

      const allocations = await prisma.allocation.findMany({
        where: { requestId: emergencyId },
      });
      expect(allocations).toHaveLength(0);
    });

    test('11. Unauthorized responder cannot start/complete another responder\'s request', async () => {
      const emergency = await createResourceFreeRequest('Fire');

      await request(app)
        .patch(`/api/requests/${emergency.id}/accept`)
        .set('Authorization', `Bearer ${fireToken}`);

      const unauthStart = await request(app)
        .post(`/api/requests/${emergency.id}/start`)
        .set('Authorization', `Bearer ${otherToken}`);
      expect([400, 403]).toContain(unauthStart.statusCode);

      await request(app)
        .post(`/api/requests/${emergency.id}/start`)
        .set('Authorization', `Bearer ${fireToken}`);

      const unauthComplete = await request(app)
        .post(`/api/requests/${emergency.id}/complete`)
        .set('Authorization', `Bearer ${otherToken}`);
      expect([400, 403]).toContain(unauthComplete.statusCode);
    });

    test('12. Terminal request cannot be started/completed', async () => {
      const emergency = await createResourceFreeRequest('Fire');

      await request(app)
        .patch(`/api/requests/${emergency.id}/accept`)
        .set('Authorization', `Bearer ${fireToken}`);

      await request(app)
        .post(`/api/requests/${emergency.id}/start`)
        .set('Authorization', `Bearer ${fireToken}`);

      await request(app)
        .post(`/api/requests/${emergency.id}/complete`)
        .set('Authorization', `Bearer ${fireToken}`);

      const repeatStart = await request(app)
        .post(`/api/requests/${emergency.id}/start`)
        .set('Authorization', `Bearer ${fireToken}`);
      expect([400, 403]).toContain(repeatStart.statusCode);

      const repeatComplete = await request(app)
        .post(`/api/requests/${emergency.id}/complete`)
        .set('Authorization', `Bearer ${fireToken}`);
      expect([400, 403]).toContain(repeatComplete.statusCode);

      const cancelledEmergency = await createResourceFreeRequest('Fire');
      await request(app)
        .patch(`/api/requests/${cancelledEmergency.id}/accept`)
        .set('Authorization', `Bearer ${fireToken}`);
      await request(app)
        .patch(`/api/requests/${cancelledEmergency.id}/cancel`)
        .set('Authorization', `Bearer ${requesterToken}`);

      const cancelledStart = await request(app)
        .post(`/api/requests/${cancelledEmergency.id}/start`)
        .set('Authorization', `Bearer ${fireToken}`);
      expect(cancelledStart.statusCode).toBe(400);

      const cancelledComplete = await request(app)
        .post(`/api/requests/${cancelledEmergency.id}/complete`)
        .set('Authorization', `Bearer ${fireToken}`);
      expect(cancelledComplete.statusCode).toBe(400);
    });
  }
);
