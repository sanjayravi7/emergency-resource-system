// ---------------------------------------------------------------------------
// ADMIN USER MANAGEMENT
//
// One place for the operations an ADMIN is allowed to perform on an ERAS
// account, and - more importantly - for the operations it must NEVER perform:
//
//   * an ADMIN may correct another account's display name and phone number,
//     because operators routinely receive "ravi", "ravi test" or a stale phone
//     number and need to fix the label without touching identity;
//   * an ADMIN may NEVER rewrite an email address here. The address is the
//     login identity (password login, OTP, password reset, Google/Firebase
//     linking) and changing it silently would orphan sessions and let one
//     account take over another's verified address;
//   * an account may be DELETED only when it carries no operational history
//     at all (no emergency it requested, no emergency it accepted, no
//     assignment, no allocation, no responder inventory/eligibility rows).
//     Anything else must be DEACTIVATED instead, which keeps every historical
//     row intact while removing access;
//   * ERAS can never lose its last active ADMIN, and nobody may delete or
//     demote their own account - an operator must not be able to lock
//     themselves (or everyone) out.
//
// Every write is audited through the existing append-only audit trail.
// ---------------------------------------------------------------------------

const prisma = require('../config/prisma');

/** Same bounds the public registration/Google paths already enforce. */
const MAX_NAME_LENGTH = 120;
const MAX_PHONE_LENGTH = 20;

/** Fields an ADMIN (or the account owner) may correct on a profile. */
const EDITABLE_PROFILE_FIELDS = ['name', 'phone'];

/** Columns that are identity/authorization and must never be written here. */
const PROTECTED_PROFILE_FIELDS = ['email', 'role', 'isActive', 'password'];

class UserAdminError extends Error {
  constructor(code, message, statusCode = 400) {
    super(message);
    this.name = 'UserAdminError';
    this.code = code;
    this.statusCode = statusCode;
  }
}

const USER_SELECT = {
  id: true,
  name: true,
  email: true,
  phone: true,
  role: true,
  isActive: true,
  lastActiveAt: true,
  responderStatus: true,
  emailVerified: true,
  createdAt: true,
  updatedAt: true,
};

/**
 * Relationship counters that decide whether an account may be deleted.
 * `authCodes` / `deviceTokens` are intentionally excluded: they cascade with
 * the account and carry no operational history.
 */
const RELATION_COUNTS = {
  requests: true, // emergencies this account requested
  acceptedRequests: true, // emergencies this account accepted as lead
  responderAssignments: true, // participation rows on an emergency
  allocations: true, // reserved/dispatched/delivered inventory
  responderResources: true, // inventory held by this responder
  responderHelpTypes: true, // eligibility rows
};

const USER_SELECT_WITH_COUNTS = {
  ...USER_SELECT,
  _count: { select: RELATION_COUNTS },
};

/** Human labels for the counters, used in the refusal message. */
const RELATION_LABELS = {
  requests: 'emergency requests',
  acceptedRequests: 'accepted emergencies',
  responderAssignments: 'responder assignments',
  allocations: 'allocations',
  responderResources: 'inventory rows',
  responderHelpTypes: 'help-type rows',
};

function positiveInteger(value) {
  const number = Number(value);
  return Number.isInteger(number) && number > 0 ? number : null;
}

function normalizeName(value) {
  if (typeof value !== 'string') {
    throw new UserAdminError('INVALID_NAME', 'A valid name is required');
  }
  const name = value.trim().replace(/\s+/g, ' ');
  if (!name) {
    throw new UserAdminError('INVALID_NAME', 'A valid name is required');
  }
  if (name.length > MAX_NAME_LENGTH) {
    throw new UserAdminError(
      'INVALID_NAME',
      `Name must be ${MAX_NAME_LENGTH} characters or fewer`
    );
  }
  return name;
}

function normalizePhone(value) {
  if (value === undefined || value === null) return undefined; // "not supplied"
  if (typeof value !== 'string') {
    throw new UserAdminError('INVALID_PHONE', 'Invalid phone number');
  }
  const phone = value.trim();
  if (!phone) return null; // an explicitly empty value clears the field
  if (phone.length > MAX_PHONE_LENGTH) {
    throw new UserAdminError('INVALID_PHONE', 'Invalid phone number');
  }
  return phone;
}

/**
 * Build the `{ name, phone }` patch for a profile edit.
 *
 * Unknown keys are rejected instead of being ignored silently, so a client
 * cannot smuggle `role`, `email` or `isActive` into this endpoint and believe
 * it worked.
 */
function profilePatch(body) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) {
    throw new UserAdminError('INVALID_BODY', 'No profile fields were supplied');
  }

  for (const field of Object.keys(body)) {
    if (PROTECTED_PROFILE_FIELDS.includes(field)) {
      throw new UserAdminError(
        'FIELD_NOT_EDITABLE',
        `${field} cannot be changed here`
      );
    }
    if (!EDITABLE_PROFILE_FIELDS.includes(field)) {
      throw new UserAdminError('FIELD_NOT_EDITABLE', `${field} is not editable`);
    }
  }

  const patch = {};
  if ('name' in body) patch.name = normalizeName(body.name);
  const phone = normalizePhone(body.phone);
  if (phone !== undefined) patch.phone = phone;

  if (Object.keys(patch).length === 0) {
    throw new UserAdminError('INVALID_BODY', 'No profile fields were supplied');
  }
  return patch;
}

