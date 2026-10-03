// ---------------------------------------------------------------------------
// ONE-TIME AUTH CODES (email verification + 6-digit password reset)
//
// Security properties (all enforced here, in one place):
//   * CSPRNG generation (crypto.randomInt), exactly 6 digits;
//   * the plaintext code is NEVER stored - only a bcrypt hash (cost 10);
//   * short TTL (10 minutes for password resets by default);
//   * single use (consumedAt) and automatically invalidated when a new code is
//     issued for the same (user, purpose);
//   * attempt limit per code (default 5) - exhausting it burns the code;
//   * request rate limit and resend cooldown per user+purpose;
//   * the code is never logged, never returned to an unauthenticated caller
//     and never stored in audit metadata (see auditLogService redaction).
// ---------------------------------------------------------------------------

const crypto = require('crypto');
const bcrypt = require('bcrypt');

const prisma = require('../config/prisma');
const env = require('../config/env');
const logger = require('../config/logger');

const CODE_LENGTH = 6;
const CODE_PATTERN = /^\d{6}$/;
const BCRYPT_ROUNDS = 10;

const PURPOSES = Object.freeze({
  EMAIL_VERIFICATION: 'EMAIL_VERIFICATION',
  PASSWORD_RESET: 'PASSWORD_RESET',
});

const TTL_MINUTES = Object.freeze({
  [PURPOSES.EMAIL_VERIFICATION]: env.EMAIL_VERIFICATION_TTL_MINUTES,
  [PURPOSES.PASSWORD_RESET]: env.PASSWORD_RESET_TTL_MINUTES,
});

/** Cryptographically secure, zero-padded 6-digit code. */
function generateNumericCode(length = CODE_LENGTH) {
  let code = '';
  while (code.length < length) {
    code += String(crypto.randomInt(0, 10));
  }
  return code;
}

/** Strict format check before any hashing/DB work. */
function isValidCodeFormat(code) {
  return typeof code === 'string' && CODE_PATTERN.test(code);
}

function hashCode(code) {
  return bcrypt.hash(String(code), BCRYPT_ROUNDS);
}

async function verifyCodeHash(code, codeHash) {
  if (!codeHash) return false;
  try {
    return await bcrypt.compare(String(code), codeHash);
  } catch {
    return false;
  }
}

function ttlMs(purpose) {
  const minutes = TTL_MINUTES[purpose] ?? 10;
  return minutes * 60 * 1000;
}

/**
 * Has this (user, purpose) pair requested too many codes recently, or asked
 * again inside the resend cooldown?
 *
 * @returns {{ allowed: boolean, reason?: string, retryAfterSeconds?: number,
 *             requestsInWindow: number }}
 */
async function checkRequestAllowance({ userId, purpose, now = new Date() }) {
  const windowStart = new Date(now.getTime() - env.AUTH_CODE_REQUEST_WINDOW_MINUTES * 60 * 1000);

  const [latest, requestsInWindow] = await Promise.all([
    prisma.authCode.findFirst({
      where: { userId: Number(userId), purpose },
      orderBy: { id: 'desc' },
      select: { lastSentAt: true },
    }),
    prisma.authCode.count({
      where: {
        userId: Number(userId),
        purpose,
        createdAt: { gte: windowStart },
      },
    }),
  ]);

  if (latest?.lastSentAt) {
    const elapsedMs = now.getTime() - new Date(latest.lastSentAt).getTime();
    const cooldownMs = env.AUTH_CODE_RESEND_COOLDOWN_SECONDS * 1000;
    if (elapsedMs < cooldownMs) {
      return {
        allowed: false,
        reason: 'COOLDOWN',
        retryAfterSeconds: Math.ceil((cooldownMs - elapsedMs) / 1000),
        requestsInWindow,
      };
    }
  }

  if (requestsInWindow >= env.AUTH_CODE_MAX_REQUESTS_PER_WINDOW) {
    return { allowed: false, reason: 'RATE_LIMITED', requestsInWindow };
  }

  return { allowed: true, requestsInWindow };
}

/**
 * Issue a fresh code for (user, purpose), invalidating any previous unconsumed
 * code of the same purpose. Returns the PLAINTEXT code for immediate delivery
 * by the email service; it is never persisted or logged.
 */
async function issueCode({ userId, purpose, now = new Date(), code = null } = {}) {
  const numericUserId = Number(userId);
  if (!Number.isInteger(numericUserId) || numericUserId <= 0) {
    throw new Error('A valid user is required');
  }
  if (!Object.values(PURPOSES).includes(purpose)) {
    throw new Error('Unsupported code purpose');
  }

  const plaintext = code ?? generateNumericCode();
  if (!isValidCodeFormat(plaintext)) throw new Error('Invalid code format');

  const codeHash = await hashCode(plaintext);
  const expiresAt = new Date(now.getTime() + ttlMs(purpose));

  const created = await prisma.$transaction(async (tx) => {
    // Any previously issued, still usable code becomes unusable immediately.
    await tx.authCode.updateMany({
      where: { userId: numericUserId, purpose, consumedAt: null },
      data: { consumedAt: now },
    });

    return tx.authCode.create({
      data: {
        userId: numericUserId,
        purpose,
        codeHash,
        expiresAt,
        maxAttempts: env.AUTH_CODE_MAX_ATTEMPTS,
        lastSentAt: now,
      },
      select: { id: true, expiresAt: true, maxAttempts: true },
    });
  });

  return { code: plaintext, expiresAt: created.expiresAt, codeId: created.id };
}

