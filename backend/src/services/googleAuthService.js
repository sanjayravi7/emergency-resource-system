// ---------------------------------------------------------------------------
// GOOGLE REGISTRATION / LOGIN -> ERAS ACCOUNT RESOLUTION
//
// This runs only AFTER firebaseTokenService has cryptographically verified the
// Google/Firebase ID token. Identity therefore comes from Google, while the
// ERAS session (JWT), role, isActive flag and RBAC continue to come from the
// EXISTING backend: a Firebase-authenticated client gets exactly the same
// ERAS token as a password login and can never bypass authorization.
//
// Rules implemented here:
//   * an existing `firebaseUid` resolves to its ERAS user (idempotent login);
//   * a verified Google email that matches an existing ERAS account LINKS to
//     that account (no duplicate users) - the account keeps its own role;
//   * a brand new identity creates a user with role REQUESTER or RESPONDER
//     only. ADMIN can never be created through public Google sign-up;
//   * deactivated accounts are refused (Google sign-in is not a way around an
//     administrative ban);
//   * Google identities are considered email-verified by Google, so they never
//     receive the ERAS verification email;
//   * Google-only accounts receive a random, unguessable password hash, so the
//     password login endpoint can never authenticate them.
// ---------------------------------------------------------------------------

const crypto = require('crypto');
const bcrypt = require('bcrypt');

const prisma = require('../config/prisma');
const logger = require('../config/logger');
const { validateAndNormalizeEmail } = require('../domain/emailValidation');

const SALT_ROUNDS = 10;
const PUBLIC_REGISTRATION_ROLES = ['REQUESTER', 'RESPONDER'];
const MAX_NAME_LENGTH = 120;
const MAX_PHONE_LENGTH = 20;

class GoogleAuthError extends Error {
  constructor(code, message, statusCode = 400) {
    super(message);
    this.name = 'GoogleAuthError';
    this.code = code;
    this.statusCode = statusCode;
  }
}

function normalizePublicRole(role) {
  const normalized = typeof role === 'string' ? role.trim() : '';
  if (!normalized) throw new GoogleAuthError('REGISTRATION_ROLE_REQUIRED', 'Choose how you want to use ERAS', 400);
  if (!PUBLIC_REGISTRATION_ROLES.includes(normalized)) {
    throw new GoogleAuthError('INVALID_REGISTRATION_ROLE', 'Invalid role selection', 400);
  }
  return normalized;
}

function normalizeName(value, fallbackEmail) {
  const candidate = typeof value === 'string' ? value.trim() : '';
  if (candidate) return candidate.slice(0, MAX_NAME_LENGTH);
  const fromEmail = String(fallbackEmail || '').split('@')[0] || '';
  return (fromEmail || 'ERAS user').slice(0, MAX_NAME_LENGTH);
}

function normalizePhone(value) {
  if (value === undefined || value === null) return null;
  if (typeof value !== 'string') throw new GoogleAuthError('INVALID_PHONE', 'Invalid phone number', 400);
  const trimmed = value.trim();
  if (!trimmed) return null;
  if (trimmed.length > MAX_PHONE_LENGTH) throw new GoogleAuthError('INVALID_PHONE', 'Invalid phone number', 400);
  return trimmed;
}

/** Random, non-recoverable password material for Google-only accounts. */
async function randomPasswordHash() {
  return bcrypt.hash(crypto.randomBytes(48).toString('hex'), SALT_ROUNDS);
}

function publicUser(user) {
  return {
    id: user.id,
    name: user.name,
    email: user.email,
    phone: user.phone,
    role: user.role,
    location: user.location,
    latitude: user.latitude,
    longitude: user.longitude,
    isActive: user.isActive,
    lastActiveAt: user.lastActiveAt,
    responderStatus: user.responderStatus,
    emailVerified: user.emailVerified,
    createdAt: user.createdAt,
  };
}

/**
 * Resolve (or create/link) the ERAS user for a VERIFIED Google identity.
 *
 * @param {object} identity  output of firebaseTokenService.verifyIdentityToken
 * @param {object} options   { role, name, phone } from the client (validated)
 * @returns {Promise<{ user: object, created: boolean, linked: boolean }>}
 */