/** The counters that make an account part of ERAS history. */
function historicalCounts(user) {
  const counts = user?._count || {};
  const present = {};
  let total = 0;
  for (const field of Object.keys(RELATION_COUNTS)) {
    const value = Number(counts[field] || 0);
    present[field] = value;
    total += value;
  }
  return { counts: present, total };
}

/** True when the account can be deleted without destroying history. */
function isDeletable(user) {
  return historicalCounts(user).total === 0;
}

/** Adds the derived `history` block the admin surface consumes. */
function withHistory(user) {
  if (!user) return user;
  const { _count, ...rest } = user;
  const { counts, total } = historicalCounts(user);
  return {
    ...rest,
    history: { ...counts, total, deletable: total === 0 },
  };
}

/** Number of administrators that are currently active. */
async function countActiveAdmins(tx = prisma) {
  return tx.user.count({ where: { role: 'ADMIN', isActive: true } });
}

/**
 * ADMIN view of every account, including whether deletion is safe.
 */
async function listUsers() {
  const users = await prisma.user.findMany({
    select: USER_SELECT_WITH_COUNTS,
    orderBy: { id: 'asc' },
  });
  return users.map(withHistory);
}

async function findUserOrFail(id) {
  const userId = positiveInteger(id);
  if (!userId) throw new UserAdminError('INVALID_USER_ID', 'Invalid user id');

  const user = await prisma.user.findUnique({
    where: { id: userId },
    select: USER_SELECT_WITH_COUNTS,
  });
  if (!user) throw new UserAdminError('USER_NOT_FOUND', 'User not found', 404);
  return user;
}

/**
 * Correct another account's display name / phone number (ADMIN only).
 *
 * The email address, the role and the active flag are never written by this
 * path: each of them has its own guarded endpoint.
 */
async function updateUserProfile(targetId, body) {
  const patch = profilePatch(body);
  const target = await findUserOrFail(targetId);

  const user = await prisma.user.update({
    where: { id: target.id },
    data: patch,
    select: USER_SELECT_WITH_COUNTS,
  });
  return withHistory(user);
}

/** Self-service: any authenticated account may correct its own name/phone. */
async function updateOwnProfile(userId, body) {
  const patch = profilePatch(body);
  const userIdOrNull = positiveInteger(userId);
  if (!userIdOrNull) {
    throw new UserAdminError('INVALID_USER_ID', 'Invalid user id');
  }

  const user = await prisma.user.update({
    where: { id: userIdOrNull },
    data: patch,
    select: USER_SELECT_WITH_COUNTS,
  });
  return withHistory(user);
}

/**
 * Deletes an account ONLY when it carries no operational history.
 *
 * PostgreSQL would already refuse most of these deletes (the required
 * relations are restrictive), but counting first keeps the refusal honest and
 * readable, and covers the relations that cascade (inventory, help types).
 */
async function deleteUser(targetId, actorId) {
  const target = await findUserOrFail(targetId);
  const actorUserId = positiveInteger(actorId);

  if (actorUserId && target.id === actorUserId) {
    throw new UserAdminError(
      'CANNOT_DELETE_SELF',
      'You cannot delete your own account'
    );
  }

  if (target.role === 'ADMIN') {
    const admins = await countActiveAdmins();
    if (admins <= 1) {
      throw new UserAdminError(
        'LAST_ADMIN',
        'At least one active administrator account must remain'
      );
    }
  }

  const { counts, total } = historicalCounts(target);
  if (total > 0) {
    const summary = Object.entries(counts)
      .filter(([, value]) => value > 0)
      .map(([field, value]) => `${value} ${RELATION_LABELS[field] || field}`)
      .join(', ');
    // The account is NOT deleted: history always wins over cosmetics. The
    // caller is told exactly how to proceed instead.
    throw new UserAdminError(
      'USER_HAS_HISTORY',
      `This account cannot be deleted because it is linked to ${summary}. ` +
        'Deactivate it instead so the emergency and allocation history is preserved.',
      409
    );
  }

  const deleted = await prisma.$transaction(async (tx) => {
    // Re-check inside the transaction: a request created between the count and
    // the delete must never be silently destroyed.
    const fresh = await tx.user.findUnique({
      where: { id: target.id },
      select: USER_SELECT_WITH_COUNTS,
    });
    if (!fresh) return null;
    if (historicalCounts(fresh).total > 0) {
      throw new UserAdminError(
        'USER_HAS_HISTORY',
        'This account gained emergency history while the deletion was being processed. Nothing was deleted.',
        409
      );
    }
    await tx.user.delete({ where: { id: target.id } });
    return fresh;
  });

  if (!deleted) throw new UserAdminError('USER_NOT_FOUND', 'User not found', 404);

  return {
    id: deleted.id,
    email: deleted.email,
    name: deleted.name,
    role: deleted.role,
    deletedAt: new Date(),
  };
}

module.exports = {
  MAX_NAME_LENGTH,
  MAX_PHONE_LENGTH,
  EDITABLE_PROFILE_FIELDS,
  PROTECTED_PROFILE_FIELDS,
  RELATION_LABELS,
  UserAdminError,
  profilePatch,
  historicalCounts,
  isDeletable,
  withHistory,
  countActiveAdmins,
  listUsers,
  findUserOrFail,
  updateUserProfile,
  updateOwnProfile,
  deleteUser,
};
