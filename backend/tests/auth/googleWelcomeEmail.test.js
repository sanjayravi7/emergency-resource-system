process.env.NODE_ENV = 'test';
process.env.DATABASE_URL =
  process.env.DATABASE_URL || 'postgresql://u:p@localhost:5432/db';
process.env.JWT_SECRET =
  process.env.JWT_SECRET || 'S6m2yq0m9k3wq7Zt1v8Xr4Lp6Nc2Bd5Hf8Jk1Mn4Qs7Uw0';

const mockUsers = [];
let mockNextUserId = 1;

jest.mock('../../src/config/prisma', () => {
  const prisma = {
    user: {
      findUnique: jest.fn(async ({ where } = {}) => {
        if (where?.firebaseUid !== undefined) {
          return mockUsers.find((user) => user.firebaseUid === where.firebaseUid) || null;
        }
        if (where?.email !== undefined) {
          return mockUsers.find((user) => user.email === where.email) || null;
        }
        if (where?.id !== undefined) {
          return mockUsers.find((user) => user.id === Number(where.id)) || null;
        }
        return null;
      }),
      create: jest.fn(async ({ data } = {}) => {
        if (mockUsers.some((user) =>
          user.email === data.email || user.firebaseUid === data.firebaseUid,
        )) {
          const error = new Error('Unique constraint failed');
          error.code = 'P2002';
          throw error;
        }
        const created = {
          id: mockNextUserId++,
          name: data.name,
          email: data.email,
          password: data.password,
          phone: data.phone ?? null,
          role: data.role,
          isActive: true,
          lastActiveAt: null,
          responderStatus: 'OFFLINE',
          emailVerified: data.emailVerified,
          emailVerifiedAt: data.emailVerifiedAt,
          welcomeEmailDispatchClaimedAt: data.welcomeEmailDispatchClaimedAt ?? null,
          authProvider: data.authProvider,
          firebaseUid: data.firebaseUid,
          createdAt: new Date(),
          updatedAt: new Date(),
        };
        mockUsers.push(created);
        return created;
      }),
      update: jest.fn(async ({ where, data } = {}) => {
        const user = mockUsers.find((candidate) => candidate.id === Number(where.id));
        if (!user) throw new Error('User not found');
        Object.assign(user, data, { updatedAt: new Date() });
        return user;
      }),
    },
    auditLog: {
      create: jest.fn(async ({ data }) => ({ id: 1, ...data, createdAt: new Date() })),
    },
  };
  return prisma;
});

jest.mock('../../src/services/firebaseTokenService', () => ({
  isGoogleAuthConfigured: jest.fn(() => true),
  verifyIdentityToken: jest.fn(async () => ({
    provider: 'FIREBASE',
    subject: 'google-uid-001',
    email: 'google.new@example.com',
    emailVerified: true,
    name: 'Google New User',
  })),
  IdentityTokenError: class IdentityTokenError extends Error {
    constructor(message, statusCode = 401) {
      super(message);
      this.statusCode = statusCode;
    }
  },
}));

const request = require('supertest');
const app = require('../../src/app');
const prisma = require('../../src/config/prisma');
const firebaseTokenService = require('../../src/services/firebaseTokenService');
const emailService = require('../../src/services/emailService');

