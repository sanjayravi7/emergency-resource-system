// ---------------------------------------------------------------------------
// ERAS EMAIL VERIFICATION
//
// New EMAIL/PASSWORD registrations start unverified and receive a one-time
// ERAS verification code (the email itself is ERAS-branded - it never pretends
// to come from Google or Firebase). Google sign-ups are already verified by
// Google and never receive this email.
//
// Anti-enumeration: "resend" always answers with the same generic success, wether or not
// the address belongs to an ERAS account.
// ---------------------------------------------------------------------------

const prisma = require('../config/prisma');
const logger = require('../config/logger');
const emailService = require('./emailService');
const authCodeService = require('./authCodeService');
const { normalizeEmail } = require('../domain/emailValidation');

const PURPOSE = authCodeService.PURPOSES.EMAIL_VERIFICATION;

/**
 * Send (or resend) the verification code for a freshly registered account.
 * Best effort by design: a delivery problem must never roll back a completed
 * registration.
 */
async function issueVerificationForUser(user, { now = new Date(), code = null } = {}) {
  if (!user || !user.email || user.emailVerified) {
    return { sent: false, reason: 'ALREADY_VERIFIED' };
  }

  const allowance = await authCodeService.checkRequestAllowance({
    userId: user.id,
    purpose: PURPOSE,
    now,
  });
  if (!allowance.allowed) {
    return { sent: false, reason: allowance.reason, retryAfterSeconds: allowance.retryAfterSeconds };
  }

  const issued = await authCodeService.issueCode({ userId: user.id, purpose: PURPOSE, now, code });
  const delivery = await emailService.sendVerificationCode(user.email, issued.code);

  logger.info('auth.verification_email_issued', {
    userId: user.id,
    delivered: delivery.delivered,
    transport: delivery.transport,
  });

  return {
    sent: true,
    delivered: delivery.delivered,
    expiresAt: issued.expiresAt,
    retryAfterSeconds: 0,
  };
}

/**
 * Resend verification for an email address. The response is identical whether
 * or not the address is registered (no account enumeration).
 */
async function resendVerificationForEmail(email, { now = new Date() } = {}) {
  const normalized = normalizeEmail(email);
  if (!normalized) return { ok: true, sent: false };

  const user = await prisma.user.findUnique({ where: { email: normalized } });
  if (!user || !user.isActive || user.emailVerified) {
    return { ok: true, sent: false };
  }

  const result = await issueVerificationForUser(user, { now });
  return {
    ok: true,
    sent: result.sent,
    reason: result.reason ?? null,
    retryAfterSeconds: result.retryAfterSeconds ?? 0,
  };
}

/**
 * Confirm a verification code and mark the account verified.
 *
 * @returns {Promise<{ ok: boolean, reason?: string, attemptsRemaining?: number,
 *                     user?: object }>}
 */
async function confirmVerification(userId, code, { now = new Date() } = {}) {
  const numericUserId = Number(userId);
  const user = await prisma.user.findUnique({ where: { id: numericUserId } });
  if (!user) return { ok: false, reason: 'INVALID_CODE' };

  if (user.emailVerified) {
    return { ok: true, alreadyVerified: true, user };
  }

  const result = await authCodeService.consumeCode({
    userId: numericUserId,
    purpose: PURPOSE,
    code,
    now,
  });
  if (!result.ok) return result;

  const updated = await prisma.user.update({
    where: { id: numericUserId },
    data: { emailVerified: true, emailVerifiedAt: now },
  });

  logger.info('auth.email_verified', { userId: numericUserId });
  return { ok: true, user: updated };
}

module.exports = {
  PURPOSE,
  issueVerificationForUser,
  resendVerificationForEmail,
  confirmVerification,
};
