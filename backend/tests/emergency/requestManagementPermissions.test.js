require('dotenv').config({ quiet: true });

const hasDatabase = Boolean(process.env.DATABASE_URL && process.env.JWT_SECRET);

if (!hasDatabase) {
  describe.skip('ADMIN and REQUESTER request-management endpoints', () => {
    test('requires DATABASE_URL and JWT_SECRET', () => {});
  });
} else {
  describe('ADMIN and REQUESTER request-management endpoints', () => {
    const request = require('supertest');
    const jwt = require('jsonwebtoken');
    const app = require('../../src/app');
    const prisma = require('../../src/config/prisma');
    const env = require('../../src/config/env');

    const runId = `request-management-${Date.now()}`;
    const emails = {
      admin: `${runId}-admin@test.com`,
      requester: `${runId}-requester@test.com`,
      other: `${runId}-other@test.com`,
      compatible: `${runId}-compatible@test.com`,
      incompatible: `${runId}-incompatible@test.com`,
    };

    let admin;
    let requesterUser;
    let otherRequester;
    let compatibleResponder;
    let incompatibleResponder;
    let tokens;

    const tokenFor = (user) =>
      jwt.sign({ userId: user.id, role: user.role }, env.JWT_SECRET, {
        expiresIn: '1h',
      });

    const auth = (token) => ({ Authorization: `Bearer ${token}` });

    const payload = (overrides = {}) => ({
      emergencyType: 'Fire',
      description: 'Smoke reported on the second floor',
      location: 'Operations Test Building',
      latitude: 9.9911,
      longitude: 76.6622,
      priority: 'HIGH',
      requiredResources: [],
      ...overrides,
    });

    async function cleanupRequests() {
      const userIds = [admin?.id, requesterUser?.id, otherRequester?.id].filter(
        Boolean
      );
      if (!userIds.length) return;
      await prisma.emergencyRequest.deleteMany({
        where: { requesterId: { in: userIds } },
      });
      const responderIds = [
        compatibleResponder?.id,
        incompatibleResponder?.id,
      ].filter(Boolean);
      if (responderIds.length) {
        await prisma.user.updateMany({
          where: { id: { in: responderIds } },
          data: { responderStatus: 'AVAILABLE' },
        });
      }
    }

    beforeAll(async () => {
      await prisma.user.deleteMany({
        where: { email: { in: Object.values(emails) } },
      });

      [admin, requesterUser, otherRequester, compatibleResponder,
        incompatibleResponder] = await Promise.all([
        prisma.user.create({
          data: {
            name: 'Request Management Admin',
            email: emails.admin,
            password: 'test-password',
            role: 'ADMIN',
            isActive: true,
          },
        }),
        prisma.user.create({
          data: {
            name: 'Request Management Requester',
            email: emails.requester,
            password: 'test-password',
            role: 'REQUESTER',
            isActive: true,
          },
        }),
        prisma.user.create({
          data: {
            name: 'Other Requester',
            email: emails.other,
            password: 'test-password',
            role: 'REQUESTER',
            isActive: true,
          },
        }),
        prisma.user.create({
          data: {
            name: 'Compatible Fire Responder',
            email: emails.compatible,
            password: 'test-password',
            role: 'RESPONDER',
            responderStatus: 'AVAILABLE',
            isActive: true,
          },
        }),
        prisma.user.create({
          data: {
            name: 'Incompatible Medical Responder',
            email: emails.incompatible,
            password: 'test-password',
            role: 'RESPONDER',
            responderStatus: 'AVAILABLE',
            isActive: true,
          },
        }),
      ]);

      await prisma.responderHelpType.createMany({
        data: [
          {
            responderId: compatibleResponder.id,
            category: 'FIRE',
            enabled: true,
          },
          {
            responderId: incompatibleResponder.id,
            category: 'MEDICAL',
            enabled: true,
          },
        ],
      });

      tokens = {
        admin: tokenFor(admin),
        requester: tokenFor(requesterUser),
        other: tokenFor(otherRequester),
      };
    });

    afterEach(cleanupRequests);

    afterAll(async () => {
      await cleanupRequests();
      const responderIds = [compatibleResponder.id, incompatibleResponder.id];
      await prisma.responderHelpType.deleteMany({
        where: { responderId: { in: responderIds } },
      });
      await prisma.user.deleteMany({
        where: { email: { in: Object.values(emails) } },
      });
      await prisma.$disconnect();
    });

    test('ADMIN can create a PENDING emergency', async () => {
      const response = await request(app)
        .post('/api/admin/requests')
        .set(auth(tokens.admin))
        .send(payload());

      expect(response.statusCode).toBe(201);
      expect(response.body.request).toMatchObject({
        requesterId: admin.id,
        status: 'PENDING',
        emergencyType: 'Fire',
      });
    });

    test('ADMIN can assign a compatible responder', async () => {
      const emergency = await prisma.emergencyRequest.create({
        data: {
          requesterId: admin.id,
          emergencyType: 'Fire',
          location: 'Compatibility Test',
          priority: 'HIGH',
        },
      });

      const response = await request(app)
        .patch(
          `/api/admin/requests/${emergency.id}/assign/${compatibleResponder.id}`
        )
        .set(auth(tokens.admin));

      expect(response.statusCode).toBe(200);
      expect(response.body.request.status).toBe('ACCEPTED');
      expect(response.body.request.acceptedById).toBe(compatibleResponder.id);
      expect(response.body.request.assignments).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            responderId: compatibleResponder.id,
            status: 'ACTIVE',
          }),
        ])
      );
    });

    test('ADMIN cannot assign an incompatible responder', async () => {
      const emergency = await prisma.emergencyRequest.create({
        data: {
          requesterId: admin.id,
          emergencyType: 'Fire',
          location: 'Incompatibility Test',
          priority: 'HIGH',
        },
      });

      const response = await request(app)
        .patch(
          `/api/admin/requests/${emergency.id}/assign/${incompatibleResponder.id}`
        )
        .set(auth(tokens.admin));

      expect(response.statusCode).toBe(400);
      expect(response.body.message).toMatch(/compatible help type/i);
      const stored = await prisma.emergencyRequest.findUnique({
        where: { id: emergency.id },
      });
      expect(stored.status).toBe('PENDING');
      expect(stored.acceptedById).toBeNull();
    });

    test('ADMIN can cancel an eligible request without deleting history', async () => {
      const emergency = await prisma.emergencyRequest.create({
        data: {
          requesterId: admin.id,
          emergencyType: 'Flood',
          location: 'Cancellation Test',
          priority: 'MEDIUM',
        },
      });

      const response = await request(app)
        .patch(`/api/admin/requests/${emergency.id}/cancel`)
        .set(auth(tokens.admin));

      expect(response.statusCode).toBe(200);
      expect(response.body.request.status).toBe('CANCELLED');
      await expect(
        prisma.emergencyRequest.findUnique({ where: { id: emergency.id } })
      ).resolves.toMatchObject({ id: emergency.id, status: 'CANCELLED' });
    });

    test('REQUESTER can edit their own PENDING request', async () => {
      const emergency = await prisma.emergencyRequest.create({
        data: {
          requesterId: requesterUser.id,
          emergencyType: 'Medical',
          description: 'Original description',
          location: 'Original place',
          priority: 'MEDIUM',
        },
      });

      const response = await request(app)
        .patch(`/api/requests/${emergency.id}`)
        .set(auth(tokens.requester))
        .send(
          payload({
            emergencyType: 'Accident',
            description: 'Updated description',
            location: 'Updated place',
            priority: 'CRITICAL',
          })
        );

      expect(response.statusCode).toBe(200);
      expect(response.body.request).toMatchObject({
        id: emergency.id,
        emergencyType: 'Accident',
        description: 'Updated description',
        location: 'Updated place',
        priority: 'CRITICAL',
      });
    });

    test("REQUESTER cannot edit another user's request", async () => {
      const emergency = await prisma.emergencyRequest.create({
        data: {
          requesterId: otherRequester.id,
          emergencyType: 'Fire',
          location: 'Other requester place',
          priority: 'HIGH',
        },
      });

      const response = await request(app)
        .patch(`/api/requests/${emergency.id}`)
        .set(auth(tokens.requester))
        .send(payload({ location: 'Unauthorized update' }));

      expect(response.statusCode).toBe(403);
      expect(response.body.message).toMatch(/only edit your own/i);
    });

    test('REQUESTER cannot edit a COMPLETED request', async () => {
      const emergency = await prisma.emergencyRequest.create({
        data: {
          requesterId: requesterUser.id,
          emergencyType: 'Fire',
          location: 'Completed request place',
          priority: 'HIGH',
          status: 'COMPLETED',
        },
      });

      const response = await request(app)
        .patch(`/api/requests/${emergency.id}`)
        .set(auth(tokens.requester))
        .send(payload());

      expect(response.statusCode).toBe(400);
      expect(response.body.message).toMatch(/pending/i);
    });

    test('REQUESTER can cancel their own request without hard deletion', async () => {
      const emergency = await prisma.emergencyRequest.create({
        data: {
          requesterId: requesterUser.id,
          emergencyType: 'Rescue',
          location: 'Requester cancellation place',
          priority: 'HIGH',
        },
      });

      const response = await request(app)
        .delete(`/api/requests/${emergency.id}`)
        .set(auth(tokens.requester));

      expect(response.statusCode).toBe(200);
      expect(response.body.request.status).toBe('CANCELLED');
      await expect(
        prisma.emergencyRequest.findUnique({ where: { id: emergency.id } })
      ).resolves.toMatchObject({ id: emergency.id, status: 'CANCELLED' });
    });
  });
}
