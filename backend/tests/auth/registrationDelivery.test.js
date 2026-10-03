const mockUsers = [];
let mockNextUserId = 1;

jest.mock('../../src/config/prisma', () => ({
  user: {
    findUnique: jest.fn(async ({ where }) => {
      if (where.email) return mockUsers.find((u) => u.email === where.email) || null;
      if (where.id) return mockUsers.find((u) => u.id === where.id) || null;
      return null;
    }),
    create: jest.fn(async ({ data }) => {
      const created = {
        id: mockNextUserId++,
        ...data,
        createdAt: new Date(),
        updatedAt: new Date(),
        isActive: true,
        lastActiveAt: null,
        responderStatus: 'OFFLINE',
      };
      mockUsers.push(created);
      return created;
    }),
  },
}));

jest.mock('../../src/services/emailVerificationService');

const emailVerificationService = require('../../src/services/emailVerificationService');
const authService = require('../../src/services/authService');

describe('Registration email delivery handling', () => {
  beforeEach(() => {
    mockUsers.length = 0;
    mockNextUserId = 1;
    jest.clearAllMocks();
  });

  test('successful registration with delivered email reports emailDelivered: true', async () => {
    emailVerificationService.issueVerificationForUser.mockResolvedValue({
      sent: true,
      delivered: true,
      expiresAt: new Date(Date.now() + 1800000),
    });

    const result = await authService.registerUser({
      name: 'John Doe',
      email: 'john@example.com',
      password: 'StrongPassword123!',
      role: 'REQUESTER',
    });

    expect(result.user.email).toBe('john@example.com');
    expect(result.verificationRequired).toBe(true);
    expect(result.emailDelivered).toBe(true);
    expect(result.user.emailVerified).toBe(false);
  });

  test('successful registration when email delivery fails reports emailDelivered: false without rolling back user', async () => {
    emailVerificationService.issueVerificationForUser.mockResolvedValue({
      sent: true,
      delivered: false,
      reason: 'DELIVERY_FAILED',
    });

    const result = await authService.registerUser({
      name: 'Jane Doe',
      email: 'jane@example.com',
      password: 'StrongPassword123!',
      role: 'RESPONDER',
    });

    // Account creation succeeds
    expect(result.user.email).toBe('jane@example.com');
    expect(result.user.role).toBe('RESPONDER');
    expect(result.verificationRequired).toBe(true);
    // Delivery is reported accurately
    expect(result.emailDelivered).toBe(false);
    expect(result.token).toBeDefined();

    // Verify user actually persisted in database
    expect(mockUsers).toHaveLength(1);
    expect(mockUsers[0].email).toBe('jane@example.com');
  });

  test('delivery exception does not fail account creation', async () => {
    emailVerificationService.issueVerificationForUser.mockRejectedValue(
      new Error('Resend network timeout')
    );

    const result = await authService.registerUser({
      name: 'Bob Smith',
      email: 'bob@example.com',
      password: 'StrongPassword123!',
      role: 'REQUESTER',
    });

    expect(result.user.email).toBe('bob@example.com');
    expect(result.emailDelivered).toBe(false);
    expect(mockUsers).toHaveLength(1);
  });
});
