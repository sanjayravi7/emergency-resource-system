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
  GPS_SENSITIVE_PATHS,
};