async function resolveUserFromGoogleIdentity(identity, { role, name, phone } = {}) {
  if (!identity || !identity.subject) {
    throw new GoogleAuthError('INVALID_TOKEN', 'Google sign-in could not be verified', 401);
  }
  if (!identity.emailVerified) {
    throw new GoogleAuthError('EMAIL_NOT_VERIFIED', 'Your Google email address is not verified', 403);
  }

  const { email, valid } = validateAndNormalizeEmail(identity.email);
  if (!valid) {
    throw new GoogleAuthError('INVALID_EMAIL', 'Your Google account has no usable email address', 400);
  }

  const firebaseUid = String(identity.subject);
  const displayName = normalizeName(name || identity.name, email);
  const normalizedPhone = normalizePhone(phone);

  // 1. Known Google identity: straight login.
  const linkedByUid = await prisma.user.findUnique({ where: { firebaseUid } });
  if (linkedByUid) {
    if (!linkedByUid.isActive) {
      throw new GoogleAuthError('ACCOUNT_INACTIVE', 'Account is inactive', 403);
    }
    const user = await prisma.user.update({
      where: { id: linkedByUid.id },
      data: {
        lastActiveAt: new Date(),
        // Google may have verified the address after ERAS first saw the
        // account; keep the ERAS verification state truthful.
        ...(linkedByUid.emailVerified ? {} : { emailVerified: true, emailVerifiedAt: new Date() }),
      },
    });
    return { user, created: false, linked: false };
  }

  // 2. Existing ERAS account with the same verified Google email: link it,
  //    never duplicate it. The account's role is untouched.
  const existingByEmail = await prisma.user.findUnique({ where: { email } });
  if (existingByEmail) {
    if (!existingByEmail.isActive) {
      throw new GoogleAuthError('ACCOUNT_INACTIVE', 'Account is inactive', 403);
    }
    const user = await prisma.user.update({
      where: { id: existingByEmail.id },
      data: {
        firebaseUid,
        lastActiveAt: new Date(),
        emailVerified: true,
        emailVerifiedAt: existingByEmail.emailVerifiedAt ?? new Date(),
      },
    });
    logger.info('auth.google_linked', { userId: user.id, provider: identity.provider });
    return { user, created: false, linked: true };
  }

  // 3. Brand new identity: public roles only. ADMIN is rejected by
  //    normalizePublicRole before any write.
  const userRole = normalizePublicRole(role);

  const createdAt = new Date();
  let created;
  try {
    created = await prisma.user.create({
      data: {
        name: displayName,
        email,
        // No plaintext password exists for Google accounts: an unguessable
        // random hash keeps the credential column NOT NULL without ever
        // providing a usable password login.
        password: await randomPasswordHash(),
        phone: normalizedPhone,
        role: userRole,
        authProvider: 'GOOGLE',
        firebaseUid,
        emailVerified: true,
        emailVerifiedAt: createdAt,
        // Persist the one-time dispatch claim with the new account itself. A
        // later Google login (including after a Render restart) sees an existing
        // user and will never send another welcome email.
        welcomeEmailDispatchClaimedAt: createdAt,
      },
    });
  } catch (error) {
    // A parallel first-sign-in may win the unique Firebase UID/email insert.
    // Resolve its persisted row as an ordinary login/link so only the actual
    // creator can trigger a first-account welcome email.
    if (error?.code !== 'P2002') throw error;

    const racedByUid = await prisma.user.findUnique({ where: { firebaseUid } });
    if (racedByUid) {
      if (!racedByUid.isActive) {
        throw new GoogleAuthError('ACCOUNT_INACTIVE', 'Account is inactive', 403);
      }
      const user = await prisma.user.update({
        where: { id: racedByUid.id },
        data: {
          lastActiveAt: new Date(),
          ...(racedByUid.emailVerified
            ? {}
            : { emailVerified: true, emailVerifiedAt: new Date() }),
        },
      });
      return { user, created: false, linked: false };
    }

    const racedByEmail = await prisma.user.findUnique({ where: { email } });
    if (!racedByEmail) throw error;
    if (!racedByEmail.isActive) {
      throw new GoogleAuthError('ACCOUNT_INACTIVE', 'Account is inactive', 403);
    }
    if (racedByEmail.firebaseUid && racedByEmail.firebaseUid !== firebaseUid) {
      throw new GoogleAuthError(
        'IDENTITY_ALREADY_LINKED',
        'This ERAS account is already linked to another Google identity',
        409,
      );
    }
    const user = await prisma.user.update({
      where: { id: racedByEmail.id },
      data: {
        firebaseUid,
        lastActiveAt: new Date(),
        emailVerified: true,
        emailVerifiedAt: racedByEmail.emailVerifiedAt ?? new Date(),
      },
    });
    return { user, created: false, linked: true };
  }

  logger.info('auth.google_registered', { userId: created.id, role: created.role });
  return { user: created, created: true, linked: false };
}

module.exports = {
  PUBLIC_REGISTRATION_ROLES,
  MAX_NAME_LENGTH,
  MAX_PHONE_LENGTH,
  GoogleAuthError,
  normalizePublicRole,
  randomPasswordHash,
  publicUser,
  resolveUserFromGoogleIdentity,
};
