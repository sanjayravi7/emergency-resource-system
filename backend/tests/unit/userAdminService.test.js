jest.mock('../../src/config/prisma', () => ({
  user: {
    findMany: jest.fn(),
    findUnique: jest.fn(),
    update: jest.fn(),
    delete: jest.fn(),
    count: jest.fn(),
  },
  $transaction: jest.fn(),
}));

// ADMIN USER MANAGEMENT (unit level, PostgreSQL mocked).
//
// Rules locked down here:
//   * an ADMIN may correct a name/phone but never an email, role or active
//     flag through the profile endpoint;
//   * an account with emergency/assignment/allocation/inventory history is
//     NEVER deleted - it must be deactivated instead;
//   * ERAS can never lose its last active ADMIN;
//   * nobody deletes or demotes their own account;
//   * any authenticated user may correct their OWN name/phone.

const userAdminService = require('../../src/services/userAdminService');
const prisma = require('../../src/config/prisma');

const cleanUser = (overrides = {}) => ({
  id: 8,
  name: 'ravi',
  email: 'indexceramic2018@gmail.com',
  phone: null,
  role: 'RESPONDER',
  isActive: true,
  lastActiveAt: null,
  responderStatus: 'OFFLINE',
  emailVerified: true,
  createdAt: new Date('2026-01-01T00:00:00.000Z'),
  updatedAt: new Date('2026-01-02T00:00:00.000Z'),
  _count: {
    requests: 0,
    acceptedRequests: 0,
    responderAssignments: 0,
    allocations: 0,
    responderResources: 0,
    responderHelpTypes: 0,
  },
  ...overrides,
});

const withHistory = (overrides = {}) =>
  cleanUser({
    _count: {
      requests: 2,
      acceptedRequests: 0,
      responderAssignments: 3,
      allocations: 1,
      responderResources: 0,
      responderHelpTypes: 2,
    },
    ...overrides,
  });

describe('profilePatch validation', () => {
  test('accepts a name and a phone number', () => {
    expect(userAdminService.profilePatch({ name: 'Ravi Kumar', phone: '+91 90000 00000' })).toEqual({
      name: 'Ravi Kumar',
      phone: '+91 90000 00000',
    });
  });

  test('collapses whitespace and keeps a name bounded', () => {
    const patch = userAdminService.profilePatch({ name: '  Ravi   Kumar  ' });
    expect(patch.name).toBe('Ravi Kumar');
    expect(() =>
      userAdminService.profilePatch({ name: 'x'.repeat(userAdminService.MAX_NAME_LENGTH + 1) })
    ).toThrow(/120 characters or fewer/);
  });

  test('an empty phone clears the field, an absent one changes nothing', () => {
    expect(userAdminService.profilePatch({ phone: '   ' })).toEqual({ phone: null });
    expect(userAdminService.profilePatch({ name: 'Only name' })).toEqual({ name: 'Only name' });
  });

  test('rejects an empty or non-string name', () => {
    expect(() => userAdminService.profilePatch({ name: '   ' })).toThrow(/valid name/);
    expect(() => userAdminService.profilePatch({ name: 42 })).toThrow(/valid name/);
  });

  test('refuses identity and authorization fields instead of ignoring them', () => {
    for (const field of ['email', 'role', 'isActive', 'password']) {
      expect(() => userAdminService.profilePatch({ [field]: 'ADMIN' })).toThrow(
        /cannot be changed here/
      );
    }
  });

  test('refuses unknown fields and empty bodies', () => {
    expect(() => userAdminService.profilePatch({ nickname: 'ravi' })).toThrow(/not editable/);
    expect(() => userAdminService.profilePatch({})).toThrow(/No profile fields/);
    expect(() => userAdminService.profilePatch(null)).toThrow(/No profile fields/);
  });
});

describe('updateUserProfile (ADMIN edits another account)', () => {
  beforeEach(() => {
    prisma.user.findUnique.mockResolvedValue(cleanUser());
    prisma.user.update.mockImplementation(({ data }) =>
      Promise.resolve(cleanUser({ ...data }))
    );
  });

  test('a display name can be corrected without touching the email', async () => {
    const user = await userAdminService.updateUserProfile(8, { name: 'Ravi Kumar' });

    expect(prisma.user.update).toHaveBeenCalledWith(
      expect.objectContaining({ data: { name: 'Ravi Kumar' } })
    );
    expect(user.name).toBe('Ravi Kumar');
    expect(user.email).toBe('indexceramic2018@gmail.com');
    expect(user.history.deletable).toBe(true);
  });

  test('history is reported so the UI knows deletion is safe', async () => {
    prisma.user.findUnique.mockResolvedValue(withHistory());
    prisma.user.update.mockResolvedValue(withHistory());

    const user = await userAdminService.updateUserProfile(8, { name: 'Ravi Kumar' });

    expect(user.history).toEqual(
      expect.objectContaining({
        requests: 2,
        responderAssignments: 3,
        allocations: 1,
        responderHelpTypes: 2,
        deletable: false,
      })
    );
  });

  test('an unknown user id is a clean 404, not a database error', async () => {
    prisma.user.findUnique.mockResolvedValue(null);

    await expect(userAdminService.updateUserProfile(999, { name: 'X' })).rejects.toMatchObject({
      code: 'USER_NOT_FOUND',
      statusCode: 404,
    });
  });
});

