// AUTOMATIC EXPIRATION OF UNATTENDED EMERGENCIES (backend authoritative).
//
// Requires PostgreSQL (same gating pattern as the other integration suites).
// Covers:
//   - 30 minute urgent expiry (medical/fire/accident/rescue)
//   - 4 hour supply expiry (food/water/relief/inventory)
//   - responder assignment preventing expiry
//   - IN_PROGRESS never expiring
//   - completed / cancelled requests never expiring
//   - refresh/restart behaviour: expiry is enforced on retrieval from the
//     durable expiresAt column, without any timer running

require('dotenv').config();

const request = require('supertest');
const jwt = require('jsonwebtoken');

const app = require('../../src/app');
const prisma = require('../../src/config/prisma');
const env = require('../../src/config/env');
const { expireUnattendedRequests, enforceExpiryOnRetrieval } = require('../../src/services/emergencyExpiryService');

const hasDatabase = Boolean(process.env.DATABASE_URL && process.env.JWT_SECRET);

(hasDatabase ? describe : describe.skip)('Automatic request expiry', () => {
  const runId = `expiry-${Date.now()}`;

  let requester;
  let responder;
  let requesterToken;
  let adminToken;
  const requestIds = [];
  const userIds = [];

  function tokenFor(user, role = user.role) {
    return jwt.sign({ userId: user.id, role }, env.JWT_SECRET, { expiresIn: '1h' });
  }

  async function createUser(role, suffix, extra = {}) {
    const user = await prisma.user.create({
      data: {
        name: `${runId}-${suffix}`,
        email: `${runId}-${suffix}@test.com`,
        password: 'not-a-real-hash-used-only-for-expiry-tests',
        role,
        isActive: true,
        emailVerified: true,
        ...extra,
      },
    });
    userIds.push(user.id);
    return user;
  }

  /** Insert a request with an explicit (past or future) expiry deadline. */
  async function createRequest(overrides = {}) {
    const row = await prisma.emergencyRequest.create({
      data: {
        requesterId: requester.id,
        emergencyType: 'Medical',
        location: 'Expiry test location',
        priority: 'HIGH',
        status: 'PENDING',
        // Default: already past its deadline so the next sweep expires it.
        expiresAt: new Date(Date.now() - 60 * 1000),
        ...overrides,
      },
    });
    requestIds.push(row.id);
    return row;
  }

  beforeAll(async () => {
    requester = await createUser('REQUESTER', 'requester');
    responder = await createUser('RESPONDER', 'responder', { responderStatus: 'AVAILABLE' });
    requesterToken = tokenFor(requester);
    adminToken = tokenFor(requester, 'ADMIN');
  });

  afterAll(async () => {
    if (!hasDatabase) return;
    await prisma.emergencyRequest.deleteMany({ where: { id: { in: requestIds } } });
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
    await prisma.$disconnect();
  });

  test('creation stores a server-generated deadline from the central policy', async () => {
    const response = await request(app)
      .post('/api/requests')
      .set('Authorization', `Bearer ${requesterToken}`)
      .send({
        emergencyType: 'Medical',
        location: 'Urgent expiry test',
        priority: 'HIGH',
        requiredResources: [],
      });

    expect(response.statusCode).toBe(201);
    const created = response.body.request;
    requestIds.push(created.id);

    expect(created.expiresAt).toBeTruthy();
    const minutes = (new Date(created.expiresAt).getTime() - Date.now()) / 60000;
    // ~30 minutes for an urgent emergency (allow a small clock tolerance).
    expect(minutes).toBeGreaterThan(28);
    expect(minutes).toBeLessThan(31);
  });

  test('an urgent unattended request past 30 minutes is expired by the backend', async () => {
    const row = await createRequest({
      emergencyType: 'Fire',
      expiresAt: new Date(Date.now() - 31 * 60 * 1000),
    });

    await expireUnattendedRequests();

    const after = await prisma.emergencyRequest.findUnique({ where: { id: row.id } });
    expect(after.status).toBe('CANCELLED');
    expect(after.expiredAt).toBeTruthy();
  });

  test('a supply request uses the ~4 hour window and does not expire early', async () => {
    const response = await request(app)
      .post('/api/requests')
      .set('Authorization', `Bearer ${requesterToken}`)
      .send({
        emergencyType: 'Food',
        location: 'Supply expiry test',
        description: 'food packets for 50 people',
        priority: 'MEDIUM',
        requiredResources: [],
      });

    expect(response.statusCode).toBe(201);
    const created = response.body.request;
    requestIds.push(created.id);

    const minutes = (new Date(created.expiresAt).getTime() - Date.now()) / 60000;
    expect(minutes).toBeGreaterThan(238);
    expect(minutes).toBeLessThan(241);

    await expireUnattendedRequests();
    const after = await prisma.emergencyRequest.findUnique({ where: { id: created.id } });
    expect(after.status).toBe('PENDING');
  });

  test('a responder assignment prevents expiry (accepted request does not expire)', async () => {
    const row = await createRequest({
      expiresAt: new Date(Date.now() - 60 * 60 * 1000),
    });
    await prisma.responderAssignment.create({
      data: { requestId: row.id, responderId: responder.id, status: 'ACTIVE' },
    });
    await prisma.emergencyRequest.update({
      where: { id: row.id },
      data: { status: 'ACCEPTED', acceptedById: responder.id, acceptedAt: new Date(), expiresAt: null },
    });

    await expireUnattendedRequests();

    const after = await prisma.emergencyRequest.findUnique({ where: { id: row.id } });
    expect(after.status).toBe('ACCEPTED');
    expect(after.expiredAt).toBeNull();
  });

  test('an IN_PROGRESS request never expires', async () => {
    const row = await createRequest({
      status: 'IN_PROGRESS',
      acceptedById: responder.id,
      acceptedAt: new Date(Date.now() - 3 * 60 * 60 * 1000),
      expiresAt: new Date(Date.now() - 2 * 60 * 60 * 1000),
    });

    await expireUnattendedRequests();

    const after = await prisma.emergencyRequest.findUnique({ where: { id: row.id } });
    expect(after.status).toBe('IN_PROGRESS');
    expect(after.expiredAt).toBeNull();
  });

  test('a completed request never expires', async () => {
    const row = await createRequest({
      status: 'COMPLETED',
      acceptedById: responder.id,
      acceptedAt: new Date(Date.now() - 3 * 60 * 60 * 1000),
      expiresAt: new Date(Date.now() - 2 * 60 * 60 * 1000),
    });

    await expireUnattendedRequests();

    const after = await prisma.emergencyRequest.findUnique({ where: { id: row.id } });
    expect(after.status).toBe('COMPLETED');
    expect(after.expiredAt).toBeNull();
  });

  test('a cancelled request never expires (and is never double-processed)', async () => {
    const row = await createRequest({
      status: 'CANCELLED',
      expiresAt: new Date(Date.now() - 2 * 60 * 60 * 1000),
    });

    await expireUnattendedRequests();

    const after = await prisma.emergencyRequest.findUnique({ where: { id: row.id } });
    expect(after.status).toBe('CANCELLED');
    expect(after.expiredAt).toBeNull();
  });

  test('expiry is idempotent under concurrent sweeps (no double processing)', async () => {
    const row = await createRequest({ expiresAt: new Date(Date.now() - 5 * 60 * 1000) });

    const [first, second] = await Promise.all([
      expireUnattendedRequests(),
      expireUnattendedRequests(),
    ]);

    const transitions = [first, second].filter((ids) => ids.includes(row.id)).length;
    expect(transitions).toBe(1);

    const after = await prisma.emergencyRequest.findUnique({ where: { id: row.id } });
    expect(after.status).toBe('CANCELLED');
  });

  test('refresh/restart behaviour: retrieval enforces expiry without any timer', async () => {
    const unexpired = await createRequest({
      emergencyType: 'Medical',
      // Past its deadline but never touched by a timer.
      expiresAt: new Date(Date.now() - 10 * 60 * 1000),
    });

    // Simulate a service restart: no background sweep has run, and the first
    // thing that happens is a normal request listing.
    const sweepResult = await enforceExpiryOnRetrieval();
    expect(sweepResult).toContain(unexpired.id);

    const response = await request(app)
      .get('/api/requests/my')
      .set('Authorization', `Bearer ${requesterToken}`);

    expect(response.statusCode).toBe(200);
    const ids = response.body.requests.map((row) => row.id);
    expect(ids).not.toContain(unexpired.id);
  });

  test('a live unattended request is still visible and joinable', async () => {
    const live = await createRequest({
      emergencyType: 'Medical',
      expiresAt: new Date(Date.now() + 20 * 60 * 1000),
    });

    const response = await request(app)
      .get('/api/requests/my')
      .set('Authorization', `Bearer ${requesterToken}`);

    const ids = response.body.requests.map((row) => row.id);
    expect(ids).toContain(live.id);
  });

  test('an expired request is never accepted (accept reports it as cancelled)', async () => {
    const row = await createRequest({ expiresAt: new Date(Date.now() - 45 * 60 * 1000) });
    await expireUnattendedRequests();

    const response = await request(app)
      .patch(`/api/requests/${row.id}/accept`)
      .set('Authorization', `Bearer ${tokenFor(responder)}`)
      .send({});

    expect([400, 404]).toContain(response.statusCode);
  });

  test('admin listing also reflects expiry (ADMIN sees the cancelled state)', async () => {
    const row = await createRequest({ expiresAt: new Date(Date.now() - 30 * 60 * 1000) });

    const response = await request(app)
      .get('/api/admin/requests')
      .set('Authorization', `Bearer ${adminToken}`);

    expect(response.statusCode).toBe(200);
    const entry = response.body.requests.find((item) => item.id === row.id);
    expect(entry.status).toBe('CANCELLED');
  });
});
