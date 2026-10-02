const request = require('supertest');
const bcrypt = require('bcrypt');

const app = require('../../src/app');
const prisma = require('../../src/config/prisma');
const firebaseAdmin = require('../../src/config/firebaseAdmin');
const authEmailService = require('../../src/services/authEmailService');

const stamp = `${Date.now()}_${Math.floor(Math.random() * 10000)}`;
const localEmail = `local_${stamp}@eras.test`;
const googleEmail = `google_${stamp}@eras.test`;
const linkedEmail = `linked_${stamp}@eras.test`;
const missingGoogleEmail = `missing_${stamp}@eras.test`;
const existingPassword = 'ExistingPass123';
const resetPassword = 'ResetPass456';

const claimsByToken = new Map([
  ['google-token-register', {
    uid: `firebase_uid_${stamp}`,
    email: googleEmail,
    email_verified: true,
    name: 'Google ERAS User',
    firebase: { sign_in_provider: 'google.com' },
  }],
  ['google-token-login', {
    uid: `firebase_uid_${stamp}`,
    email: googleEmail,
    email_verified: true,
    name: 'Google ERAS User',
    firebase: { sign_in_provider: 'google.com' },
  }],
  ['google-token-link', {
    uid: `firebase_linked_uid_${stamp}`,
    email: linkedEmail,
    email_verified: true,
    name: 'Linked Google User',
    firebase: { sign_in_provider: 'google.com' },
  }],
  ['google-token-unverified', {
    uid: `firebase_unverified_${stamp}`,
    email: `not_verified_${stamp}@eras.test`,
    email_verified: false,
    name: 'Unverified',
    firebase: { sign_in_provider: 'google.com' },
  }],
  ['google-token-wrong-provider', {
    uid: `firebase_wrong_provider_${stamp}`,
    email: `wrong_provider_${stamp}@eras.test`,
    email_verified: true,
    name: 'Wrong Provider',
    firebase: { sign_in_provider: 'password' },
  }],
  ['google-token-no-account', {
    uid: `firebase_missing_${stamp}`,
    email: missingGoogleEmail,
    email_verified: true,
    name: 'Missing ERAS Account',
    firebase: { sign_in_provider: 'google.com' },
  }],
]);

beforeAll(() => {
  firebaseAdmin.setGoogleTokenVerifierForTests(async (token) => {
    const claims = claimsByToken.get(token);
    if (!claims) throw new Error('invalid token');
    return claims;
  });
});

afterAll(async () => {
  firebaseAdmin.resetFirebaseAdminForTests();
  await prisma.user.deleteMany({
    where: {
      email: {
        in: [
          localEmail,
          googleEmail,
          linkedEmail,
          missingGoogleEmail,
          `not_verified_${stamp}@eras.test`,
          `wrong_provider_${stamp}@eras.test`,
        ],
      },
    },
  });
  authEmailService.clearTestCodesForTests();
  await prisma.$disconnect();
});

