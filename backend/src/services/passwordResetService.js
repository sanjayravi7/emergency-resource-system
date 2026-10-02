// ---------------------------------------------------------------------------
// PASSWORD RESET (6-digit email code)
//
//   FORGOT PASSWORD -> email -> ERAS emails a 6-digit code -> code verified ->
//   new password (+ confirmation) -> password updated -> existing sessions
//   invalidated -> back to login.
//
// The whole flow is backend/auth based, so it works identically on web and
// Android (the APK talks to the same endpoints; there is no platform-specific
// reset logic).
//
// Security:
//   * no plaintext code in PostgreSQL (bcrypt hash, short TTL, single use,
//     attempt limited, rate limited, resend cooldown - see authCodeService);
//   * account enumeration is impossible: the request endpoint always answers
//     with the same generic message and performs comparable work either way;
//   * never logs the code, the password or provider credentials;
//   * a successful reset rotates the credential and stamps passwordChangedAt,
//     which invalidates every previously issued ERAS JWT.
// ---------------------------------------------------------------------------

const bcrypt = require('bcrypt');

const prisma = require('../config/prisma');
const logger = require('../config/logger');
const env = require('../config/env');
const emailService = require('./emailService');
const authCodeService = require('./authCodeService');
const { normalizeEmail, isValidEmail } = require('../domain/emailValidation');

const PURPOSE = authCodeService.PURPOSES.PASSWORD_RESET;
const SALT_ROUNDS = 10;
const MIN_PASSWORD_LENGTH = 6;
const MAX_PASSWORD_LENGTH = 128;

// Generic answer used for every request outcome (existing / unknown account).
const GENERIC_REQUEST_MESSAGE =
  'If an ERAS account exists for that email address, a reset code has been sent.';

// Same messages for every verification outcome so nothing distinguishes an
// unknown account from a wrong code.
const GENERIC_CODE_ERROR = 'The reset code is invalid or has expired';

class PasswordResetError extends Error {
  constructor(code, message, statusCode = 400) {
    super(message);
    this.name = 'PasswordResetError';
    this.code = code;
    this.statusCode = statusCode;
  }
}

/**
 * Step 1 - request a reset code.
 * Always resolves with the same generic message (never reveals whether the
 * email belongs to an account).
 */
async function requestPasswordReset(email, { now = new Date(), code = null } = {}) {
  const normalized = normalizeEmail(email);

  if (!isValidEmail(normalized)) {
    // Malformed input is a client error, but the message is about the FORMAT,
    // not about account existence.
    return { ok: true, sent: false, message: GENERIC_REQUEST_MESSAGE };
  }

  const user = await prisma.user.findUnique({ where: { email: normalized } });

  if (!user || !user.isActive) {
    // Equalize timing with the branch below so the response time does not
    // reveal whether the account exists.
    await bcrypt.hash('enumeration-timing-equalizer', SALT_ROUNDS);
    logger.info('auth.password_reset_requested_unknown_account');
    return { ok: true, sent: false, message: GENERIC_REQUEST_MESSAGE };
  }

  if (user.authProvider === 'GOOGLE' && !user.passwordChangedAt) {
    // Google-only accounts have no usable ERAS password. No code is issued
    // (a code would let anyone with mailbox access add one); the response stays
    // identical so nothing is revealed.
    logger.info('auth.password_reset_skipped_google_account', { userId: user.id });
    return { ok: true, sent: false, message: GENERIC_REQUEST_MESSAGE };
  }

  const allowance = await authCodeService.checkRequestAllowance({
    userId: user.id,
    purpose: PURPOSE,
    now,
  });
  if (!allowance.allowed) {
    logger.warn('auth.password_reset_throttled', {
      userId: user.id,
      reason: allowance.reason,
    });
    return {
      ok: true,
      sent: false,
      throttled: true,
      retryAfterSeconds: allowance.retryAfterSeconds ?? null,
      message: GENERIC_REQUEST_MESSAGE,
    };
  }

  const issued = await authCodeService.issueCode({ userId: user.id, purpose: PURPOSE, now, code });
  const delivery = await emailService.sendPasswordResetCode(user.email, issued.code);

  logger.info('auth.password_reset_code_issued', {
    userId: user.id,
    delivered: delivery.delivered,
    transport: delivery.transport,
  });

  return {
    ok: true,
    sent: true,
    delivered: delivery.delivered,
    expiresAt: issued.expiresAt,
    message: GENERIC_REQUEST_MESSAGE,
  };
}

