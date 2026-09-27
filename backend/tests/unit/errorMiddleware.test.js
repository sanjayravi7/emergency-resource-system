/**
 * Phase I, Part 2/9: the error handler must
 *  - map malformed / oversized / unsupported bodies to stable 4xx responses,
 *  - never leak Prisma query text or stack traces to clients,
 *  - preserve the existing business-conflict message contract.
 */

process.env.DATABASE_URL = process.env.DATABASE_URL || 'postgresql://u:p@localhost:5432/db';
process.env.JWT_SECRET =
  process.env.JWT_SECRET || 'S6m2yq0m9k3wq7Zt1v8Xr4Lp6Nc2Bd5Hf8Jk1Mn4Qs7Uw0';

const errorHandler = require('../../src/middleware/errorMiddleware');

function mockRes() {
  return {
    statusCode: null,
    body: null,
    status(code) {
      this.statusCode = code;
      return this;
    },
    json(payload) {
      this.body = payload;
      return this;
    },
  };
}

const req = { method: 'POST', originalUrl: '/api/x', user: { id: 1 } };

describe('errorMiddleware', () => {
  test('malformed JSON -> 400 with generic message', () => {
    const err = new SyntaxError('Unexpected token b in JSON at position 0');
    err.status = 400;
    err.body = '{bad';
    const res = mockRes();
    errorHandler(err, req, res, () => {});
    expect(res.statusCode).toBe(400);
    expect(res.body.message).toMatch(/Malformed JSON/);
  });

  test('entity.parse.failed -> 400', () => {
    const err = Object.assign(new Error('parse'), { type: 'entity.parse.failed', status: 400 });
    const res = mockRes();
    errorHandler(err, req, res, () => {});
    expect(res.statusCode).toBe(400);
  });

  test('oversized body -> 413', () => {
    const err = Object.assign(new Error('too big'), { type: 'entity.too.large', status: 413 });
    const res = mockRes();
    errorHandler(err, req, res, () => {});
    expect(res.statusCode).toBe(413);
    expect(res.body.message).toMatch(/too large/i);
  });

  test('Prisma error is masked - no query internals reach the client', () => {
    const err = Object.assign(
      new Error('Invalid `prisma.user.findUnique()` invocation: secret column detail'),
      { code: 'P2002', name: 'PrismaClientKnownRequestError' }
    );
    const res = mockRes();
    errorHandler(err, req, res, () => {});
    expect(res.statusCode).toBe(500);
    expect(res.body.message).toBe('Database operation failed');
    expect(res.body.message).not.toMatch(/prisma\./);
    expect(res.body.message).not.toMatch(/secret column/);
  });

  test('business conflict keeps its message + 500 contract', () => {
    const err = new Error('Unauthorized');
    const res = mockRes();
    errorHandler(err, req, res, () => {});
    expect(res.statusCode).toBe(500);
    expect(res.body.message).toBe('Unauthorized');
  });

  test('response body never contains a stack trace', () => {
    const err = new Error('boom');
    const res = mockRes();
    errorHandler(err, req, res, () => {});
    expect(JSON.stringify(res.body)).not.toMatch(/at Object|\.js:\d+/);
  });
});
