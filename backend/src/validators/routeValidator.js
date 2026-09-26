/**
 * Validation for POST /api/routes/compute.
 *
 * The endpoint is a thin, authenticated proxy in front of the Google Routes
 * API Compute Routes method, so every coordinate is validated here before a
 * billable upstream request is made. Nothing is guessed or defaulted: an
 * incomplete or out-of-range coordinate is rejected with 400.
 */

const LATITUDE_RANGE = { min: -90, max: 90 };
const LONGITUDE_RANGE = { min: -180, max: 180 };

function isFiniteNumber(value) {
  return typeof value === 'number' && Number.isFinite(value);
}

/**
 * Validates one `{ latitude, longitude }` waypoint.
 * Returns an error string, or null when the waypoint is usable.
 */
function validateWaypoint(waypoint, label) {
  if (
    waypoint === undefined ||
    waypoint === null ||
    typeof waypoint !== 'object' ||
    Array.isArray(waypoint)
  ) {
    return `${label} is required`;
  }

  const { latitude, longitude } = waypoint;

  if (latitude === undefined || latitude === null) {
    return `${label} latitude is required`;
  }
  if (longitude === undefined || longitude === null) {
    return `${label} longitude is required`;
  }
  if (!isFiniteNumber(latitude)) {
    return `${label} latitude must be a number`;
  }
  if (!isFiniteNumber(longitude)) {
    return `${label} longitude must be a number`;
  }
  if (latitude < LATITUDE_RANGE.min || latitude > LATITUDE_RANGE.max) {
    return `${label} latitude must be between -90 and 90`;
  }
  if (longitude < LONGITUDE_RANGE.min || longitude > LONGITUDE_RANGE.max) {
    return `${label} longitude must be between -180 and 180`;
  }

  return null;
}

/**
 * Validates the whole compute-route body.
 * Returns an error string, or null when the request may be forwarded.
 */
function validateRouteComputeInput(body) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) {
    return 'Origin is required';
  }

  const originError = validateWaypoint(body.origin, 'Origin');
  if (originError) return originError;

  const destinationError = validateWaypoint(body.destination, 'Destination');
  if (destinationError) return destinationError;

  return null;
}

/**
 * Narrows an already validated body down to the exact numbers forwarded to
 * Google. Extra client fields never reach the upstream request.
 */
function normalizeRouteComputeInput(body) {
  return {
    origin: {
      latitude: Number(body.origin.latitude),
      longitude: Number(body.origin.longitude),
    },
    destination: {
      latitude: Number(body.destination.latitude),
      longitude: Number(body.destination.longitude),
    },
  };
}

module.exports = {
  validateWaypoint,
  validateRouteComputeInput,
  normalizeRouteComputeInput,
};