/**
 * Step 2a - check a code WITHOUT consuming it (immediate UI feedback). A wrong
 * code still counts against the attempt limit.
 */
async function verifyResetCode(email, code, { now = new Date() } = {}) {
  const normalized = normalizeEmail(email);
  if (!isValidEmail(normalized)) {
    throw new PasswordResetError('INVALID_CODE', GENERIC_CODE_ERROR);
  }

  const user = await prisma.user.findUnique({ where: { email: normalized } });
  if (!user || !user.isActive) {
    // Burn comparable work (the code path below hashes a comparison).
    await authCodeService.verifyCodeHash(code, await bcrypt.hash('invalid', 4));
    throw new PasswordResetError('INVALID_CODE', GENERIC_CODE_ERROR);
  }

  const result = await authCodeService.consumeCode({
    userId: user.id,
    purpose: PURPOSE,
    code,
    now,
    consume: false,
  });

  if (!result.ok) {
    throw new PasswordResetError(
      result.reason === 'EXPIRED_CODE' ? 'EXPIRED_CODE' : 'INVALID_CODE',
      GENERIC_CODE_ERROR
    );
  }
  return { ok: true };
}

/** Password policy shared by registration and reset (server side). */
function validateNewPassword(password, confirmPassword) {
  if (typeof password !== 'string' || !password) {
    throw new PasswordResetError('PASSWORD_REQUIRED', 'Password is required');
  }
  if (password.length < MIN_PASSWORD_LENGTH) {
    throw new PasswordResetError(
      'PASSWORD_TOO_SHORT',
      `Password must be at least ${MIN_PASSWORD_LENGTH} characters`
    );
  }
  if (password.length > MAX_PASSWORD_LENGTH) {
    throw new PasswordResetError('PASSWORD_TOO_LONG', 'Password is too long');
  }
  if (confirmPassword !== undefined && password !== confirmPassword) {
    throw new PasswordResetError('PASSWORD_MISMATCH', 'Passwords do not match');
  }
  return password;
}

/**
 * Step 2b - consume the code and set the new password.
 *
 * Existing sessions are invalidated through User.passwordChangedAt: authMiddleware
 * rejects any token issued before that instant.
 */
async function resetPassword({ email, code, password, confirmPassword, now = new Date() } = {}) {
  const normalized = normalizeEmail(email);
  const newPassword = validateNewPassword(password, confirmPassword);

  if (!isValidEmail(normalized)) {
    throw new PasswordResetError('INVALID_CODE', GENERIC_CODE_ERROR);
  }

  const user = await prisma.user.findUnique({ where: { email: normalized } });
  if (!user || !user.isActive) {
    throw new PasswordResetError('INVALID_CODE', GENERIC_CODE_ERROR);
  }

  const result = await authCodeService.consumeCode({
    userId: user.id,
    purpose: PURPOSE,
    code,
    now,
  });

  if (!result.ok) {
    logger.warn('auth.password_reset_failed', {
      userId: user.id,
      reason: result.reason,
    });
    throw new PasswordResetError(
      result.reason === 'TOO_MANY_ATTEMPTS' ? 'TOO_MANY_ATTEMPTS' : 'INVALID_CODE',
      result.reason === 'TOO_MANY_ATTEMPTS'
        ? 'Too many incorrect attempts. Request a new reset code.'
        : GENERIC_CODE_ERROR
    );
  }

  const passwordHash = await bcrypt.hash(newPassword, SALT_ROUNDS);

  const updated = await prisma.$transaction(async (tx) => {
    const row = await tx.user.update({
      where: { id: user.id },
      data: {
        password: passwordHash,
        passwordChangedAt: now,
        // The mailbox was proven by the code, and a password now exists.
        authProvider: user.authProvider === 'GOOGLE' ? 'PASSWORD' : user.authProvider,
        ...(user.emailVerified ? {} : { emailVerified: true, emailVerifiedAt: now }),
      },
    });

    // No reset code may survive a successful reset.
    await tx.authCode.updateMany({
      where: { userId: user.id, purpose: PURPOSE, consumedAt: null },
      data: { consumedAt: now },
    });

    return row;
  });

  logger.info('auth.password_reset_completed', { userId: updated.id });
  return { ok: true, userId: updated.id };
}

module.exports = {
  PURPOSE,
  MIN_PASSWORD_LENGTH,
  MAX_PASSWORD_LENGTH,
  GENERIC_REQUEST_MESSAGE,
  GENERIC_CODE_ERROR,
  PasswordResetError,
  requestPasswordReset,
  verifyResetCode,
  validateNewPassword,
  resetPassword,
};
