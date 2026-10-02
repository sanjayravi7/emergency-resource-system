// ---------------------------------------------------------------------------
// BACKEND-AUTHORITATIVE REQUEST EXPIRY
//
// An unattended emergency (still PENDING, nobody accepted/assigned it and no
// unfinished allocation holds a claim on it) is expired by the SERVER once its
// durable `EmergencyRequest.expiresAt` deadline has passed. Nothing here
// depends on a connected browser, the Flutter client, or a long-lived timer:
//
//   1. `expiresAt` is written by the server at creation time (expiryPolicy).
//   2. Every request LIST/READ runs `enforceExpiryOnRetrieval()`, which applies
//      due expirations before the query and filters expired rows defensively.
//      This is what makes expiry correct after a Render sleep/restart.
//   3. The periodic sweep (server.js) only makes the transition prompt; it is
//      never the source of truth and may be skipped entirely.
//
// Races: every transition runs inside a serializable transaction that takes a
// row lock (SELECT ... FOR UPDATE) and RE-EVALUATES the unattended predicate
// after acquiring it, so two concurrent operations can never both expire the
// same row, and a responder accepting at the same moment always wins (their
// transaction either sees PENDING and cancels expiry, or sees the request
// already CANCELLED and gets the existing "already cancelled" business error).
//
// Data preservation: expiry reuses the EXISTING terminal state (CANCELLED) and
// adds `expiredAt` for history. No row is deleted; allocations are already
// impossible on an unattended request, and the existing cancellation cleanup
// path is reused when one is somehow present.
// ---------------------------------------------------------------------------

const prisma = require('../config/prisma');
const logger = require('../config/logger');
const { runSerializableTransaction } = require('./transactionService');
const { isExpiredUnattended } = require('../domain/expiryPolicy');

const DEFAULT_SWEEP_LIMIT = 50;

/**
 * Prisma `where` fragment that excludes unattended-but-expired requests from
 * ACTIVE listings, independently of whether the sweep has already run. Used in
 * addition to (never instead of) persisting the transition, so a stale row can
 * never be shown as active.
 */
function notExpiredUnattendedWhere(now = new Date()) {
  return {
    NOT: {
      AND: [
        { status: 'PENDING' },
        { expiresAt: { not: null, lte: now } },
        { acceptedById: null },
        { assignments: { none: { status: 'ACTIVE' } } },
      ],
    },
  };
}

/** Merge the defensive "not expired" filter into an existing where clause. */
function withActiveExpiryFilter(where = {}, now = new Date()) {
  return { AND: [where, notExpiredUnattendedWhere(now)] };
}

/**
 * Expire every unattended request whose deadline has passed. Returns the ids
 * that were transitioned by THIS call (already-expired rows are idempotent:
 * they are CANCELLED and therefore no longer candidates).
 *
 * @param {object} options { now, limit, actorId }
 */
async function expireUnattendedRequests({ now = new Date(), limit = DEFAULT_SWEEP_LIMIT, actorId = null } = {}) {
  const candidates = await prisma.emergencyRequest.findMany({
    where: {
      status: 'PENDING',
      acceptedById: null,
      acceptedAt: null,
      expiresAt: { not: null, lte: now },
      assignments: { none: { status: 'ACTIVE' } },
      allocations: { none: { status: { in: ['RESERVED', 'DISPATCHED'] } } },
    },
    select: { id: true },
    orderBy: { expiresAt: 'asc' },
    take: Math.max(1, Number(limit) || DEFAULT_SWEEP_LIMIT),
  });

  const expiredIds = [];
  for (const candidate of candidates) {
    try {
      const didExpire = await expireOne(candidate.id, now);
      if (didExpire) expiredIds.push(candidate.id);
    } catch (error) {
      // One bad row must never stop the sweep: log and continue.
      logger.error('request.expiry_failed', {
        requestId: candidate.id,
        message: error?.message,
      });
    }
  }

  if (expiredIds.length) {
    logger.info('request.expired', { count: expiredIds.length, requestIds: expiredIds, actorId });
    const { emitRequestUpdated } = require('../realtime/eventEmitters');
    for (const requestId of expiredIds) {
      try {
        await emitRequestUpdated(requestId, []);
      } catch (error) {
        // A realtime failure must never undo a committed expiry.
        logger.warn('request.expiry_emit_failed', { requestId, message: error?.message });
      }
    }
  }

  return expiredIds;
}

/**
 * Expire exactly one request, re-checking the full unattended predicate under a
 * row lock. Returns true when this call performed the transition.
 */
async function expireOne(requestId, now = new Date()) {
  const numericRequestId = Number(requestId);
  if (!Number.isInteger(numericRequestId) || numericRequestId <= 0) return false;

  return runSerializableTransaction(async (tx) => {
    const locked = await tx.$queryRaw`
      SELECT id, status, "acceptedById", "acceptedAt", "expiresAt", "expiredAt"
      FROM "EmergencyRequest"
      WHERE id = ${numericRequestId}
      FOR UPDATE
    `;
    const request = locked[0];
    if (!request) return false;

    // Re-evaluate AFTER the lock: a responder may have accepted between the
    // candidate query and this transaction.
    const [activeAssignments, unfinishedAllocations] = await Promise.all([
      tx.responderAssignment.count({
        where: { requestId: numericRequestId, status: 'ACTIVE' },
      }),
      tx.allocation.count({
        where: {
          requestId: numericRequestId,
          status: { in: ['RESERVED', 'DISPATCHED'] },
        },
      }),
    ]);

    const stillUnattended = isExpiredUnattended(
      {
        status: request.status,
        expiresAt: request.expiresAt,
        acceptedById: request.acceptedById,
        acceptedAt: request.acceptedAt,
        assignments: activeAssignments ? [{ status: 'ACTIVE' }] : [],
        allocations: unfinishedAllocations ? [{ status: 'RESERVED' }] : [],
      },
      now
    );
    if (!stillUnattended) return false;

    await tx.emergencyRequest.update({
      where: { id: numericRequestId },
      data: {
        status: 'CANCELLED',
        expiredAt: now,
      },
    });

    return true;
  });
}

/**
 * Apply due expirations before serving a request listing/read. Bounded and
 * cheap: when nothing is due the candidate query returns quickly through the
 * (status, expiresAt) index and no transaction is opened.
 */
async function enforceExpiryOnRetrieval({ now = new Date(), limit = DEFAULT_SWEEP_LIMIT } = {}) {
  try {
    return await expireUnattendedRequests({ now, limit });
  } catch (error) {
    // Retrieval must never fail because the expiry bookkeeping failed. The
    // defensive query filter still hides expired rows.
    logger.error('request.expiry_sweep_failed', { message: error?.message });
    return [];
  }
}

module.exports = {
  DEFAULT_SWEEP_LIMIT,
  notExpiredUnattendedWhere,
  withActiveExpiryFilter,
  expireUnattendedRequests,
  expireOne,
  enforceExpiryOnRetrieval,
};
