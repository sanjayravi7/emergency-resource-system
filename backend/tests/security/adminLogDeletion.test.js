// ADMIN-ONLY AFTER-ACTION LOG DELETION.
//
// Verifies RBAC, the confirmation guard, non-destructive archival, the
// ADMIN_DELETED_LOG audit event and that the security audit trail survives.
// Requires PostgreSQL.

require('dotenv').config();

const request = require('supertest');
const jwt = require('jsonwebtoken');

const app = require('../../src/app');
const prisma = require('../../src/config/prisma');
const env = require('../../src/config/env');

const hasDatabase = Boolean(process.env.DATABASE_URL && process.env.JWT_SECRET);

(hasDatabase ? describe : describe.skip)('Admin log deletion', () => {
  const runId = `logdel-${Date.now()}`;

  let requester;
  let responder;
  let admin;
  let requesterToken;
  let responderToken;
  let adminToken;
  let closedRequestId;
  let activeRequestId;
  const userIds = [];
  const requestIds = [];

  function tokenFor(user) {
    return jwt.sign({ userId: user.id, role: user.role }, env.JWT_SECRET, { expiresIn: '1h' });
  }

  async function createUser(role, suffix) {
    const user = await prisma.user.create({
      data: {
        name: `${runId}-${suffix}`,
        email: `${runId}-${suffix}@test.com`,
        password: 'log-deletion-test-password-hash',
        role,
        isActive: true,
        emailVerified: true,
      },
    });
    userIds.push(user.id);
    return user;
  }

  beforeAll(async () => {
    requester = await createUser('REQUESTER', 'requester');
    responder = await createUser('RESPONDER', 'responder');
    admin = await createUser('ADMIN', 'admin');
    requesterToken = tokenFor(requester);
    responderToken = tokenFor(responder);
    adminToken = tokenFor(admin);

    const closed = await prisma.emergencyRequest.create({
      data: {
        requesterId: requester.id,
        emergencyType: 'Medical',
        location: 'Archive test',
        priority: 'LOW',
        status: 'COMPLETED',
      },
    });
    closedRequestId = closed.id;
    requestIds.push(closed.id);

    const active = await prisma.emergencyRequest.create({
      data: {
        requesterId: requester.id,
        emergencyType: 'Medical',
        location: 'Active archive test',
        priority: 'LOW',
        status: 'IN_PROGRESS',
      },
    });
    activeRequestId = active.id;
    requestIds.push(active.id);
  });

  afterAll(async () => {
    if (!hasDatabase) return;
    await prisma.auditLog.deleteMany({ where: { targetId: { in: requestIds.map(String) } } });
    await prisma.emergencyRequest.deleteMany({ where: { id: { in: requestIds } } });
    await prisma.user.deleteMany({ where: { id: { in: userIds } } });
    await prisma.$disconnect();
  });

  test('REQUESTER cannot delete a log entry', async () => {
    const response = await request(app)
      .delete(`/api/admin/logs/${closedRequestId}`)
      .set('Authorization', `Bearer ${requesterToken}`)
      .send({ confirm: true });
    expect(response.statusCode).toBe(403);

    const row = await prisma.emergencyRequest.findUnique({ where: { id: closedRequestId } });
    expect(row.archivedAt).toBeNull();
  });

  test('RESPONDER cannot delete a log entry', async () => {
    const response = await request(app)
      .delete(`/api/admin/logs/${closedRequestId}`)
      .set('Authorization', `Bearer ${responderToken}`)
      .send({ confirm: true });
    expect(response.statusCode).toBe(403);
  });

  test('anonymous callers cannot delete a log entry', async () => {
    const response = await request(app)
      .delete(`/api/admin/logs/${closedRequestId}`)
      .send({ confirm: true });
    expect(response.statusCode).toBe(401);
  });

  test('an active emergency can never be deleted from the log', async () => {
    const response = await request(app)
      .delete(`/api/admin/logs/${activeRequestId}`)
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ confirm: true });
    expect(response.statusCode).toBe(400);

    const row = await prisma.emergencyRequest.findUnique({ where: { id: activeRequestId } });
    expect(row.archivedAt).toBeNull();
  });

  test('deletion requires explicit confirmation', async () => {
    const response = await request(app)
      .delete(`/api/admin/logs/${closedRequestId}`)
      .set('Authorization', `Bearer ${adminToken}`)
      .send({});
    expect(response.statusCode).toBe(400);
  });

  test('an unknown log id returns 404', async () => {
    const response = await request(app)
      .delete('/api/admin/logs/999999999')
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ confirm: true });
    expect(response.statusCode).toBe(404);
  });

  test('ADMIN archives the entry, records ADMIN_DELETED_LOG and keeps the data', async () => {
    const response = await request(app)
      .delete(`/api/admin/logs/${closedRequestId}`)
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ confirm: true });

    expect(response.statusCode).toBe(200);
    expect(response.body.success).toBe(true);

    const row = await prisma.emergencyRequest.findUnique({ where: { id: closedRequestId } });
    // Non-destructive: the request (and its history) still exists.
    expect(row).not.toBeNull();
    expect(row.status).toBe('COMPLETED');
    expect(row.archivedAt).toBeTruthy();
    expect(row.archivedById).toBe(admin.id);

    const audit = await prisma.auditLog.findFirst({
      where: { event: 'ADMIN_DELETED_LOG', targetId: String(closedRequestId) },
      orderBy: { id: 'desc' },
    });
    expect(audit).not.toBeNull();
    expect(audit.actorId).toBe(admin.id);
    expect(audit.actorRole).toBe('ADMIN');
  });

  test('the deleted entry disappears from the visible log but is reachable as archived', async () => {
    const visible = await request(app)
      .get('/api/admin/requests')
      .set('Authorization', `Bearer ${adminToken}`);
    expect(visible.body.requests.map((row) => row.id)).not.toContain(closedRequestId);

    const withArchived = await request(app)
      .get('/api/admin/requests?includeArchived=true')
      .set('Authorization', `Bearer ${adminToken}`);
    expect(withArchived.body.requests.map((row) => row.id)).toContain(closedRequestId);
  });

  test('deleting the same entry twice is refused', async () => {
    const response = await request(app)
      .delete(`/api/admin/logs/${closedRequestId}`)
      .set('Authorization', `Bearer ${adminToken}`)
      .send({ confirm: true });
    expect(response.statusCode).toBe(400);
  });

  test('the audit trail itself is exposed read-only to ADMIN', async () => {
    const response = await request(app)
      .get('/api/admin/audit-logs')
      .set('Authorization', `Bearer ${adminToken}`);

    expect(response.statusCode).toBe(200);
    expect(Array.isArray(response.body.logs)).toBe(true);
    // No secrets are ever stored or returned in audit metadata.
    const serialized = JSON.stringify(response.body.logs);
    expect(serialized).not.toMatch(/password"\s*:\s*"/i);
  });

  test('there is no endpoint that deletes audit records', async () => {
    const response = await request(app)
      .delete('/api/admin/audit-logs/1')
      .set('Authorization', `Bearer ${adminToken}`);
    expect(response.statusCode).toBe(404);
  });
});
