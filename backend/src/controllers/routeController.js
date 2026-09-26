const routesService = require('../services/routesService');
const {
  validateRouteComputeInput,
  normalizeRouteComputeInput,
} = require('../validators/routeValidator');

/**
 * POST /api/routes/compute  (authenticated)
 *
 * Body:
 *   { origin: { latitude, longitude }, destination: { latitude, longitude } }
 *
 * Response data (nothing else — never the API key, never the raw Google
 * payload):
 *   { distanceMeters, durationSeconds, duration, encodedPolyline,
 *     distanceText, durationText }
 */
async function computeRoute(req, res) {
  const validationError = validateRouteComputeInput(req.body);
  if (validationError) {
    return res.status(400).json({
      success: false,
      message: validationError,
    });
  }

  const { origin, destination } = normalizeRouteComputeInput(req.body);

  try {
    const route = await routesService.computeRoute({ origin, destination });

    return res.status(200).json({
      success: true,
      data: route,
    });
  } catch (error) {
    const statusCode = Number.isInteger(error && error.statusCode)
      ? error.statusCode
      : 502;
    const message = routesService.redactApiKey(
      (error && error.message) || 'Route calculation failed.'
    );

    // Server-side log stays redacted too.
    console.error(`[routes] compute failed (${statusCode}): ${message}`);

    return res.status(statusCode).json({
      success: false,
      message,
      code: (error && error.code) || 'ROUTES_UPSTREAM_ERROR',
    });
  }
}

module.exports = {
  computeRoute,
};
