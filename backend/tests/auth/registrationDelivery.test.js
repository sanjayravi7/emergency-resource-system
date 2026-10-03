// ---------------------------------------------------------------------------
// ERAS REGISTRATION, 6-DIGIT EMAIL VERIFICATION & POST-VERIFICATION WELCOME
//
// Exercises the full backend-owned OTP flow (authController -> authService ->
// emailVerificationService -> authCodeService -> emailService) against an
// in-memory Prisma store and mocked email transport so no real email is ever
// sent during automated tests.
// ---------------------------------------------------------------------------

process.env.DATABASE_URL =
  process.env.DATABASE_URL || 'postgresql://u:p@localhost:5432/db';
process.env.JWT_SECRET =
  process.env.JWT_SECRET || 'S6m2yq0m9k3wq7Zt1v8Xr4Lp6Nc2Bd5Hf8Jk1Mn4Qs7Uw0';

jest.mock('nodemailer', () => ({ createTransport: jest.fn() }));

const mockUsers = [];
const mockAuditLogs = [];
let mockNextUserId = 1;
let mockNextAuditId = 1;

jest.mock('../../src/config/prisma', () => {
      const fakeAuthCode = require('../helpers/fakeAuthCodePrisma');

  function projectSelect(row, select) {
    if (!row || !select) return row ? { ...row } : null;
    const out = {};
    for (const [key, enabled] of Object.entries(select)) {
      if (enabled) out[key] = row[key];
    }
    return out;
  }

  const prisma = {
    user: {
      findUnique: jest.fn(async ({ where, select } = {}) => {
        let found = null;
        if (where?.email !== undefined) {
          found = mockUsers.find((u) => u.email === where.email) || null;
        } else if (where?.id !== undefined) {
          found = mockUsers.find((u) => u.id === Number(where.id)) || null;
        }
        return projectSelect(found, select);
      }),
      create: jest.fn(async ({ data, select } = {}) => {
        const created = {
          id: mockNextUserId++,
          name: data.name,
          email: data.email,
          password: data.password,
          phone: data.phone ?? null,
          location: data.location ?? null,
          latitude: data.latitude ?? null,
          longitude: data.longitude ?? null,
          role: data.role ?? 'REQUESTER',
          isActive: data.isActive ?? true,
          lastActiveAt: data.lastActiveAt ?? null,
          responderStatus: data.responderStatus ?? 'OFFLINE',
          emailVerified: data.emailVerified ?? false,
          emailVerifiedAt: data.emailVerifiedAt ?? null,
          welcomeEmailDispatchClaimedAt: data.welcomeEmailDispatchClaimedAt ?? null,
          authProvider: data.authProvider ?? 'PASSWORD',
          firebaseUid: data.firebaseUid ?? null,
          passwordChangedAt: data.passwordChangedAt ?? null,
          createdAt: new Date(),
          updatedAt: new Date(),
        };
        mockUsers.push(created);
        return projectSelect(created, select);
      }),
      update: jest.fn(async ({ where, data, select } = {}) => {
        const user = mockUsers.find((u) => u.id === Number(where.id));
        if (!user) throw new Error('User not found');
        Object.assign(user, data, { updatedAt: new Date() });
        return projectSelect(user, select);
      }),
      updateMany: jest.fn(async ({ where, data } = {}) => {
        const user = mockUsers.find((candidate) =>
          Object.entries(where || {}).every(([key, value]) => candidate[key] === value)
        );
        if (!user) return { count: 0 };
        Object.assign(user, data, { updatedAt: new Date() });
        return { count: 1 };
      }),
    },
    authCode: fakeAuthCode.authCode,
    auditLog: {
      create: jest.fn(async ({ data }) => {
        const row = {
          id: mockNextAuditId++,
          ...data,
          createdAt: new Date(),
        };
        mockAuditLogs.push(row);
        return row;
      }),
    },
    $transaction: async (callback) => callback(prisma),
  };

  return prisma;
});

const request = require('supertest');
const bcrypt = require('bcrypt');
const nodemailer = require('nodemailer');

const fakeAuthCode = require('../helpers/fakeAuthCodePrisma');
const env = require('../../src/config/env');
const logger = require('../../src/config/logger');
const emailService = require('../../src/services/emailService');
const authCodeService = require('../../src/services/authCodeService');
const emailVerificationService = require('../../src/services/emailVerificationService');
const authService = require('../../src/services/authService');
const app = require('../../src/app');

