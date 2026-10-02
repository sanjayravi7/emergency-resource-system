// 6-DIGIT EMAIL PASSWORD RESET (end-to-end through the REST API).
//
// The mail transport is replaced by a capture stub so the test can read the
// code the way a human would (from the email) without any code ever being
// stored in plaintext or returned by the API. Requires PostgreSQL.

require('dotenv').config();

const request = require('supertest');
const bcrypt = require('bcrypt');
const jwt = require('jsonwebtoken');

// Captures the outgoing ERAS email instead of sending it.
const sentEmails = [];
jest.mock('../../src/services/emailService', () => ({
  sendVerificationCode: async (to, code) => {
    sentEmails.push({ to, code, kind: 'verification' });
    return { delivered: true, transport: 'test' };
  },
  sendPasswordResetCode: async (to, code) => {
    sentEmails.push({ to, code, kind: 'reset' });
    return { delivered: true, transport: 'test' };
  },
  send: async () => ({ delivered: false, transport: 'test' }),
  verificationEmail: () => ({ subject: 'x', text: 'y', html: 'z' }),
  passwordResetEmail: () => ({ subject: 'x', text: 'y', html: 'z' }),
}));

const app = require('../../src/app');
const prisma = require('../../src/config/prisma');
const env = require('../../src/config/env');

const hasDatabase = Boolean(process.env.DATABASE_URL && process.env.JWT_SECRET);

(hasDatabase ? describe : describe.skip)('6-digit password reset', () => {
  const runId = `reset-${Date.now()}`;
  const email = `${runId}@test.com`;
  const originalPassword = 'OriginalPassword1';
  const newPassword = 'BrandNewPassword2';

  let user;
  let userToken;

  const codeFor = (kind) => sentEmails.filter((mail) => mail.kind === kind).pop()?.code;

  beforeAll(async () => {
    user = await prisma.user.create({
      data: {
        name: `${runId}-user`,
        email,
        password: await bcrypt.hash(originalPassword, 10),
        role: 'REQUESTER',
        isActive: true,
        emailVerified: true,
      },
    });
    userToken = jwt.sign({ userId: user.id, role: user.role }, env.JWT_SECRET, { expiresIn: '1h' });
  });

  afterAll(async () => {
    if (!hasDatabase) return;
    await prisma.authCode.deleteMany({ where: { userId: user.id } });
    await prisma.user.delete({ where: { id: user.id } });
    await prisma.$disconnect();
  });

  beforeEach(() => {
    sentEmails.length = 0;
  });

  test('the request endpoint never reveals whether an account exists', async () => {
    const known = await request(app)
      .post('/api/auth/password/forgot')
      .send({ email });
    const unknown = await request(app)
      .post('/api/auth/password/forgot')
      .send({ email: `${runId}-nobody@test.com` });

    expect(known.statusCode).toBe(200);
    expect(unknown.statusCode).toBe(200);
    expect(known.body.message).toBe(unknown.body.message);
  });

  test('a malformed email address is rejected by the server validator', async () => {
    const response = await request(app)
      .post('/api/auth/password/forgot')
      .send({ email: 'not-an-email' });
    expect(response.statusCode).toBe(400);
    expect(response.body.message).toBe('Enter a valid email address');
  });

  test('a reset code is emailed as exactly 6 digits and never returned by the API', async () => {
    const response = await request(app)
      .post('/api/auth/password/forgot')
      .send({ email });

    expect(response.statusCode).toBe(200);
    expect(JSON.stringify(response.body)).not.toMatch(/\d{6}/);

    const code = codeFor('reset');
    expect(code).toMatch(/^\d{6}$/);
  });

  test('the code is stored hashed, never in plaintext', async () => {
    const code = codeFor('reset');
    const row = await prisma.authCode.findFirst({
      where: { userId: user.id, purpose: 'PASSWORD_RESET' },
      orderBy: { id: 'desc' },
    });
    expect(row.codeHash).not.toBe(code);
    expect(row.codeHash.startsWith('$2')).toBe(true);
    expect(await bcrypt.compare(code, row.codeHash)).toBe(true);
  });

  test('a wrong code is rejected', async () => {
    const code = codeFor('reset');
    const wrong = code === '000000' ? '111111' : '000000';
    const response = await request(app)
      .post('/api/auth/password/verify-code')
      .send({ email, code: wrong });
    expect(response.statusCode).toBe(400);
  });

  test('the correct code verifies, and the reset sets the new password', async () => {
    const code = codeFor('reset');

    const verified = await request(app)
      .post('/api/auth/password/verify-code')
      .send({ email, code });
    expect(verified.statusCode).toBe(200);

    const mismatched = await request(app)
      .post('/api/auth/password/reset')
      .send({ email, code, password: newPassword, confirmPassword: 'SomethingElse3' });
    expect(mismatched.statusCode).toBe(400);

    const reset = await request(app)
      .post('/api/auth/password/reset')
      .send({ email, code, password: newPassword, confirmPassword: newPassword });
    expect(reset.statusCode).toBe(200);

    const login = await request(app)
      .post('/api/auth/login')
      .send({ email, password: newPassword });
    expect(login.statusCode).toBe(200);
  });

  test('a reused code is refused', async () => {
    const code = codeFor('reset');
    const response = await request(app)
      .post('/api/auth/password/reset')
      .send({ email, code, password: newPassword, confirmPassword: newPassword });
    expect(response.statusCode).toBe(400);
  });

  test('sessions issued before the reset are no longer accepted', async () => {
    const response = await request(app)
      .get('/api/auth/me')
      .set('Authorization', `Bearer ${userToken}`);
    expect(response.statusCode).toBe(401);
  });

  test('an expired code is refused', async () => {
    await prisma.authCode.deleteMany({ where: { userId: user.id } });

    const { requestPasswordReset } = require('../../src/services/passwordResetService');
    const past = new Date(Date.now() - 60 * 60 * 1000);
    await requestPasswordReset(email, { now: past, code: '424242' });

    const response = await request(app)
      .post('/api/auth/password/reset')
      .send({ email, code: '424242', password: newPassword, confirmPassword: newPassword });
    expect(response.statusCode).toBe(400);
  });

  test('the attempt limit blocks brute forcing of a 6-digit code', async () => {
    // Fresh code for the current moment.
    await request(app).post('/api/auth/password/forgot').send({ email });
    const code = codeFor('reset');
    const wrong = code === '000000' ? '111111' : '000000';

    for (let attempt = 0; attempt < env.AUTH_CODE_MAX_ATTEMPTS; attempt += 1) {
      await request(app)
        .post('/api/auth/password/verify-code')
        .send({ email, code: wrong });
    }

    const afterLimit = await request(app)
      .post('/api/auth/password/reset')
      .send({ email, code, password: newPassword, confirmPassword: newPassword });
    expect(afterLimit.statusCode).toBe(400);
  });
}, 30000);
