// ---------------------------------------------------------------------------
// ERAS EMAIL VERIFICATION
//
// New EMAIL/PASSWORD registrations start unverified and receive a one-time
// ERAS verification code (the email itself is ERAS-branded - it never pretends
// to come from Google or Firebase). Google sign-ups are already verified by
// Google and never receive this email.
//
// After the 6-digit verification code is validated and consumed and the user
// record is updated to emailVerified=true (with emailVerifiedAt persisted),
// ERAS sends a one-time post-verification welcome email.
//
// Anti-enumeration: "resend" always answers with the same generic success,
// whether or not the address belongs to an ERAS account.
// ---------------------------------------------------------------------------

const prisma = require('../config/prisma');
const logger = require('../config/logger');
const emailService = require('./emailService');
const authCodeService = require('./authCodeService');
const { normalizeEmail } = require('../domain/emailValidation');

const PURPOSE = authCodeService.PURPOSES.EMAIL_VERIFICATION;

// Guards against concurrent duplicate confirmation requests for the same userId
// before the persisted emailVerified / emailVerifiedAt flags are committed.
const inFlightConfirmations = new Set();

function resolveDiagnostics() {
  if (typeof emailService.getTransportDiagnostics === 'function') {
    return emailService.getTransportDiagnostics();
  }
  return {
    configured: false,
    transportConfigured: 'no',
    provider: 'unconfigured',
    transport: 'unconfigured',
    fromConfigured: 'no',
  };
}

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
    return {
      sent: false,
      reason: allowance.reason,
      retryAfterSeconds: allowance.retryAfterSeconds,
    };
  }

  const issued = await authCodeService.issueCode({
    userId: user.id,
    purpose: PURPOSE,
    now,
    code,
  });
  const delivery = await emailService.sendVerificationCode(user.email, issued.code);
  const diagnostics = resolveDiagnostics();
  const delivered = Boolean(delivery && delivery.delivered);

  logger.info('auth.verification_email_issued', {
    userId: user.id,
    transportConfigured: delivery?.transportConfigured ?? diagnostics.transportConfigured,
    provider: delivery?.provider ?? diagnostics.provider,
    delivered,
    deliveryResult: delivered ? 'success' : 'failure',
    transport: delivery?.transport ?? diagnostics.transport,
  });

  return {
    sent: true,
    delivered,
    deliveryResult: delivered ? 'success' : 'failure',
    transport: delivery?.transport ?? diagnostics.transport,
    provider: delivery?.provider ?? diagnostics.provider,
    transportConfigured: delivery?.transportConfigured ?? diagnostics.transportConfigured,
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
    delivered: Boolean(result.delivered),
    reason: result.reason ?? null,
    retryAfterSeconds: result.retryAfterSeconds ?? 0,
  };
}

/**
 * Confirm a verification code, mark the account verified, and send the
 * post-verification ERAS welcome email once.
 *
 * Idempotency & ordering guarantees:
 *   1. If the account is already verified (emailVerified === true or
 *      emailVerifiedAt is set), returns immediately without consuming any code
 *      and without sending a duplicate welcome email.
 *   2. Validates and consumes the 6-digit code first. Invalid, expired, or
 *      already-consumed codes fail before any user update or welcome email.
 *   3. Updates the user record to emailVerified=true and emailVerifiedAt=now.
 *   4. Sends the welcome email best-effort; a mail failure never rolls back
 *      the verified account state.
 *
 * @returns {Promise<{ ok: boolean, reason?: string, attemptsRemaining?: number,
 *                     alreadyVerified?: boolean, welcomeEmailSent?: boolean,
 *                     welcomeEmailDelivered?: boolean, user?: object }>}
 */
async function confirmVerification(userId, code, { now = new Date() } = {}) {
  const numericUserId = Number(userId);
  if (!Number.isInteger(numericUserId) || numericUserId <= 0) {
    return { ok: false, reason: 'INVALID_CODE', welcomeEmailSent: false };
  }

  const user = await prisma.user.findUnique({ where: { id: numericUserId } });
  if (!user) return { ok: false, reason: 'INVALID_CODE', welcomeEmailSent: false };

  if (user.emailVerified || Boolean(user.emailVerifiedAt)) {
    return {
      ok: true,
      alreadyVerified: true,
      welcomeEmailSent: false,
      welcomeEmailDelivered: false,
      user,
    };
  }

  if (inFlightConfirmations.has(numericUserId)) {
    return {
      ok: true,
      alreadyVerified: true,
      welcomeEmailSent: false,
      welcomeEmailDelivered: false,
      user,
    };
  }

  inFlightConfirmations.add(numericUserId);
  try {
    const result = await authCodeService.consumeCode({
      userId: numericUserId,
      purpose: PURPOSE,
      code,
      now,
    });
    if (!result.ok) {
      return { ...result, welcomeEmailSent: false };
    }

    const updated = await prisma.user.update({
      where: { id: numericUserId },
      data: { emailVerified: true, emailVerifiedAt: now },
    });

    const diagnostics = resolveDiagnostics();
    let welcomeDelivery = {
      delivered: false,
      deliveryResult: 'failure',
      transport: diagnostics.transport,
      provider: diagnostics.provider,
      transportConfigured: diagnostics.transportConfigured,
    };

    if (typeof emailService.sendWelcomeEmail === 'function') {
      try {
        const delivery = await emailService.sendWelcomeEmail(
          updated?.email || user.email,
          updated?.name || user.name
        );
        if (delivery && typeof delivery === 'object') {
          welcomeDelivery = delivery;
        }
      } catch (error) {
        logger.warn('auth.welcome_email_failed', {
          userId: numericUserId,
          transportConfigured: diagnostics.transportConfigured,
          provider: diagnostics.provider,
          deliveryResult: 'failure',
          message: error?.message,
        });
      }
    }

    const welcomeEmailDelivered = Boolean(welcomeDelivery.delivered);

    logger.info('auth.email_verified', {
      userId: numericUserId,
      transportConfigured:
        welcomeDelivery.transportConfigured ?? diagnostics.transportConfigured,
      provider: welcomeDelivery.provider ?? diagnostics.provider,
      welcomeEmailDelivered,
      deliveryResult: welcomeEmailDelivered ? 'success' : 'failure',
    });

    return {
      ok: true,
      alreadyVerified: false,
      welcomeEmailSent: true,
      welcomeEmailDelivered,
      user: updated,
    };
  } finally {
    inFlightConfirmations.delete(numericUserId);
  }
}

module.exports = {
  PURPOSE,
  issueVerificationForUser,
  resendVerificationForEmail,
  confirmVerification,
};
