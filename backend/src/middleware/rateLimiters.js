const rateLimit = require('express-rate-limit');
const env = require('../config/env');
const logger = require('../config/logger');

const jsonLimitResponse = (req, res) => {
  logger.warn('rate_limit.exceeded', {
    ip: req.ip,
    method: req.method,
    path: req.originalUrl,
    userId: req.user?.id,
  });
  res.status(429).json({
    success: false,
    message: 'Too many requests. Please slow down and try again shortly.',
  });
};

const baseOptions = {
  standardHeaders: true,
  legacyHeaders: false,
  handler: jsonLimitResponse,
  // Global switch. Disabled during the automated test suite so the integration
  // tests can hammer endpoints; always enabled in production.
  skip: () => !env.RATE_LIMIT_ENABLED,
};

/**
 * Strict limiter for credential endpoints (login / registration). Protects
 * against password spraying and mass-registration abuse. Deliberately narrow:
 * it is only mounted on /api/auth/login and /api/auth/register.
 */
const authLimiter = rateLimit({
  ...baseOptions,
  windowMs: env.AUTH_RATE_WINDOW_MS,
  limit: env.AUTH_RATE_MAX,
});

// ---------------------------------------------------------------------------
// Sensitive-endpoint limiters.
//
// These are intentionally permissive enough for a real person (a few clicks),
// but stop automated abuse. Emergency dispatch traffic (requests, GPS,
// heartbeat) is never limited by them.
// ---------------------------------------------------------------------------

/** Google/Firebase identity exchange per IP. */
const googleAuthLimiter = rateLimit({
  ...baseOptions,
  windowMs: env.AUTH_RATE_WINDOW_MS,
  limit: env.GOOGLE_AUTH_RATE_MAX,
});

/**
 * Password reset request/verify/reset per IP. Combined with the per-account
 * cooldown and request budget in authCodeService (which cannot be bypassed by
 * changing IP), this blocks both enumeration and code brute forcing.
 */
const passwordResetLimiter = rateLimit({
  ...baseOptions,
  windowMs: env.PASSWORD_RESET_RATE_WINDOW_MS,
  limit: env.PASSWORD_RESET_RATE_MAX,
});

/** Verification-email resends per IP (per-account cooldown applies on top). */
const emailResendLimiter = rateLimit({
  ...baseOptions,
  windowMs: env.EMAIL_RESEND_RATE_WINDOW_MS,
  limit: env.EMAIL_RESEND_RATE_MAX,
});

/**
 * Destructive/sensitive ADMIN operations (log deletion, role changes).
 * Deliberately generous: an administrator must never be locked out of
 * emergency administration, but scripted bulk deletion is not possible.
 */
const adminSensitiveLimiter = rateLimit({
  ...baseOptions,
  windowMs: env.ADMIN_SENSITIVE_RATE_WINDOW_MS,
  limit: env.ADMIN_SENSITIVE_RATE_MAX,
  keyGenerator: (req) => (req.user?.id ? `user:${req.user.id}` : req.ip),
  validate: { keyGeneratorIpFallback: false },
});

/**
 * Generous catch-all limiter for the rest of the API. It exists to blunt
 * blind abusive traffic, NOT to interfere with legitimate emergency dispatch.
 * High-frequency responder GPS / heartbeat traffic is explicitly skipped so
 * live location behaviour is unchanged.
 */
const GPS_SENSITIVE_PATHS = [
  '/responders/location',
  '/responders/heartbeat',
];

const apiLimiter = rateLimit({
  ...baseOptions,
  windowMs: env.API_RATE_WINDOW_MS,
  limit: env.API_RATE_MAX,
  skip: (req, res) => {
    if (!env.RATE_LIMIT_ENABLED) return true;
    // req.path here is relative to the mount point (/api).
    return GPS_SENSITIVE_PATHS.some((p) => req.path.startsWith(p));
  },
});

module.exports = {
  authLimiter,
  apiLimiter,
  googleAuthLimiter,
  passwordResetLimiter,
  emailResendLimiter,
  adminSensitiveLimiter,
  GPS_SENSITIVE_PATHS,
  jsonLimitResponse,
  baseOptions,
};
