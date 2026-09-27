/**
 * Phase I, Part 2/9: HTTP hardening at the app boundary.
 *
 * Prisma is mocked so these middleware-level guarantees can be verified without
 * a database (they run identically in CI with a real DB, since none of these
 * paths touch a table).
 */

process.env.DATABASE_URL = process.env.DATABASE_URL || 'postgresql://u:p@localhost:5432/db';
process.env.JWT_SECRET =
  process.env.JWT_SECRET || 'S6m2yq0m9k3wq7Zt1v8Xr4Lp6Nc2Bd5Hf8Jk1Mn4Qs7Uw0';

jest.mock('../../src/config/prisma', () => ({
  user: { findUnique: jest.fn() },
}));

const request = require('supertest');
const app = require('../../src/app');

describe('HTTP hardening', () => {
  test('security headers are present and framework is not advertised', async () => {
    const res = await request(app).get('/api/nope');
    expect(res.headers['x-content-type-options']).toBe('nosniff');
    // helmet sets these; exact values may vary but must exist.
    expect(res.headers['x-powered-by']).toBeUndefined();
    expect(res.headers).toHaveProperty('x-dns-prefetch-control');
  });

  test('unknown route returns a JSON 404 envelope', async () => {
    const res = await request(app).get('/api/definitely-not-here');
    expect(res.status).toBe(404);
    expect(res.body).toEqual({ success: false, message: 'Not found' });
  });

  test('malformed JSON body -> 400, no stack trace', async () => {
    const res = await request(app)
      .post('/api/auth/login')
      .set('Content-Type', 'application/json')
      .send('{ this is not json');
    expect(res.status).toBe(400);
    expect(res.body.success).toBe(false);
    expect(res.body.message).toMatch(/Malformed JSON/);
    expect(JSON.stringify(res.body)).not.toMatch(/\.js:\d+/);
  });

  test('oversized JSON body -> 413', async () => {
    const big = JSON.stringify({ email: 'x'.repeat(200 * 1024) });
    const res = await request(app)
      .post('/api/auth/login')
      .set('Content-Type', 'application/json')
      .send(big);
    expect(res.status).toBe(413);
    expect(res.body.message).toMatch(/too large/i);
  });

  test('CORS reflects the request origin by default', async () => {
    const res = await request(app)
      .get('/api/nope')
      .set('Origin', 'https://client.example');
    expect(res.headers['access-control-allow-origin']).toBe('https://client.example');
  });

  test('protected route without a token is 401 (no DB access)', async () => {
    const res = await request(app).get('/api/auth/me');
    expect(res.status).toBe(401);
    expect(res.body.message).toMatch(/token/i);
  });
});
