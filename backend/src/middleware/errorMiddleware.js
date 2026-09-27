const EXPECTED_BUSINESS_CONFLICT = new RegExp(
  [
    '^Unauthorized',
    '^Forbidden',
    '^Only .+ can',
    '^Responder .+ (inactive|not available)',
    '^Responder already has',
    '^Assignment has already ended$',
    '^Request (has already|is invalid or already closed)',
    '^Completed requests cannot',
    '^This resource is already fully allocated$',
    '^Not enough available quantity$',
    '^Already (cancelled|delivered)$',
    '^Receipt has already been confirmed$',
    '^Cancelled allocations cannot',
    '^Only (RESERVED|DISPATCHED)',
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

const errorHandler = (error, req, res, next) => {
  const message = error?.message || 'Server Error';

  // Expected business conflicts are normal rejected operations, not server
  // crashes. Keep established HTTP status conventions while avoiding noisy
  // raw stack traces in production logs.
  if (EXPECTED_BUSINESS_CONFLICT.test(message)) {
    console.warn(`Business conflict: ${message}`);
  } else if (isPrismaError(error)) {
    console.error(`Database operation failed${error.code ? ` (${error.code})` : ''}`);
  } else {
    console.error(error?.stack || message);
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