describe('updateOwnProfile (self service)', () => {
  test('any authenticated user may edit their own name', async () => {
    prisma.user.update.mockResolvedValue(cleanUser({ name: 'Ravi Kumar' }));

    const user = await userAdminService.updateOwnProfile(8, { name: 'Ravi Kumar' });

    expect(prisma.user.update).toHaveBeenCalledWith(
      expect.objectContaining({
        where: { id: 8 },
        data: { name: 'Ravi Kumar' },
      })
    );
    expect(user.name).toBe('Ravi Kumar');
  });

  test('the same guard refuses an email change', async () => {
    await expect(
      userAdminService.updateOwnProfile(8, { email: 'other@example.com' })
    ).rejects.toMatchObject({ code: 'FIELD_NOT_EDITABLE' });
    expect(prisma.user.update).not.toHaveBeenCalled();
  });
});

describe('deleteUser safety', () => {
  const transactionContext = {
    user: {
      findUnique: jest.fn(),
      delete: jest.fn(),
    },
  };

  beforeEach(() => {
    prisma.$transaction.mockImplementation((callback) => callback(transactionContext));
  });

  test('deletes an account with no history', async () => {
    prisma.user.findUnique.mockResolvedValue(cleanUser());
    prisma.user.count.mockResolvedValue(2);
    transactionContext.user.findUnique.mockResolvedValue(cleanUser());
    transactionContext.user.delete.mockResolvedValue(cleanUser());

    const removed = await userAdminService.deleteUser(8, 1);

    expect(transactionContext.user.delete).toHaveBeenCalledWith({ where: { id: 8 } });
    expect(removed.id).toBe(8);
    expect(removed.email).toBe('indexceramic2018@gmail.com');
  });

  test('REFUSES to delete an account that carries emergency history', async () => {
    prisma.user.findUnique.mockResolvedValue(withHistory());

    await expect(userAdminService.deleteUser(8, 1)).rejects.toMatchObject({
      code: 'USER_HAS_HISTORY',
      statusCode: 409,
    });
    expect(prisma.$transaction).not.toHaveBeenCalled();
    expect(transactionContext.user.delete).not.toHaveBeenCalled();
  });

  test('the refusal names the history and points at deactivation', async () => {
    prisma.user.findUnique.mockResolvedValue(withHistory());

    await expect(userAdminService.deleteUser(8, 1)).rejects.toThrow(
      /emergency requests.*Deactivate it instead/
    );
  });

  test('refuses to delete the signed-in administrator’s own account', async () => {
    prisma.user.findUnique.mockResolvedValue(cleanUser({ role: 'ADMIN' }));

    await expect(userAdminService.deleteUser(8, 8)).rejects.toMatchObject({
      code: 'CANNOT_DELETE_SELF',
    });
    expect(prisma.$transaction).not.toHaveBeenCalled();
  });

  test('refuses to delete the last active administrator', async () => {
    prisma.user.findUnique.mockResolvedValue(cleanUser({ role: 'ADMIN' }));
    prisma.user.count.mockResolvedValue(1);

    await expect(userAdminService.deleteUser(8, 1)).rejects.toMatchObject({
      code: 'LAST_ADMIN',
    });
    expect(prisma.$transaction).not.toHaveBeenCalled();
  });

  test('re-checks history inside the transaction before deleting', async () => {
    prisma.user.findUnique.mockResolvedValue(cleanUser());
    prisma.user.count.mockResolvedValue(2);
    // A request was created between the count and the delete.
    transactionContext.user.findUnique.mockResolvedValue(withHistory());

    await expect(userAdminService.deleteUser(8, 1)).rejects.toMatchObject({
      code: 'USER_HAS_HISTORY',
    });
    expect(transactionContext.user.delete).not.toHaveBeenCalled();
  });
});

describe('history helpers', () => {
  test('isDeletable is false as soon as one relationship exists', () => {
    expect(userAdminService.isDeletable(cleanUser())).toBe(true);
    expect(userAdminService.isDeletable(withHistory())).toBe(false);
  });

  test('historicalCounts ignores auth codes and device tokens', () => {
    const { total } = userAdminService.historicalCounts(cleanUser());
    expect(total).toBe(0);
  });
});