describe('Google account welcome email API flow', () => {
  let welcomeSpy;

  beforeEach(() => {
    mockUsers.length = 0;
    mockNextUserId = 1;
    jest.clearAllMocks();
    firebaseTokenService.verifyIdentityToken.mockResolvedValue({
      provider: 'FIREBASE',
      subject: 'google-uid-001',
      email: 'google.new@example.com',
      emailVerified: true,
      name: 'Google New User',
    });
    welcomeSpy = jest.spyOn(emailService, 'sendWelcomeEmail').mockResolvedValue({
      deliveryAccepted: true,
      accepted: true,
      delivered: true,
      deliveryResult: 'accepted',
      transport: 'resend',
      provider: 'Resend',
      transportConfigured: 'yes',
      providerResponseStatus: 202,
      messageId: 'welcome-message-001',
    });
  });

  afterEach(() => {
    jest.restoreAllMocks();
  });

  function signIn() {
    return request(app)
      .post('/api/auth/google')
      .send({ idToken: 'test-google-id-token', role: 'REQUESTER' });
  }

  test('new Google ERAS account is verified and gets one welcome email', async () => {
    const response = await signIn();

    expect(response.status).toBe(200);
    expect(response.body.success).toBe(true);
    expect(response.body.data.isNewUser).toBe(true);
    expect(response.body.data.created).toBe(true);
    expect(response.body.data.user.emailVerified).toBe(true);
    expect(response.body.data.emailVerified).toBe(true);
    expect(response.body.data.verificationRequired).toBe(false);
    expect(response.body.data.welcomeEmailSent).toBe(true);
    expect(response.body.data.emailRequestAccepted).toBe(true);
    expect(response.body.data.emailDeliveryConfirmed).toBe(false);
    expect(response.body.data.welcomeEmailRequestAccepted).toBe(true);
    expect(response.body.data.welcomeEmailDelivered).toBeNull();
    expect(response.body.data.welcomeEmailDeliveryConfirmed).toBe(false);
    expect(response.body.data.welcomeEmailDeliveryStatus).toBe('accepted');
    expect(response.body.data.welcomeEmailDeliveryResult).toBe('accepted');
    expect(response.body.data.welcomeEmailProviderResponseStatus).toBe(202);
    expect(response.body.data.welcomeEmailMessageId).toBe('welcome-message-001');
    expect(response.body.data.token).toEqual(expect.any(String));
    expect(welcomeSpy).toHaveBeenCalledTimes(1);
    expect(welcomeSpy).toHaveBeenCalledWith(
      'google.new@example.com',
      'Google New User',
    );

    const persisted = mockUsers[0];
    expect(persisted.authProvider).toBe('GOOGLE');
    expect(persisted.emailVerifiedAt).toBeInstanceOf(Date);
    expect(persisted.welcomeEmailDispatchClaimedAt).toBeInstanceOf(Date);
    expect(persisted.password).not.toBe('test-google-id-token');
    expect(response.body.data).not.toHaveProperty('password');
  });

  test('parallel first Google sign-ins resolve one durable user and send one welcome', async () => {
    const createImplementation = prisma.user.create.getMockImplementation();
    let createArrivals = 0;
    let releaseCreates;
    const createGate = new Promise((resolve) => {
      releaseCreates = resolve;
    });
    prisma.user.create.mockImplementation(async (args) => {
      createArrivals += 1;
      if (createArrivals === 2) releaseCreates();
      await createGate;
      return createImplementation(args);
    });

    try {
      const [first, second] = await Promise.all([signIn(), signIn()]);

      expect(first.status).toBe(200);
      expect(second.status).toBe(200);
      expect(mockUsers).toHaveLength(1);
      expect([first.body.data.isNewUser, second.body.data.isNewUser]).toEqual([
        expect.any(Boolean),
        expect.any(Boolean),
      ]);
      expect(
        [first.body.data.isNewUser, second.body.data.isNewUser].filter(Boolean),
      ).toHaveLength(1);
      expect(welcomeSpy).toHaveBeenCalledTimes(1);
      expect(mockUsers[0].welcomeEmailDispatchClaimedAt).toBeInstanceOf(Date);
    } finally {
      prisma.user.create.mockImplementation(createImplementation);
    }
  });

  test('Google links a pre-existing ERAS account without sending a new-user welcome', async () => {
    firebaseTokenService.verifyIdentityToken.mockResolvedValueOnce({
      provider: 'FIREBASE',
      subject: 'google-link-uid',
      email: 'linked@example.com',
      emailVerified: true,
      name: 'Linked Google Name',
    });
    mockUsers.push({
      id: 41,
      name: 'Existing ERAS Name',
      email: 'linked@example.com',
      password: '$2b$10$existing-password-hash',
      phone: null,
      role: 'RESPONDER',
      isActive: true,
      lastActiveAt: null,
      responderStatus: 'OFFLINE',
      emailVerified: false,
      emailVerifiedAt: null,
      welcomeEmailDispatchClaimedAt: null,
      authProvider: 'PASSWORD',
      firebaseUid: null,
      createdAt: new Date(),
    });

    const response = await signIn();

    expect(response.status).toBe(200);
    expect(response.body.data.isNewUser).toBe(false);
    expect(response.body.data.linked).toBe(true);
    expect(response.body.data.user.role).toBe('RESPONDER');
    expect(response.body.data.user.emailVerified).toBe(true);
    expect(response.body.data.verificationRequired).toBe(false);
    expect(response.body.data.welcomeEmailSent).toBe(false);
    expect(response.body.data.welcomeEmailDeliveryResult).toBe('not_attempted');
    expect(welcomeSpy).not.toHaveBeenCalled();
    expect(mockUsers).toHaveLength(1);
  });

  test('existing Google user gets a normal session and no duplicate welcome email', async () => {
    const first = await signIn();
    expect(first.status).toBe(200);
    expect(first.body.data.isNewUser).toBe(true);
    expect(welcomeSpy).toHaveBeenCalledTimes(1);

    const second = await signIn();
    expect(second.status).toBe(200);
    expect(second.body.data.isNewUser).toBe(false);
    expect(second.body.data.created).toBe(false);
    expect(second.body.data.emailVerified).toBe(true);
    expect(second.body.data.verificationRequired).toBe(false);
    expect(second.body.data.welcomeEmailSent).toBe(false);
    expect(second.body.data.welcomeEmailRequestAccepted).toBe(false);
    expect(second.body.data.welcomeEmailDelivered).toBeNull();
    expect(second.body.data.welcomeEmailDeliveryResult).toBe('not_attempted');
    expect(welcomeSpy).toHaveBeenCalledTimes(1);
  });

  test('welcome-email provider failure does not fail Google authentication', async () => {
    welcomeSpy.mockResolvedValueOnce({
      deliveryAccepted: false,
      accepted: false,
      delivered: false,
      deliveryResult: 'failed',
      transport: 'resend',
      provider: 'Resend',
      transportConfigured: 'yes',
      providerResponseStatus: 422,
      providerErrorCode: 'validation_error',
      providerErrorType: 'sender_rejected',
    });

    const response = await signIn();

    expect(response.status).toBe(200);
    expect(response.body.success).toBe(true);
    expect(response.body.data.token).toEqual(expect.any(String));
    expect(response.body.data.isNewUser).toBe(true);
    expect(response.body.data.emailVerified).toBe(true);
    expect(response.body.data.welcomeEmailSent).toBe(false);
    expect(response.body.data.welcomeEmailRequestAccepted).toBe(false);
    expect(response.body.data.welcomeEmailDelivered).toBeNull();
    expect(response.body.data.welcomeEmailDeliveryStatus).toBe('failed');
    expect(response.body.data.welcomeEmailDeliveryResult).toBe('failed');
    expect(response.body.data.welcomeEmailProviderResponseStatus).toBe(422);
    expect(response.body.data.welcomeEmailProviderErrorCode).toBe('validation_error');
    expect(mockUsers[0].emailVerified).toBe(true);
    expect(welcomeSpy).toHaveBeenCalledTimes(1);
  });
});
