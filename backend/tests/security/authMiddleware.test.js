/**
 * Phase I, Part 3: JWT / auth middleware hardening.
 *
 * Prisma is mocked so the identity lookup is deterministic and DB-free.
 * Verifies:
 *  - missing / malformed / expired / tampered tokens are rejected,
 *  - inactive identities are rejected,
 *  - role is sourced from the CURRENT DB record, not the token claim
 *    (a token claiming ADMIN cannot act as ADMIN if the DB says RESPONDER).
 */

process.env.DATABASE_URL = process.env.DATABASE_URL || 'postgresql://u:p@localhost:5432/db';
process.env.JWT_SECRET =
  process.env.JWT_SECRET || 'S6m2yq0m9k3wq7Zt1v8Xr4Lp6Nc2Bd5Hf8Jk1Mn4Qs7Uw0';

const jwt = require('jsonwebtoken');

const mockFindUnique = jest.fn();
jest.mock('../../src/config/prisma', () => ({
  user: { findUnique: (...args) => mockFindUnique(...args) },
}));

const env = require('../../src/config/env');
const authMiddleware = require('../../src/middleware/authMiddleware');

function run(headers, dbUser) {
  mockFindUnique.mockReset();
  if (dbUser !== undefined) mockFindUnique.mockResolvedValue(dbUser);
  const req = { headers, method: 'GET', originalUrl: '/api/x' };
  const res = {
    statusCode: null,
    body: null,
    status(c) { this.statusCode = c; return this; },
    json(b) { this.body = b; return this; },
  };
  let nextCalled = false;
  return authMiddleware(req, res, () => { nextCalled = true; }).then(() => ({
    req, res, nextCalled,
  }));
}

const sign = (payload, opts) => jwt.sign(payload, env.JWT_SECRET, opts);

describe('authMiddleware hardening', () => {
  test('no Authorization header -> 401', async () => {
    const { res, nextCalled } = await run({});
    expect(res.statusCode).toBe(401);
    expect(nextCalled).toBe(false);
  });

  test('non-Bearer scheme -> 401', async () => {
    const { res } = await run({ authorization: 'Basic abc' });
    expect(res.statusCode).toBe(401);
  });

  test('expired token -> 401', async () => {
    const token = sign({ userId: 1, role: 'REQUESTER' }, { expiresIn: -10 });
    const { res, nextCalled } = await run({ authorization: `Bearer ${token}` });
    expect(res.statusCode).toBe(401);
    expect(nextCalled).toBe(false);
  });

  test('token signed with a different secret -> 401', async () => {
    const token = jwt.sign({ userId: 1, role: 'ADMIN' }, 'some-other-secret');
    const { res } = await run({ authorization: `Bearer ${token}` });
    expect(res.statusCode).toBe(401);
  });

  test('valid token but user missing -> 401', async () => {
    const token = sign({ userId: 42, role: 'REQUESTER' });
    const { res } = await run({ authorization: `Bearer ${token}` }, null);
    expect(res.statusCode).toBe(401);
    expect(res.body.message).toMatch(/not found/i);
  });

  test('inactive user -> 401', async () => {
    const token = sign({ userId: 5, role: 'RESPONDER' });
    const { res } = await run(
      { authorization: `Bearer ${token}` },
      { id: 5, role: 'RESPONDER', isActive: false }
    );
    expect(res.statusCode).toBe(401);
    expect(res.body.message).toMatch(/inactive/i);
  });

  test('role comes from DB, not the token claim (anti-privilege-escalation)', async () => {
    // Token forges ADMIN, DB says RESPONDER -> req.user.role must be RESPONDER.
    const token = sign({ userId: 9, role: 'ADMIN' });
    const { req, res, nextCalled } = await run(
      { authorization: `Bearer ${token}` },
      { id: 9, role: 'RESPONDER', isActive: true }
    );
    expect(res.statusCode).toBeNull();
    expect(nextCalled).toBe(true);
    expect(req.user.role).toBe('RESPONDER');
    expect(req.user.id).toBe(9);
    expect(req.user.userId).toBe(9);
  });
});