describe('ERAS registration, 6-digit email verification, and welcome email flow', () => {
  const sentMessages = [];
  let sendSpy;

  beforeEach(() => {
    mockUsers.length = 0;
    mockAuditLogs.length = 0;
    mockNextUserId = 1;
    mockNextAuditId = 1;
    sentMessages.length = 0;
    fakeAuthCode.reset();
    jest.restoreAllMocks();

    env.RESEND_API_KEY = null;
    env.SMTP_URL = null;
    env.ERAS_MAIL_FROM = null;
    delete process.env.RESEND_API_KEY;
    delete process.env.SMTP_URL;
    delete process.env.ERAS_MAIL_FROM;

    // Intercept at the single transport abstraction `emailService.send` so
    // `verificationEmail`, `welcomeEmail`, `sendVerificationCode`, and
    // `sendWelcomeEmail` execute their real payload generation logic without
    // sending real network mail.
    sendSpy = jest.spyOn(emailService, 'send').mockImplementation(async (payload) => {
      sentMessages.push(payload);
      return {
        deliveryAccepted: true,
        accepted: true,
        delivered: null,
        deliveryConfirmed: false,
        deliveryResult: 'accepted',
        transport: 'resend',
        provider: 'Resend',
        transportConfigured: 'yes',
      };
    });
  });

  afterEach(() => {
    jest.restoreAllMocks();
  });

  function extractSixDigitCode(message) {
    const match = message?.text?.match(/\b(\d{6})\b/);
    return match ? match[1] : null;
  }

  test('1 & 2. Registration creates emailVerified=false and issues a hashed 6-digit EMAIL_VERIFICATION code', async () => {
    const res = await request(app)
      .post('/api/auth/register')
      .send({
        name: 'Asha Menon',
        email: 'asha@example.com',
        password: 'StrongPassword123!',
        role: 'REQUESTER',
      });

    expect(res.status).toBe(201);
    expect(res.body.success).toBe(true);
    expect(res.body.data.verificationRequired).toBe(true);
    expect(res.body.data.emailVerified).toBe(false);
    expect(res.body.data.emailDelivered).toBeNull();
    expect(res.body.data.emailRequestAccepted).toBe(true);
    expect(res.body.data.emailDeliveryAccepted).toBe(true);
    expect(res.body.data.emailDeliveryConfirmed).toBe(false);
    expect(res.body.data.emailDeliveryStatus).toBe('accepted');
    expect(res.body.data.emailDeliveryResult).toBe('accepted');
    expect(res.body.data.user.email).toBe('asha@example.com');
    expect(res.body.data.user.emailVerified).toBe(false);
    expect(res.body.data.user.authProvider).toBe('PASSWORD');
    expect(res.body.data.token).toBeDefined();

    // Persisted user starts unverified
    expect(mockUsers).toHaveLength(1);
    expect(mockUsers[0].emailVerified).toBe(false);
    expect(mockUsers[0].emailVerifiedAt).toBeNull();

    // Auth code row is EMAIL_VERIFICATION and stores only a bcrypt hash
    const storedCodes = fakeAuthCode.allRows();
    expect(storedCodes).toHaveLength(1);
    expect(storedCodes[0].purpose).toBe(authCodeService.PURPOSES.EMAIL_VERIFICATION);
    expect(storedCodes[0].codeHash).toMatch(/^\$2[aby]\$/);

    // Sent verification email contains the 6-digit code matching the stored hash
    expect(sentMessages).toHaveLength(1);
    const code = extractSixDigitCode(sentMessages[0]);
    expect(code).toMatch(/^\d{6}$/);
    expect(storedCodes[0].codeHash).not.toContain(code);
    expect(await bcrypt.compare(code, storedCodes[0].codeHash)).toBe(true);
  });

  test('3. Verification email payload contains ERAS branding, Welcome to ERAS wording, 6-digit code, expiry, one-time-use, and no Firebase/Google impersonation', () => {
    const payload = emailService.verificationEmail('482915');

    expect(payload.subject).toContain('ERAS');
    expect(payload.text).toContain('Welcome to ERAS');
    expect(payload.html).toContain('Welcome to ERAS');
    expect(payload.text).toContain('482915');
    expect(payload.html).toContain('482915');
    expect(payload.text).toMatch(/\b\d{6}\b/);
    expect(payload.html).toMatch(/\b\d{6}\b/);

    // Expiry, one-time use, and instruction to enter in ERAS
    expect(payload.text).toMatch(/expires in \d+ minutes/i);
    expect(payload.html).toMatch(/expires in \d+ minutes/i);
    expect(payload.text).toMatch(/used once/i);
    expect(payload.html).toMatch(/one-time|works once/i);
    expect(payload.text).toMatch(/Enter this code in ERAS/i);
    expect(payload.html).toMatch(/Enter this one-time 6-digit verification code in ERAS/i);

    // Never impersonates Firebase or Google
    expect(payload.subject).not.toMatch(/firebase|google/i);
    expect(payload.text).not.toMatch(/firebase|google/i);
    expect(payload.html).not.toMatch(/firebase|google/i);
  });

  test('4 & 9. Correct 6-digit code verifies the account and triggers the ERAS welcome email', async () => {
    const reg = await request(app)
      .post('/api/auth/register')
      .send({
        name: 'Asha Menon',
        email: 'asha@example.com',
        password: 'StrongPassword123!',
        role: 'REQUESTER',
      });

    // Welcome email is NOT sent at registration time
    expect(sentMessages).toHaveLength(1);
    expect(sentMessages[0].subject).toBe('ERAS: confirm your email address');

    const code = extractSixDigitCode(sentMessages[0]);
    const token = reg.body.data.token;

    const verifyRes = await request(app)
      .post('/api/auth/verify-email')
      .set('Authorization', `Bearer ${token}`)
      .send({ code });

    expect(verifyRes.status).toBe(200);
    expect(verifyRes.body.success).toBe(true);
    expect(verifyRes.body.data.user.emailVerified).toBe(true);
    expect(verifyRes.body.data.emailVerified).toBe(true);
    expect(verifyRes.body.data.welcomeEmailSent).toBe(true);
    expect(verifyRes.body.data.welcomeEmailRequestAccepted).toBe(true);
    expect(verifyRes.body.data.welcomeEmailDelivered).toBeNull();
    expect(verifyRes.body.data.welcomeEmailDeliveryConfirmed).toBe(false);
    expect(verifyRes.body.data.welcomeEmailDeliveryStatus).toBe('accepted');
    expect(verifyRes.body.data.welcomeEmailDeliveryResult).toBe('accepted');

    // Persisted user is now verified
    expect(mockUsers[0].emailVerified).toBe(true);
    expect(mockUsers[0].emailVerifiedAt).toBeInstanceOf(Date);
    expect(mockUsers[0].welcomeEmailDispatchClaimedAt).toBeInstanceOf(Date);

    // Code is marked consumed
    const storedCodes = fakeAuthCode.allRows();
    expect(storedCodes[0].consumedAt).not.toBeNull();

    // Welcome email was sent after verification
    expect(sentMessages).toHaveLength(2);
    const welcome = sentMessages[1];
    expect(welcome.to).toBe('asha@example.com');
    expect(welcome.subject).toBe('Welcome to ERAS — your account is verified');
    expect(welcome.text).toContain('Welcome to ERAS, Asha.');
    expect(welcome.text).toContain(
      'Your email address has been verified and your ERAS account is now ready to use.'
    );
    expect(welcome.text).toContain(
      'Thank you for joining ERAS, the Emergency Resource Allocation System.'
    );
    expect(welcome.html).toContain('Welcome to ERAS, Asha.');
    expect(welcome.html).toContain(
      'Your email address has been verified and your ERAS account is now ready to use.'
    );
    expect(welcome.html).toContain(
      'Thank you for joining ERAS, the Emergency Resource Allocation System.'
    );

    // Welcome email never contains password, JWT, verification code, or secrets
    const serializedWelcome = JSON.stringify(welcome);
    expect(serializedWelcome).not.toContain('StrongPassword123!');
    expect(serializedWelcome).not.toContain(token);
    expect(serializedWelcome).not.toContain(code);
    expect(serializedWelcome).not.toMatch(/firebase|google/i);
  });

  test('verification endpoint rejects non-string, whitespace-padded, and non-six-digit codes before consumption', async () => {
    const reg = await request(app)
      .post('/api/auth/register')
      .send({
        name: 'Strict Code User',
        email: 'strict-code@example.com',
        password: 'StrongPassword123!',
        role: 'REQUESTER',
      });
    const token = reg.body.data.token;

    for (const code of [' 123456', '123456 ', '12345', 123456]) {
      const response = await request(app)
        .post('/api/auth/verify-email')
        .set('Authorization', `Bearer ${token}`)
        .send({ code });
      expect(response.status).toBe(400);
      expect(response.body.message).toBe('Enter the 6-digit code');
    }

    expect(fakeAuthCode.allRows()[0].consumedAt).toBeNull();
    expect(mockUsers[0].emailVerified).toBe(false);
    expect(
      sentMessages.filter((message) => message.subject === 'Welcome to ERAS — your account is verified'),
    ).toHaveLength(0);
  });

  test('5 & 11. Wrong code fails verification and does NOT send welcome email', async () => {
    const reg = await request(app)
      .post('/api/auth/register')
      .send({
        name: 'Rahul Nair',
        email: 'rahul@example.com',
        password: 'StrongPassword123!',
        role: 'RESPONDER',
      });

    const code = extractSixDigitCode(sentMessages[0]);
    const wrongCode = code === '000000' ? '999999' : '000000';
    const token = reg.body.data.token;

    const verifyRes = await request(app)
      .post('/api/auth/verify-email')
      .set('Authorization', `Bearer ${token}`)
      .send({ code: wrongCode });

    expect(verifyRes.status).toBe(400);
    expect(verifyRes.body.success).toBe(false);
    expect(verifyRes.body.message).toBe('That verification code is invalid or has expired');

    // Account remains unverified and no welcome email is sent
    expect(mockUsers[0].emailVerified).toBe(false);
    expect(mockUsers[0].emailVerifiedAt).toBeNull();
    expect(sentMessages).toHaveLength(1);
  });

  test('6 & 11. Expired code fails verification and does NOT send welcome email', async () => {
    const t0 = new Date('2026-10-03T10:00:00.000Z');
    const user = await prismaUserForTest({
      name: 'Meera Nair',
      email: 'meera@example.com',
    });

    await emailVerificationService.issueVerificationForUser(user, {
      now: t0,
      code: '135790',
    });
    expect(sentMessages).toHaveLength(1);

    const expiredTime = new Date(
      t0.getTime() + (env.EMAIL_VERIFICATION_TTL_MINUTES + 1) * 60 * 1000
    );
    const result = await emailVerificationService.confirmVerification(
      user.id,
      '135790',
      { now: expiredTime }
    );

    expect(result.ok).toBe(false);
    expect(result.reason).toBe('EXPIRED_CODE');
    expect(result.welcomeEmailSent).toBe(false);
    expect(mockUsers[0].emailVerified).toBe(false);
    expect(sentMessages).toHaveLength(1);
  });

  test('7. Reusing a consumed code fails', async () => {
    const t0 = new Date('2026-10-03T10:00:00.000Z');
    const user = await prismaUserForTest({
      name: 'Kiran Das',
      email: 'kiran@example.com',
    });

    await emailVerificationService.issueVerificationForUser(user, {
      now: t0,
      code: '246810',
    });

    // Consume code directly at the authCodeService layer
    const firstConsume = await authCodeService.consumeCode({
      userId: user.id,
      purpose: authCodeService.PURPOSES.EMAIL_VERIFICATION,
      code: '246810',
      now: t0,
    });
    expect(firstConsume.ok).toBe(true);

    // Attempting to verify with the already-consumed code fails and sends no welcome email
    const secondAttempt = await emailVerificationService.confirmVerification(
      user.id,
      '246810',
      { now: t0 }
    );
    expect(secondAttempt.ok).toBe(false);
    expect(secondAttempt.reason).toBe('INVALID_CODE');
    expect(secondAttempt.welcomeEmailSent).toBe(false);
    expect(mockUsers[0].emailVerified).toBe(false);
    expect(sentMessages).toHaveLength(1);
  });

  test('8. Resend generates a new 6-digit code, invalidates the previous code, respects cooldown, and prevents enumeration', async () => {
    const t0 = new Date('2026-10-03T10:00:00.000Z');
    const user = await prismaUserForTest({
      name: 'Deepa Varma',
      email: 'deepa@example.com',
    });

    await emailVerificationService.issueVerificationForUser(user, {
      now: t0,
      code: '111222',
    });
    expect(sentMessages).toHaveLength(1);

    // Inside cooldown window -> blocked with retryAfterSeconds
    const duringCooldown = await emailVerificationService.resendVerificationForEmail(
      'deepa@example.com',
      { now: new Date(t0.getTime() + 5 * 1000) }
    );
    expect(duringCooldown.ok).toBe(true);
    expect(duringCooldown.sent).toBe(false);
    expect(duringCooldown.reason).toBe('COOLDOWN');
    expect(duringCooldown.retryAfterSeconds).toBeGreaterThan(0);
    expect(sentMessages).toHaveLength(1);

    // After cooldown window -> issues a new 6-digit code and invalidates the old one
    const afterCooldown = new Date(
      t0.getTime() + (env.AUTH_CODE_RESEND_COOLDOWN_SECONDS + 2) * 1000
    );
    const resent = await emailVerificationService.resendVerificationForEmail(
      'deepa@example.com',
      { now: afterCooldown }
    );
    expect(resent.ok).toBe(true);
    expect(resent.sent).toBe(true);
    expect(sentMessages).toHaveLength(2);

    const newCode = extractSixDigitCode(sentMessages[1]);
    expect(newCode).toMatch(/^\d{6}$/);

    // Old code '111222' is now invalidated
    const oldResult = await emailVerificationService.confirmVerification(
      user.id,
      '111222',
      { now: afterCooldown }
    );
    expect(oldResult.ok).toBe(false);
    expect(mockUsers[0].emailVerified).toBe(false);
    expect(sentMessages).toHaveLength(2);

    // New code succeeds and triggers welcome email
    const newResult = await emailVerificationService.confirmVerification(
      user.id,
      newCode,
      { now: afterCooldown }
    );
    expect(newResult.ok).toBe(true);
    expect(mockUsers[0].emailVerified).toBe(true);
    expect(sentMessages).toHaveLength(3);
    expect(sentMessages[2].subject).toBe('Welcome to ERAS — your account is verified');

    // Anti-enumeration on REST endpoint: unknown email gets identical message
    const unknownRes = await request(app)
      .post('/api/auth/resend-verification')
      .send({ email: 'nobody@example.com' });
    const verifiedRes = await request(app)
      .post('/api/auth/resend-verification')
      .send({ email: 'deepa@example.com' });
    expect(unknownRes.status).toBe(200);
    expect(verifiedRes.status).toBe(200);
    expect(unknownRes.body.message).toBe(verifiedRes.body.message);
  });

  test('10. Repeated refresh/status checks and repeated verify calls do NOT send duplicate welcome emails', async () => {
    const reg = await request(app)
      .post('/api/auth/register')
      .send({
        name: 'Vikram Menon',
        email: 'vikram@example.com',
        password: 'StrongPassword123!',
        role: 'REQUESTER',
      });

    const token = reg.body.data.token;
    const code = extractSixDigitCode(sentMessages[0]);

    // Status checks before verification do not send welcome email
    const meBefore = await request(app)
      .get('/api/auth/me')
      .set('Authorization', `Bearer ${token}`);
    expect(meBefore.status).toBe(200);
    expect(meBefore.body.data.user.emailVerified).toBe(false);
    expect(sentMessages).toHaveLength(1);

    // First verification sends exactly 1 welcome email
    const firstVerify = await request(app)
      .post('/api/auth/verify-email')
      .set('Authorization', `Bearer ${token}`)
      .send({ code });
    expect(firstVerify.status).toBe(200);
    expect(firstVerify.body.data.welcomeEmailSent).toBe(true);
    expect(sentMessages).toHaveLength(2);

    // Repeated GET /api/auth/me refresh calls never send welcome emails
    for (let i = 0; i < 3; i += 1) {
      const meAfter = await request(app)
        .get('/api/auth/me')
        .set('Authorization', `Bearer ${token}`);
      expect(meAfter.status).toBe(200);
      expect(meAfter.body.data.user.emailVerified).toBe(true);
    }

    // Repeated POST /api/auth/verify-email calls on an already-verified account
    // are idempotent and do NOT send duplicate welcome emails
    const secondVerify = await request(app)
      .post('/api/auth/verify-email')
      .set('Authorization', `Bearer ${token}`)
      .send({ code });
    expect(secondVerify.status).toBe(200);
    expect(secondVerify.body.data.user.emailVerified).toBe(true);
    expect(secondVerify.body.data.welcomeEmailSent).toBe(false);

    const welcomeEmails = sentMessages.filter(
      (m) => m.subject === 'Welcome to ERAS — your account is verified'
    );
    expect(welcomeEmails).toHaveLength(1);
  });

  test('12. Email delivery failure does not roll back account creation or verification state', async () => {
    // Part A: Verification email delivery fails (delivered: false)
    sendSpy.mockResolvedValueOnce({
      delivered: false,
      deliveryResult: 'failure',
      transport: 'unconfigured',
      provider: 'unconfigured',
      transportConfigured: 'no',
    });

    const reg1 = await authService.registerUser({
      name: 'Jane Doe',
      email: 'jane@example.com',
      password: 'StrongPassword123!',
      role: 'RESPONDER',
    });

    expect(reg1.user.email).toBe('jane@example.com');
    expect(reg1.user.role).toBe('RESPONDER');
    expect(reg1.verificationRequired).toBe(true);
    expect(reg1.emailDelivered).toBeNull();
    expect(reg1.emailRequestAccepted).toBe(false);
    expect(reg1.emailDeliveryResult).toBe('unconfigured');
    expect(reg1.token).toBeDefined();
    expect(mockUsers).toHaveLength(1);

    // Part B: Verification email throws an exception
    jest
      .spyOn(emailVerificationService, 'issueVerificationForUser')
      .mockRejectedValueOnce(new Error('Resend network timeout'));

    const reg2 = await authService.registerUser({
      name: 'Bob Smith',
      email: 'bob@example.com',
      password: 'StrongPassword123!',
      role: 'REQUESTER',
    });
    expect(reg2.user.email).toBe('bob@example.com');
    expect(reg2.emailDelivered).toBeNull();
    expect(reg2.emailRequestAccepted).toBe(false);
    expect(reg2.emailDeliveryResult).toBe('failed');
    expect(mockUsers).toHaveLength(2);

    // Part C: Welcome email fails / throws during verification -> user still stays verified
    const user3 = await prismaUserForTest({
      name: 'Ananya Rao',
      email: 'ananya@example.com',
    });
    await emailVerificationService.issueVerificationForUser(user3, { code: '777888' });
    env.RESEND_API_KEY = 're_mock_resend_key';
    env.ERAS_MAIL_FROM = 'no-reply@eras.example.org';

    jest
      .spyOn(emailService, 'sendWelcomeEmail')
      .mockRejectedValueOnce(new Error('SMTP connection reset'));

    const confirmed = await emailVerificationService.confirmVerification(
      user3.id,
      '777888'
    );
    expect(confirmed.ok).toBe(true);
    expect(confirmed.user.emailVerified).toBe(true);
    expect(confirmed.welcomeEmailDelivered).toBeNull();
    expect(confirmed.welcomeEmailRequestAccepted).toBe(false);
    expect(confirmed.welcomeEmailDeliveryResult).toBe('failed');

    const storedUser3 = mockUsers.find((u) => u.id === user3.id);
    expect(storedUser3.emailVerified).toBe(true);
    expect(storedUser3.emailVerifiedAt).toBeInstanceOf(Date);
  });

  test('13. No secret, token, password, email address, or 6-digit code is ever written to logs', async () => {
    const logLines = [];
    const logSpy = jest.spyOn(console, 'log').mockImplementation((...args) => {
      logLines.push(args.join(' '));
    });
    const warnSpy = jest.spyOn(console, 'warn').mockImplementation((...args) => {
      logLines.push(args.join(' '));
    });
    const errSpy = jest.spyOn(console, 'error').mockImplementation((...args) => {
      logLines.push(args.join(' '));
    });

    process.env.LOG_IN_TEST = '1';
    const fakeResendSecret = 're_secret_api_key_99887766';
    env.RESEND_API_KEY = fakeResendSecret;
    env.ERAS_MAIL_FROM = 'no-reply@eras.example.org';

    // Exercise real `emailService.send` with a mocked fetch that fails and includes sensitive values
    sendSpy.mockRestore();
    const originalFetch = global.fetch;
    global.fetch = jest.fn(async () => ({
      ok: false,
      status: 502,
      json: async () => ({
        name: 'validation_error',
        type: 'sender_rejected',
        message: `request for private.person@example.com rejected with code 654321; ${fakeResendSecret}; smtps://smtp-user:smtp-password@smtp.example.org:465`,
      }),
    }));

    try {
      const secretPassword = 'UltraSecretPassword!99';
      const targetEmail = 'sensitive.user@example.com';

      const reg = await request(app)
        .post('/api/auth/register')
        .send({
          name: 'Sensitive User',
          email: targetEmail,
          password: secretPassword,
          role: 'REQUESTER',
        });

      expect(reg.status).toBe(201);
      const jwtToken = reg.body.data.token;

      // Issue a known 6-digit code and test both wrong and right code
      const tLater = new Date(Date.now() + 120 * 1000);
      const knownCode = '654321';
      await emailVerificationService.issueVerificationForUser(mockUsers[0], {
        now: tLater,
        code: knownCode,
      });

      await emailVerificationService.confirmVerification(mockUsers[0].id, '000000', {
        now: tLater,
      });
      await emailVerificationService.confirmVerification(mockUsers[0].id, knownCode, {
        now: tLater,
      });

      // Also test direct logger redaction if a caller passes sensitive keys
      logger.info('test.redaction_check', {
        code: knownCode,
        verificationCode: knownCode,
        email: targetEmail,
        password: secretPassword,
        token: jwtToken,
        apiKey: fakeResendSecret,
      });

      const combinedLogs = logLines.join('\n') + '\n' + JSON.stringify(mockAuditLogs);

      expect(combinedLogs).not.toContain(knownCode);
      expect(combinedLogs).not.toContain(targetEmail);
      expect(combinedLogs).not.toContain(secretPassword);
      expect(combinedLogs).not.toContain(jwtToken);
      expect(combinedLogs).not.toContain(fakeResendSecret);
      expect(combinedLogs).not.toContain('smtp-user');
      expect(combinedLogs).not.toContain('smtp-password');
      expect(combinedLogs).not.toContain('private.person@example.com');
      expect(combinedLogs).not.toContain('654321');
      expect(combinedLogs).toContain('validation_error');
      expect(combinedLogs).toContain('sender_rejected');
      expect(combinedLogs).toContain('502');
    } finally {
      global.fetch = originalFetch;
      delete process.env.LOG_IN_TEST;
      logSpy.mockRestore();
      warnSpy.mockRestore();
      errSpy.mockRestore();
    }
  });

  test('concurrent code confirmations verify once and persist one welcome-email claim', async () => {
    const registration = await request(app)
      .post('/api/auth/register')
      .send({
        name: 'Concurrent User',
        email: 'concurrent@example.com',
        password: 'StrongPassword123!',
        role: 'REQUESTER',
      });
    const token = registration.body.data.token;
    const code = extractSixDigitCode(sentMessages[0]);

    const confirm = () => request(app)
      .post('/api/auth/verify-email')
      .set('Authorization', `Bearer ${token}`)
      .send({ code });
    const results = await Promise.all([confirm(), confirm()]);

    expect(results.every((response) => response.status === 200)).toBe(true);
    expect(mockUsers[0].emailVerified).toBe(true);
    expect(mockUsers[0].emailVerifiedAt).toBeInstanceOf(Date);
    expect(mockUsers[0].welcomeEmailDispatchClaimedAt).toBeInstanceOf(Date);
    expect(
      sentMessages.filter((message) => message.subject === 'Welcome to ERAS — your account is verified'),
    ).toHaveLength(1);
    expect(results.filter((response) => response.body.data.welcomeEmailSent === true)).toHaveLength(1);
  });

  test('welcome email is not attempted unless the durable verification update succeeds', async () => {
    const user = await prismaUserForTest({
      name: 'Database Failure User',
      email: 'database-failure@example.com',
    });
    await emailVerificationService.issueVerificationForUser(user, {
      code: '808080',
    });
    const prisma = require('../../src/config/prisma');
    const updateMany = prisma.user.updateMany;
    prisma.user.updateMany = jest.fn().mockRejectedValueOnce(new Error('database write failed'));

    try {
      await expect(
        emailVerificationService.confirmVerification(user.id, '808080'),
      ).rejects.toThrow('database write failed');
      expect(mockUsers[0].emailVerified).toBe(false);
      expect(sentMessages.filter((message) =>
        message.subject === 'Welcome to ERAS — your account is verified',
      )).toHaveLength(0);
    } finally {
      prisma.user.updateMany = updateMany;
    }
  });

  test('Safe email transport diagnostics report configured/provider/fromConfigured without leaking secrets', async () => {
    // 1. Unconfigured
    expect(emailService.getTransportDiagnostics()).toEqual({
      configured: false,
      transportConfigured: 'no',
      provider: 'unconfigured',
      transport: 'unconfigured',
      fromConfigured: 'no',
      senderValid: 'no',
      smtpFallbackConfigured: 'no',
      configurationError: 'EMAIL_TRANSPORT_UNCONFIGURED',
    });

    const healthUnconfigured = await request(app).get('/health/email');
    expect(healthUnconfigured.status).toBe(200);
    expect(healthUnconfigured.body).toEqual({
      success: true,
      status: 'ok',
      email: {
        transportConfigured: 'no',
        provider: 'unconfigured',
        fromConfigured: 'no',
        senderValid: 'no',
        smtpFallbackConfigured: 'no',
        configurationError: 'EMAIL_TRANSPORT_UNCONFIGURED',
      },
    });

    // 2. Resend configured
    env.RESEND_API_KEY = 're_live_super_secret_do_not_leak';
    env.ERAS_MAIL_FROM = 'no-reply@eras.example.org';
    expect(emailService.getTransportDiagnostics()).toEqual({
      configured: true,
      transportConfigured: 'yes',
      provider: 'Resend',
      transport: 'resend',
      fromConfigured: 'yes',
      senderValid: 'yes',
      smtpFallbackConfigured: 'no',
      configurationError: null,
    });

    const healthResend = await request(app).get('/health/email');
    expect(healthResend.status).toBe(200);
    expect(healthResend.body.email).toEqual({
      transportConfigured: 'yes',
      provider: 'Resend',
      fromConfigured: 'yes',
      senderValid: 'yes',
      smtpFallbackConfigured: 'no',
      configurationError: null,
    });
    expect(JSON.stringify(healthResend.body)).not.toContain('re_live_super_secret_do_not_leak');
    expect(JSON.stringify(healthResend.body)).not.toContain('no-reply@eras.example.org');

    // 3. SMTP fallback when Resend is unset
    env.RESEND_API_KEY = null;
    env.SMTP_URL = 'smtps://user:smtp_secret_pass@smtp.example.org:465';
    expect(emailService.getTransportDiagnostics()).toEqual({
      configured: true,
      transportConfigured: 'yes',
      provider: 'SMTP',
      transport: 'smtp',
      fromConfigured: 'yes',
      senderValid: 'yes',
      smtpFallbackConfigured: 'no',
      configurationError: null,
    });
  });

  test('emailService uses Resend first, falls back to configured SMTP, and reports unconfigured/failure states', async () => {
    sendSpy.mockRestore();
    const originalFetch = global.fetch;

    try {
      // 1. Unconfigured -> safe no-op. No invented sender or code is logged.
      env.RESEND_API_KEY = null;
      env.SMTP_URL = null;
      env.ERAS_MAIL_FROM = null;
      const unconfiguredResult = await emailService.sendWelcomeEmail(
        'asha@example.com',
        'Asha Menon'
      );
      expect(unconfiguredResult).toMatchObject({
        delivered: null,
        deliveryAccepted: false,
        deliveryConfirmed: false,
        deliveryResult: 'unconfigured',
        transport: 'unconfigured',
        provider: 'unconfigured',
        transportConfigured: 'no',
      });

      // 2. Resend configured -> uses the Resend HTTPS API before SMTP fallback.
      const fetchCalls = [];
      global.fetch = jest.fn(async (url, options) => {
        fetchCalls.push({ url, options });
        return {
          ok: true,
          status: 200,
          json: async () => ({ id: 'resend-message-123' }),
        };
      });
      env.RESEND_API_KEY = 're_mock_resend_key';
      env.SMTP_URL = 'smtps://user:pass@smtp.example.org:465';
      env.ERAS_MAIL_FROM = 'verify@eras.example.org';
      nodemailer.createTransport.mockReturnValue({
        sendMail: jest.fn().mockResolvedValue({ accepted: ['asha@example.com'] }),
      });

      const resendResult = await emailService.sendWelcomeEmail(
        'asha@example.com',
        'Asha Menon'
      );
      expect(resendResult).toMatchObject({
        delivered: null,
        deliveryConfirmed: false,
        accepted: true,
        deliveryAccepted: true,
        deliveryResult: 'accepted',
        transport: 'resend',
        provider: 'Resend',
        transportConfigured: 'yes',
        providerResponseStatus: 200,
        messageId: 'resend-message-123',
        fallbackUsed: false,
      });
      expect(fetchCalls).toHaveLength(1);
      expect(fetchCalls[0].url).toBe('https://api.resend.com/emails');
      expect(fetchCalls[0].options.headers.Authorization).toBe('Bearer re_mock_resend_key');
      const sentBody = JSON.parse(fetchCalls[0].options.body);
      expect(sentBody.from).toBe(
        'ERAS (Emergency Resource Allocation System) <verify@eras.example.org>'
      );
      expect(sentBody.to).toEqual(['asha@example.com']);
      expect(sentBody.subject).toBe('Welcome to ERAS — your account is verified');
      expect(sentBody.text).toContain('Welcome to ERAS, Asha.');
      expect(nodemailer.createTransport).not.toHaveBeenCalled();

      // 3. A Resend rejection without SMTP is surfaced as a real failure with
      // safe status/type fields (it cannot silently look like an accepted send).
      env.SMTP_URL = null;
      const failedFetch = jest.fn(async () => ({
        ok: false,
        status: 422,
        json: async () => ({
          name: 'validation_error',
          type: 'sender_rejected',
          message: 'Sender verify@eras.example.org was not accepted.',
        }),
      }));
      global.fetch = failedFetch;
      const rejectedResult = await emailService.sendWelcomeEmail(
        'asha@example.com',
        'Asha Menon'
      );
      expect(rejectedResult).toMatchObject({
        delivered: null,
        deliveryConfirmed: false,
        accepted: false,
        deliveryResult: 'failed',
        transport: 'resend',
        provider: 'Resend',
        providerResponseStatus: 422,
        providerErrorCode: 'validation_error',
        providerErrorType: 'sender_rejected',
      });
      expect(failedFetch).toHaveBeenCalledTimes(1);

      // 4. If Resend rejects the request and SMTP is configured, SMTP receives
      // exactly one fallback attempt.
      env.SMTP_URL = 'smtps://user:pass@smtp.example.org:465';
      const smtpSendMail = jest.fn().mockResolvedValue({
        accepted: ['asha@example.com'],
        responseCode: 250,
        messageId: 'smtp-message-456',
      });
      nodemailer.createTransport.mockReturnValue({ sendMail: smtpSendMail });
      global.fetch = jest.fn(async () => ({
        ok: false,
        status: 422,
        json: async () => ({
          name: 'validation_error',
          message: 'The sender address verify@eras.example.org is not verified for this domain.',
        }),
      }));
      const fallbackResult = await emailService.sendWelcomeEmail(
        'asha@example.com',
        'Asha Menon'
      );
      expect(fallbackResult).toMatchObject({
        delivered: null,
        deliveryConfirmed: false,
        deliveryAccepted: true,
        deliveryResult: 'accepted',
        transport: 'smtp',
        provider: 'SMTP',
        providerResponseStatus: 250,
        messageId: 'smtp-message-456',
        fallbackUsed: true,
      });
      expect(smtpSendMail).toHaveBeenCalledWith(
        expect.objectContaining({
          from: 'ERAS (Emergency Resource Allocation System) <verify@eras.example.org>',
          to: 'asha@example.com',
          subject: 'Welcome to ERAS — your account is verified',
        })
      );

      // 4. SMTP-only mode works with the installed transport dependency.
      env.RESEND_API_KEY = null;
      smtpSendMail.mockResolvedValueOnce({
        accepted: ['asha@example.com'],
        responseCode: 250,
        messageId: 'smtp-only-message',
      });
      const smtpOnlyResult = await emailService.sendWelcomeEmail(
        'asha@example.com',
        'Asha Menon'
      );
      expect(smtpOnlyResult).toMatchObject({
        delivered: null,
        deliveryConfirmed: false,
        deliveryAccepted: true,
        deliveryResult: 'accepted',
        transport: 'smtp',
        provider: 'SMTP',
        fallbackUsed: false,
      });

      // 5. Invalid/missing sender is a safe configuration failure and makes no
      // provider request (the service never invents a local sender address).
      env.SMTP_URL = null;
      env.RESEND_API_KEY = 're_mock_resend_key';
      env.ERAS_MAIL_FROM = null;
      const missingSenderFetch = jest.fn();
      global.fetch = missingSenderFetch;
      const missingFrom = await emailService.sendWelcomeEmail(
        'asha@example.com',
        'Asha Menon'
      );
      expect(missingFrom).toMatchObject({
        delivered: null,
        deliveryConfirmed: false,
        accepted: false,
        deliveryResult: 'failed',
        providerErrorCode: 'ERAS_MAIL_FROM_UNCONFIGURED',
      });
      expect(missingSenderFetch).not.toHaveBeenCalled();
    } finally {
      global.fetch = originalFetch;
    }
  });

  async function prismaUserForTest({ name, email, role = 'REQUESTER' }) {
    const prisma = require('../../src/config/prisma');
    return prisma.user.create({
      data: {
        name,
        email,
        password: await bcrypt.hash('StrongPassword123!', 10),
        role,
        emailVerified: false,
        authProvider: 'PASSWORD',
      },
    });
  }
});
