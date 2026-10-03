// ---------------------------------------------------------------------------
// ERAS EMAIL VERIFICATION
//
// Password accounts start unverified and receive a one-time ERAS verification
// code. Google accounts are already verified by the identity provider and do
// not use this code flow.
//
// On successful verification, AuthCode consumption, the emailVerified update,
// and the persistent welcome-email dispatch claim commit in one PostgreSQL
// transaction. Only the transaction that claims the transition can attempt the
// welcome email. This works across Render workers/restarts; no in-memory lock
// is used for correctness.
//
// Anti-enumeration: resend always answers generically, whether or not an
// address belongs to an ERAS account.
// ---------------------------------------------------------------------------

const prisma = require('../config/prisma');
const logger = require('../config/logger');
const emailService = require('./emailService');
const authCodeService = require('./authCodeService');
const { normalizeEmail } = require('../domain/emailValidation');
const { summarizeEmailDelivery } = require('../domain/emailDelivery');

const PURPOSE = authCodeService.PURPOSES.EMAIL_VERIFICATION;

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
 * Issue a code for a freshly registered account and send the ERAS email.
 * Best effort: a provider problem never rolls back completed registration.
 */
async function issueVerificationForUser(user, { now = new Date(), code = null } = {}) {
  if (!user || !user.email || user.emailVerified) {
    return { sent: false, codeIssued: false, reason: 'ALREADY_VERIFIED' };
  }

  const allowance = await authCodeService.checkRequestAllowance({
    userId: user.id,
    purpose: PURPOSE,
    now,
  });
  if (!allowance.allowed) {
    return {
      sent: false,
      codeIssued: false,
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
  const summary = summarizeEmailDelivery(delivery);
  const diagnostics = resolveDiagnostics();

  logger.info('auth.verification_email_issued', {
    userId: user.id,
    transportConfigured: delivery?.transportConfigured ?? diagnostics.transportConfigured,
    provider: delivery?.provider ?? diagnostics.provider,
    emailRequestAccepted: summary.accepted,
    deliveryResult: summary.deliveryResult,
    transport: delivery?.transport ?? diagnostics.transport,
    providerResponseStatus: summary.providerResponseStatus,
    providerErrorCode: summary.providerErrorCode,
    providerErrorType: summary.providerErrorType,
    messageId: summary.messageId,
  });

  return {
    sent: true,
    codeIssued: true,
    ...summary,
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
    codeIssued: Boolean(result.codeIssued),
    delivered: Boolean(result.accepted),
    deliveryResult: result.deliveryResult,
    reason: result.reason ?? null,
    retryAfterSeconds: result.retryAfterSeconds ?? 0,
  };
}

function alreadyVerifiedResult(user) {
  return {
    ok: true,
    alreadyVerified: true,
    welcomeEmailSent: false,
    welcomeEmailDelivered: null,
    welcomeEmailRequestAccepted: false,
    welcomeEmailDeliveryStatus: 'not_attempted',
    welcomeEmailDeliveryResult: 'not_attempted',
    user,
  };
}

/**
 * Confirm a verification code, mark the account verified, and dispatch its
 * one-time ERAS welcome email.
 *
 * Provider acceptance is best effort and never rolls back verification. The
 * persisted `welcomeEmailDispatchClaimedAt` field is set atomically with the
 * verification transition, before the external call, so retries and other
 * Render instances cannot send a duplicate. Provider acceptance is reported
 * separately; final inbox delivery stays unknown without provider webhooks.
 */
async function confirmVerification(userId, code, { now = new Date() } = {}) {
  const numericUserId = Number(userId);
  if (!Number.isInteger(numericUserId) || numericUserId <= 0) {
    return { ok: false, reason: 'INVALID_CODE', welcomeEmailSent: false };
  }

  const user = await prisma.user.findUnique({ where: { id: numericUserId } });
  if (!user) return { ok: false, reason: 'INVALID_CODE', welcomeEmailSent: false };
  if (user.emailVerified || Boolean(user.emailVerifiedAt)) {
    return alreadyVerifiedResult(user);
  }

  const transactionResult = await prisma.$transaction(async (tx) => {
    const codeResult = await authCodeService.consumeCode({
      userId: numericUserId,
      purpose: PURPOSE,
      code,
      now,
      transactionClient: tx,
    });

    if (!codeResult.ok) return { codeResult };

    const claim = await tx.user.updateMany({
      where: {
        id: numericUserId,
        emailVerified: false,
        emailVerifiedAt: null,
        welcomeEmailDispatchClaimedAt: null,
      },
      data: {
        emailVerified: true,
        emailVerifiedAt: now,
        welcomeEmailDispatchClaimedAt: now,
      },
    });

    if (claim.count !== 1) {
      return { alreadyClaimed: true };
    }

    const updatedUser = await tx.user.findUnique({
      where: { id: numericUserId },
    });
    return { verified: true, user: updatedUser };
  });

  if (!transactionResult.verified) {
    // Another request/instance may have won the code-consumption and state
    // transition race. Re-read the durable row so a retry receives the same
    // successful state instead of a misleading invalid-code response.
    const current = await prisma.user.findUnique({ where: { id: numericUserId } });
    if (current?.emailVerified || current?.emailVerifiedAt) {
      return alreadyVerifiedResult(current);
    }
    return {
      ...(transactionResult.codeResult || {
        ok: false,
        reason: transactionResult.alreadyClaimed ? 'INVALID_CODE' : 'INVALID_CODE',
      }),
      welcomeEmailSent: false,
      welcomeEmailDelivered: null,
      welcomeEmailRequestAccepted: false,
      welcomeEmailDeliveryStatus: 'not_attempted',
      welcomeEmailDeliveryResult: 'not_attempted',
    };
  }

  const verifiedUser = transactionResult.user;
  const diagnostics = resolveDiagnostics();
  let delivery = null;
  try {
    if (typeof emailService.sendWelcomeEmail === 'function') {
      delivery = await emailService.sendWelcomeEmail(
        verifiedUser?.email || user.email,
        verifiedUser?.name || user.name,
      );
    }
  } catch (error) {
    // Never log the provider's raw error text; it may contain recipient or
    // transport credentials. emailService logs its own safe structured reason.
    logger.warn('auth.welcome_email_failed', {
      userId: numericUserId,
      transportConfigured: diagnostics.transportConfigured,
      provider: diagnostics.provider,
      deliveryResult: 'failed',
      errorType: error?.name || 'Error',
    });
    delivery = {
      accepted: false,
      deliveryAccepted: false,
      delivered: null,
      deliveryConfirmed: false,
      deliveryResult: 'failed',
      transportConfigured: diagnostics.transportConfigured,
      provider: diagnostics.provider,
      providerErrorCode: 'WELCOME_EMAIL_SEND_FAILED',
    };
  }

  const summary = summarizeEmailDelivery(delivery);
  logger.info('auth.email_verified', {
    userId: numericUserId,
    transportConfigured: delivery?.transportConfigured ?? diagnostics.transportConfigured,
    provider: summary.provider,
    welcomeEmailRequestAccepted: summary.accepted,
    welcomeEmailDeliveryResult: summary.deliveryResult,
    providerResponseStatus: summary.providerResponseStatus,
    providerErrorCode: summary.providerErrorCode,
    providerErrorType: summary.providerErrorType,
    messageId: summary.messageId,
  });

  return {
    ok: true,
    alreadyVerified: false,
    welcomeEmailSent: summary.accepted,
    // A synchronous Resend/SMTP response cannot confirm final inbox delivery.
    welcomeEmailDelivered: summary.delivered,
    welcomeEmailRequestAccepted: summary.accepted,
    welcomeEmailDeliveryStatus: summary.deliveryStatus,
    welcomeEmailDeliveryResult: summary.deliveryResult,
    welcomeEmailProvider: summary.provider,
    welcomeEmailProviderResponseStatus: summary.providerResponseStatus,
    welcomeEmailProviderErrorCode: summary.providerErrorCode,
    welcomeEmailProviderErrorType: summary.providerErrorType,
    welcomeEmailMessageId: summary.messageId,
    user: verifiedUser,
  };
}

module.exports = {
  PURPOSE,
  issueVerificationForUser,
  resendVerificationForEmail,
  confirmVerification,
};