/**
 * Verify and consume a code. Attempts are counted even for wrong codes, and
 * exhausting the attempt limit permanently burns the code.
 *
 * @returns {Promise<{ ok: boolean, reason?: string, attemptsRemaining?: number }>}
 */
/**
 * Verify a code.
 *
 * @param {object} options
 * @param {boolean} [options.consume=true] When false the code stays usable
 *        (used by the two-step "verify code" screen). A WRONG code still counts
 *        against the attempt limit in both modes.
 */
async function consumeCode({
  userId,
  purpose,
  code,
  now = new Date(),
  consume = true,
  transactionClient = null,
} = {}) {
  const numericUserId = Number(userId);
  if (!Number.isInteger(numericUserId) || numericUserId <= 0) {
    return { ok: false, reason: 'INVALID_CODE' };
  }
  if (!isValidCodeFormat(code)) {
    return { ok: false, reason: 'INVALID_CODE' };
  }

  // The caller may pass a Prisma transaction client so OTP consumption and the
  // corresponding account state change commit or roll back together.
  const client = transactionClient || prisma;
  const authCodes = client.authCode;
  const record = await authCodes.findFirst({
    where: { userId: numericUserId, purpose, consumedAt: null },
    orderBy: { id: 'desc' },
  });

  if (!record) return { ok: false, reason: 'INVALID_CODE' };

  if (new Date(record.expiresAt).getTime() <= now.getTime()) {
    await authCodes.updateMany({
      where: { id: record.id, consumedAt: null },
      data: { consumedAt: now },
    });
    return { ok: false, reason: 'EXPIRED_CODE' };
  }

  if (record.attempts >= record.maxAttempts) {
    await authCodes.updateMany({
      where: { id: record.id, consumedAt: null },
      data: { consumedAt: now },
    });
    return { ok: false, reason: 'TOO_MANY_ATTEMPTS' };
  }

  const matches = await verifyCodeHash(code, record.codeHash);
  if (!matches) {
    const attempts = record.attempts + 1;
    const changed = await authCodes.updateMany({
      // Compare-and-swap prevents concurrent requests from overwriting one
      // another's attempt count or reviving a code another request consumed.
      where: { id: record.id, consumedAt: null, attempts: record.attempts },
      data: {
        attempts,
        // Burning the code once the limit is reached prevents unlimited
        // guessing (6 digits would otherwise be brute-forceable).
        ...(attempts >= record.maxAttempts ? { consumedAt: now } : {}),
      },
    });
    if (changed.count !== 1) return { ok: false, reason: 'INVALID_CODE' };
    return {
      ok: false,
      reason: attempts >= record.maxAttempts ? 'TOO_MANY_ATTEMPTS' : 'INVALID_CODE',
      attemptsRemaining: Math.max(0, record.maxAttempts - attempts),
    };
  }

  if (consume) {
    // The predicate is atomic in PostgreSQL: only one concurrent request may
    // move the code from active to consumed. The transaction supplied by email
    // verification also makes this commit atomic with emailVerified=true.
    const consumed = await authCodes.updateMany({
      where: { id: record.id, consumedAt: null, attempts: record.attempts },
      data: { consumedAt: now },
    });
    if (consumed.count !== 1) return { ok: false, reason: 'INVALID_CODE' };
  }

  return {
    ok: true,
    attemptsRemaining: Math.max(0, record.maxAttempts - record.attempts),
  };
}

/** Invalidate every outstanding code for a purpose (e.g. after a reset). */
async function invalidateCodes({ userId, purpose, now = new Date() } = {}) {
  const result = await prisma.authCode.updateMany({
    where: { userId: Number(userId), purpose, consumedAt: null },
    data: { consumedAt: now },
  });
  return result.count;
}

/** Housekeeping: drop codes that expired long ago. Safe to call anytime. */
async function pruneExpiredCodes({ olderThanMs = 24 * 60 * 60 * 1000, now = new Date() } = {}) {
  try {
    const result = await prisma.authCode.deleteMany({
      where: { expiresAt: { lt: new Date(now.getTime() - olderThanMs) } },
    });
    if (result.count) logger.info('authcode.pruned', { count: result.count });
    return result.count;
  } catch (error) {
    logger.warn('authcode.prune_failed', { message: error?.message });
    return 0;
  }
}

module.exports = {
  CODE_LENGTH,
  CODE_PATTERN,
  PURPOSES,
  TTL_MINUTES,
  generateNumericCode,
  isValidCodeFormat,
  hashCode,
  verifyCodeHash,
  checkRequestAllowance,
  issueCode,
  consumeCode,
  invalidateCodes,
  pruneExpiredCodes,
};