describe('email verification and six-digit password reset', () => {
  test('requires first-time email verification, then supports a one-time six-digit reset', async () => {
    const registration = await request(app)
      .post('/api/auth/register')
      .send({
        name: 'Local Auth Test',
        email: localEmail,
        password: existingPassword,
        role: 'REQUESTER',
      });

    expect(registration.statusCode).toBe(201);
    expect(registration.body.data.user.emailVerified).toBe(false);
    expect(registration.body.data.verificationRequired).toBe(true);
    expect(registration.body.data.token).toBeUndefined();

    const storedUser = await prisma.user.findUnique({ where: { email: localEmail } });
    expect(storedUser.emailVerified).toBe(false);

    const verificationCode = authEmailService.getTestCodeForTests(
      localEmail,
      'EMAIL_VERIFICATION'
    );
    expect(verificationCode).toMatch(/^\d{6}$/);

    const challenge = await prisma.authChallenge.findFirst({
      where: { userId: storedUser.id, purpose: 'EMAIL_VERIFICATION' },
    });
    expect(challenge.codeHash).toHaveLength(64);
    expect(challenge.codeHash).not.toBe(verificationCode);

    const earlyLogin = await request(app)
      .post('/api/auth/login')
      .send({ email: localEmail, password: existingPassword });
    expect(earlyLogin.statusCode).toBe(403);
    expect(earlyLogin.body.message).toMatch(/verify your email/i);

    const wrongCode = verificationCode === '000000' ? '000001' : '000000';
    const rejectedCode = await request(app)
      .post('/api/auth/verify-email')
      .send({ email: localEmail, code: wrongCode });
    expect(rejectedCode.statusCode).toBe(400);

    const verified = await request(app)
      .post('/api/auth/verify-email')
      .send({ email: localEmail, code: verificationCode });
    expect(verified.statusCode).toBe(200);
    expect(verified.body.data.emailVerified).toBe(true);

    const emailPasswordLogin = await request(app)
      .post('/api/auth/login')
      .send({ email: localEmail, password: existingPassword });
    expect(emailPasswordLogin.statusCode).toBe(200);
    expect(emailPasswordLogin.body.data.token).toBeDefined();

    const resetRequest = await request(app)
      .post('/api/auth/password-reset/request')
      .send({ email: localEmail });
    const unknownResetRequest = await request(app)
      .post('/api/auth/password-reset/request')
      .send({ email: `unknown_${stamp}@eras.test` });
    expect(resetRequest.statusCode).toBe(200);
    expect(unknownResetRequest.statusCode).toBe(200);
    expect(resetRequest.body.message).toBe(unknownResetRequest.body.message);

    const resetCode = authEmailService.getTestCodeForTests(localEmail, 'PASSWORD_RESET');
    expect(resetCode).toMatch(/^\d{6}$/);

    const badReset = await request(app)
      .post('/api/auth/password-reset/confirm')
      .send({ email: localEmail, code: wrongCode, password: resetPassword });
    expect(badReset.statusCode).toBe(400);

    const completedReset = await request(app)
      .post('/api/auth/password-reset/confirm')
      .send({ email: localEmail, code: resetCode, password: resetPassword });
    expect(completedReset.statusCode).toBe(200);

    const oldPasswordLogin = await request(app)
      .post('/api/auth/login')
      .send({ email: localEmail, password: existingPassword });
    expect(oldPasswordLogin.statusCode).toBe(401);

    const newPasswordLogin = await request(app)
      .post('/api/auth/login')
      .send({ email: localEmail, password: resetPassword });
    expect(newPasswordLogin.statusCode).toBe(200);

    const replayedCode = await request(app)
      .post('/api/auth/password-reset/confirm')
      .send({ email: localEmail, code: resetCode, password: 'AnotherPass789' });
    expect(replayedCode.statusCode).toBe(400);
  });
});

describe('Firebase Google identity bridge', () => {
  test('registration and login create/use a local ERAS user and existing ERAS JWT', async () => {
    const registration = await request(app)
      .post('/api/auth/google')
      .send({ idToken: 'google-token-register', intent: 'register', role: 'RESPONDER' });

    expect(registration.statusCode).toBe(201);
    expect(registration.body.data.user.email).toBe(googleEmail);
    expect(registration.body.data.user.emailVerified).toBe(true);
    expect(registration.body.data.user.role).toBe('RESPONDER');
    expect(registration.body.data.token).toBeDefined();

    const login = await request(app)
      .post('/api/auth/google')
      .send({ idToken: 'google-token-login', intent: 'login' });
    expect(login.statusCode).toBe(200);
    expect(login.body.data.user.id).toBe(registration.body.data.user.id);
    expect(login.body.data.user.role).toBe('RESPONDER');
    expect(login.body.data.token).toBeDefined();

    const users = await prisma.user.findMany({ where: { email: googleEmail } });
    expect(users).toHaveLength(1);
  });

  test('does not silently link a Google identity to an existing password account', async () => {
    const passwordHash = await bcrypt.hash(existingPassword, 10);
    const localUser = await prisma.user.create({
      data: {
        name: 'Existing Responder',
        email: linkedEmail,
        password: passwordHash,
        role: 'RESPONDER',
        emailVerified: false,
      },
    });

    const response = await request(app)
      .post('/api/auth/google')
      .send({ idToken: 'google-token-link', intent: 'login' });

    expect(response.statusCode).toBe(409);
    expect(response.body.message).toMatch(/password account/i);

    const saved = await prisma.user.findUnique({ where: { id: localUser.id } });
    expect(saved.firebaseUid).toBeNull();
    expect(saved.role).toBe('RESPONDER');
    expect(saved.emailVerified).toBe(false);
  });

  test('rejects unverified, non-Google, and unregistered login identities', async () => {
    const unverified = await request(app)
      .post('/api/auth/google')
      .send({ idToken: 'google-token-unverified', intent: 'login' });
    expect(unverified.statusCode).toBe(401);

    const wrongProvider = await request(app)
      .post('/api/auth/google')
      .send({ idToken: 'google-token-wrong-provider', intent: 'login' });
    expect(wrongProvider.statusCode).toBe(401);

    const missingAccount = await request(app)
      .post('/api/auth/google')
      .send({ idToken: 'google-token-no-account', intent: 'login' });
    expect(missingAccount.statusCode).toBe(404);
  });
});
