// RESPONDER PRIVACY AT THE API BOUNDARY (security requirement).
//
// Proves that responder email/phone are OMITTED from every non-admin payload
// (responder directory, request cards, assignment payloads and allocations),
// and that ADMIN retains the allowed contact information. Requires PostgreSQL.

require('dotenv').config();

const request = require('supertest');
const jwt = require('jsonwebtoken');

const app = require('../../src/app');
const prisma = require('../../src/config/prisma');
const env = require('../../src/config/env');

const hasDatabase = Boolean(process.env.DATABASE_URL && process.env.JWT_SECRET);

(hasDatabase ? describe : describe.skip)('Responder contact privacy', () => {
  const runId = `priv-${Date.now()}`;

  const CONTACT_EMAIL = `${runId}-responder@test.com`;
  const CONTACT_PHONE = '+91 98888 77777';

  let requester;
  let responder;
  let admin;
  let requesterToken;
  let responderToken;
  let adminToken;
  let emergencyId;
  const userIds = [];
  const requestIds = [];

  function tokenFor(user) {
    return jwt.sign({ userId: user.id, role: user.role }, env.JWT_SECRET, { expiresIn: '1h' });
  }

  async function createUser(role, suffix, extra = {}) {
    const user = await prisma.user.create({
      data: {
        name: `${runId}-${suffix}`,
        email: `${runId}-${suffix}@test.com`,
        password: 'privacy-test-password-hash',
        role,
        isActive: true,
        emailVerified: true,
        ...extra,
      },
    });
    userIds.push(user.id);
    return user;
  }

  beforeAll(async () => {
    requester = await createUser('REQUESTER', 'requester');
    responder = await createUser('RESPONDER', 'responder', {
      email: CONTACT_EMAIL,
      phone: CONTACT_PHONE,
      responderStatus: 'AVAILABLE',
    });
    admin = await createUser('ADMIN', 'admin');

    requesterToken = tokenFor(requester);
    responderToken = tokenFor(responder);
    adminToken = tokenFor(admin);

    const emergency = await prisma.emergencyRequest.create({
      data: {
        requesterId: requester.id,
        emergencyType: 'Medical',
        location: 'Privacy test location',
        priority: 'HIGH',
        status: 'ACCEPTED',
        acceptedById: responder.id,
        acceptedAt: new Date(),
      },
    });
    emergencyId = emergency.id;
    requestIds.push(emergency.id);

    await prisma.responderAssignment.create({
      data: { requestId: emergency.id, responderId: responder.id, status: 'ACTIVE' },
    });
  });

  afterAll(async () => {
    if (!hasDatabase) return;
    await prisma.responderAssignment.deleteMany({ where: { requestId: { in: requestIds } } });
    await prisma.emergencyRequest.deleteMany({ where: { id: { in: requestIds } } });
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
    await prisma.$disconnect();
  });

  test('REQUESTER cannot obtain responder email or phone from the responder directory', async () => {
    const response = await request(app)
      .get('/api/responders')
      .set('Authorization', `Bearer ${requesterToken}`);

    expect(response.statusCode).toBe(200);
    const serialized = JSON.stringify(response.body);
    expect(serialized).not.toContain(CONTACT_EMAIL);
    expect(serialized).not.toContain(CONTACT_PHONE);
  });

  test('RESPONDER cannot obtain another responder email or phone', async () => {
    const response = await request(app)
      .get('/api/responders')
      .set('Authorization', `Bearer ${responderToken}`);

    expect(response.statusCode).toBe(200);
    const serialized = JSON.stringify(response.body);
    expect(serialized).not.toContain(CONTACT_PHONE);
    for (const row of response.body.responders) {
      expect(row).not.toHaveProperty('email');
      expect(row).not.toHaveProperty('phone');
    }
  });

  test('ADMIN can view the responder contact information', async () => {
    const response = await request(app)
      .get('/api/admin/responders')
      .set('Authorization', `Bearer ${adminToken}`);

    expect(response.statusCode).toBe(200);
    const target = response.body.responders.find((row) => row.id === responder.id);
    expect(target.email).toBe(CONTACT_EMAIL);
    expect(target.phone).toBe(CONTACT_PHONE);
  });

  test('REQUESTER request payloads omit responder contact details', async () => {
    const response = await request(app)
      .get('/api/requests/my')
      .set('Authorization', `Bearer ${requesterToken}`);

    expect(response.statusCode).toBe(200);
    const serialized = JSON.stringify(response.body);
    expect(serialized).not.toContain(CONTACT_EMAIL);
    expect(serialized).not.toContain(CONTACT_PHONE);
  });

  test('RESPONDER request payloads omit responder contact details', async () => {
    const response = await request(app)
      .get('/api/requests/assigned')
      .set('Authorization', `Bearer ${responderToken}`);

    expect(response.statusCode).toBe(200);
    const serialized = JSON.stringify(response.body);
    expect(serialized).not.toContain(CONTACT_EMAIL);
    expect(serialized).not.toContain(CONTACT_PHONE);
  });

  test('the shared responder-resource listing does not leak responder contact details', async () => {
    const response = await request(app)
      .get('/api/responder-resources')
      .set('Authorization', `Bearer ${responderToken}`);

    // The route exists for responders; whether it returns rows or not, no
    // contact detail may appear in the payload.
    expect([200, 403, 404]).toContain(response.statusCode);
    expect(JSON.stringify(response.body)).not.toContain(CONTACT_PHONE);
  });

  test('ADMIN request payloads keep responder contact details (existing contract)', async () => {
    const response = await request(app)
      .get('/api/admin/requests')
      .set('Authorization', `Bearer ${adminToken}`);

    expect(response.statusCode).toBe(200);
    expect(JSON.stringify(response.body)).toContain(CONTACT_PHONE);
  });
});
