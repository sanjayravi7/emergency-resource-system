// ---------------------------------------------------------------------------
// SECURITY AUDIT TRAIL
//
// Critical security/operational events are recorded here (login success and
// failure, logout, Google authentication, email verification, password reset,
// admin log deletion, role/permission and lifecycle changes...). Audit rows are
// append-only and are NEVER removed by the after-action log deletion feature.
//
// Hard rules enforced by this module:
//   * no passwords, reset/verification codes, tokens or secrets are stored -
//     sensitive keys are stripped from metadata recursively;
//   * a failed audit write never fails the caller's business operation
//     (unless a transaction client is supplied, in which case the caller
//     explicitly opted into atomicity);
//   * logging failures are themselves logged (without the payload).
// ---------------------------------------------------------------------------

const prisma = require('../config/prisma');
const logger = require('../config/logger');

const SENSITIVE_KEY_PATTERN =
  /pass(word)?|secret|token|code|authorization|credential|api[_-]?key|private[_-]?key/i;

const MAX_METADATA_DEPTH = 4;
const MAX_STRING_LENGTH = 300;

/** Recursively strip secrets from audit metadata. */
function sanitizeMetadata(value, depth = 0) {
  if (value === null || value === undefined) return null;
  if (depth > MAX_METADATA_DEPTH) return '[truncated]';

  if (typeof value === 'string') {
    return value.length > MAX_STRING_LENGTH ? `${value.slice(0, MAX_STRING_LENGTH)}…` : value;
  }
  if (typeof value === 'number' || typeof value === 'boolean') return value;
  if (Array.isArray(value)) {
    return value.slice(0, 25).map((item) => sanitizeMetadata(item, depth + 1));
  }
  if (typeof value === 'object') {
    const out = {};
    for (const [key, val] of Object.entries(value)) {
      if (SENSITIVE_KEY_PATTERN.test(key)) {
        out[key] = '[redacted]';
        continue;
      }
      out[key] = sanitizeMetadata(val, depth + 1);
    }
    return out;
  }
  return null;
}

/** Best-effort IP extraction (never trusts a client-supplied body field). */
function clientIpFrom(req) {
  if (!req) return null;
  const raw = req.ip || req.socket?.remoteAddress || null;
  return typeof raw === 'string' ? raw.slice(0, 64) : null;
}

/**
 * Append one audit event.
 *
 * @param {object} entry { event, actorId, actorRole, targetType, targetId, ip,
 *                         metadata, tx }
 * @returns {Promise<object|null>} the created row, or null when the write was
 *          skipped/failed (never throws for the best-effort path).
 */
async function record({
  event,
  actorId = null,
  actorRole = null,
  targetType = null,
  targetId = null,
  ip = null,
  metadata = null,
  tx = null,
} = {}) {
  if (!event || typeof event !== 'string') return null;

  const data = {
    event: event.slice(0, 120),
    actorId: Number.isInteger(Number(actorId)) && Number(actorId) > 0 ? Number(actorId) : null,
    actorRole: actorRole ? String(actorRole).slice(0, 32) : null,
    targetType: targetType ? String(targetType).slice(0, 64) : null,
    targetId: targetId === null || targetId === undefined ? null : String(targetId).slice(0, 64),
    ip: ip ? String(ip).slice(0, 64) : null,
    metadata: sanitizeMetadata(metadata),
  };

  const client = tx || prisma;
  try {
    return await client.auditLog.create({ data });
  } catch (error) {
    logger.error('audit.write_failed', { event: data.event, message: error?.message });
    return null;
  }
}

/**
 * Convenience wrapper for controllers/services that have the Express request:
 * records actor identity, role and IP without any caller bookkeeping.
 */
function recordForRequest(req, event, extra = {}) {
  return record({
    event,
    actorId: req?.user?.id ?? null,
    actorRole: req?.user?.role ?? null,
    ip: clientIpFrom(req),
    ...extra,
  });
}

module.exports = {
  SENSITIVE_KEY_PATTERN,
  sanitizeMetadata,
  clientIpFrom,
  record,
  recordForRequest,
};
