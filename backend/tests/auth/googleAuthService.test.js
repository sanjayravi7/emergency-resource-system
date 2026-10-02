jest.mock('../../src/config/prisma', () => ({
  user: {
    findUnique: jest.fn(),
    update: jest.fn(),
    create: jest.fn(),
  },
}));

const prisma = require('../../src/config/prisma');
const googleAuthService = require('../../src/services/googleAuthService');

describe('googleAuthService account resolution', () => {
  beforeEach(() => {
    jest.resetAllMocks();
  });

  const identity = {
    subject: 'firebase-uid-123',
    email: 'CaseSensitive@example.com',
    emailVerified: true,
    name: 'Google User',
    provider: 'firebase',
  };

  test('logs in an already-linked Firebase identity', async () => {
    const existingUser = {
      id: 42,
      email: 'casesensitive@example.com',
      role: 'RESPONDER',
      isActive: true,
      emailVerified: true,
    };
    const updatedUser = { ...existingUser, lastActiveAt: new Date() };
    prisma.user.findUnique.mockResolvedValue(existingUser);
    prisma.user.update.mockResolvedValue(updatedUser);

    const result = await googleAuthService.resolveUserFromGoogleIdentity(identity);

    expect(prisma.user.findUnique).toHaveBeenCalledWith({
      where: { firebaseUid: identity.subject },
    });
    expect(prisma.user.update).toHaveBeenCalledWith({
      where: { id: existingUser.id },
      data: expect.objectContaining({ lastActiveAt: expect.any(Date) }),
    });
    expect(result).toEqual({ user: updatedUser, created: false, linked: false });
    expect(prisma.user.create).not.toHaveBeenCalled();
  });

  test('links a verified matching email without changing the ERAS role', async () => {
    const existingPasswordAccount = {
      id: 7,
      email: 'casesensitive@example.com',
      role: 'REQUESTER',
      isActive: true,
      authProvider: 'PASSWORD',
      firebaseUid: null,
      password: 'existing-bcrypt-hash',
      emailVerified: false,
      emailVerifiedAt: null,
    };
    const linkedUser = {
      ...existingPasswordAccount,
      firebaseUid: identity.subject,
      emailVerified: true,
    };
    prisma.user.findUnique
      .mockResolvedValueOnce(null)
      .mockResolvedValueOnce(existingPasswordAccount);
    prisma.user.update.mockResolvedValue(linkedUser);

    const result = await googleAuthService.resolveUserFromGoogleIdentity(
      identity,
      { role: 'RESPONDER' }
    );

    expect(prisma.user.findUnique).toHaveBeenNthCalledWith(2, {
      where: { email: 'casesensitive@example.com' },
    });
    expect(prisma.user.update).toHaveBeenCalledWith({
      where: { id: existingPasswordAccount.id },
      data: expect.objectContaining({
        firebaseUid: identity.subject,
        emailVerified: true,
        lastActiveAt: expect.any(Date),
      }),
    });
    expect(prisma.user.update.mock.calls[0][0].data).not.toHaveProperty('role');
    expect(prisma.user.update.mock.calls[0][0].data).not.toHaveProperty('password');
    expect(linkedUser.password).toBe(existingPasswordAccount.password);
    expect(result).toEqual({ user: linkedUser, created: false, linked: true });
    expect(prisma.user.create).not.toHaveBeenCalled();
  });

  test('creates a new Google account only for an allowed public role', async () => {
    const createdUser = {
      id: 99,
      email: 'new.user@example.com',
      role: 'RESPONDER',
      isActive: true,
    };
    prisma.user.findUnique.mockResolvedValue(null);
    prisma.user.create.mockResolvedValue(createdUser);

    const result = await googleAuthService.resolveUserFromGoogleIdentity(
      { ...identity, email: 'new.user@example.com' },
      { role: 'RESPONDER' }
    );

    expect(prisma.user.create).toHaveBeenCalledWith({
      data: expect.objectContaining({
        email: 'new.user@example.com',
        role: 'RESPONDER',
        authProvider: 'GOOGLE',
        firebaseUid: identity.subject,
        emailVerified: true,
      }),
    });
    expect(result).toEqual({ user: createdUser, created: true, linked: false });
  });
});
