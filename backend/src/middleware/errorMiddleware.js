const logger = require('../config/logger');

const EXPECTED_BUSINESS_CONFLICT = new RegExp(
  [
    '^Unauthorized',
    '^Forbidden',
    '^Only .+ can',
    '^Responder .+ (inactive|not available)',
    '^Responder already has',
    '^Assignment has already ended$',
    '^Request (has already|is invalid or already closed|must be|is already)',
    '^Completed requests cannot',
    '^This resource is already fully allocated$',
    '^Not enough available quantity$',
    '^Already (cancelled|delivered)$',
    '^Receipt has already been confirmed$',
    '^Cancelled allocations cannot',
    '^Only (RESERVED|DISPATCHED)',
    '^Cannot (start|complete) response',
  ].join('|'),
  'i'
);

function isPrismaError(error) {
  return Boolean(
    error &&
      ((typeof error.code === 'string' && /^P\d{4}$/.test(error.code)) ||
        /^PrismaClient/.test(error.name || '') ||
        /^Invalid `prisma\./.test(error.message || ''))
  );
}

/**
 * body-parser (express.json) raises typed errors BEFORE any controller runs:
 *  - malformed JSON  -> SyntaxError, status 400, type 'entity.parse.failed'
 *  - oversized body  -> status 413, type 'entity.too.large'
 *  - wrong charset   -> status 415
 * These are client faults, not server crashes. They must return a stable,
 * non-leaky status/message instead of falling through to the generic 500.
 */
function bodyParserResponse(error) {
  if (!error || typeof error !== 'object') return null;
  const type = error.type;
  const status = error.status || error.statusCode;

  if (type === 'entity.too.large' || status === 413) {
    return { status: 413, message: 'Request payload is too large' };
  }
  if (
    type === 'entity.parse.failed' ||
    (error instanceof SyntaxError && status === 400 && 'body' in error)
  ) {
    return { status: 400, message: 'Malformed JSON in request body' };
  }
  if (type === 'charset.unsupported' || status === 415) {
    return { status: 415, message: 'Unsupported content type' };
  }
  if (type === 'encoding.unsupported') {
    return { status: 415, message: 'Unsupported content encoding' };
  }
  return null;
}

const errorHandler = (error, req, res, next) => {
  const requestContext = {
    method: req?.method,
    path: req?.originalUrl,
    userId: req?.user?.id,
  };

  // Malformed / oversized / unsupported request bodies -> deterministic 4xx.
  const parseResult = bodyParserResponse(error);
  if (parseResult) {
    logger.warn('request.rejected', {
      ...requestContext,
      reason: parseResult.message,
      status: parseResult.status,
    });
    return res.status(parseResult.status).json({
      success: false,
      message: parseResult.message,
    });
  }

  const message = error?.message || 'Server Error';

  // Expected business conflicts are normal rejected operations, not server
  // crashes. Keep established HTTP status conventions while avoiding noisy
  // raw stack traces in production logs. (The remaining 500-for-conflict
  // convention is documented for a future API version; see PHASE_I_REPORT.md.)
  if (EXPECTED_BUSINESS_CONFLICT.test(message)) {
    logger.warn('business.conflict', { ...requestContext, message });
  } else if (isPrismaError(error)) {
    // Only the safe error class/code is logged - never the query text, which
    // can contain schema internals or request data.
    logger.error('database.error', {
      ...requestContext,
      code: error.code,
    });
  } else {
    // Unexpected server error. The stack is logged (redacted) for diagnosis but
    // never returned to the client.
    logger.error('server.error', {
      ...requestContext,
      name: error?.name,
      message,
    });
  }

  // Prisma invocation text and stack details can expose schema/query internals.
  // Clients receive a stable message while the server log keeps only a safe
  // error class/code above.
  res.status(500).json({
    success: false,
    message: isPrismaError(error) ? 'Database operation failed' : message,
  });
};

module.exports = errorHandler;
