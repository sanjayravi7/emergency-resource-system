/**
 * Google Routes API (Compute Routes) — SERVER SIDE ONLY.
 *
 * https://developers.google.com/maps/documentation/routes/compute_route_directions
 *
 *   POST https://routes.googleapis.com/directions/v2:computeRoutes
 *   X-Goog-Api-Key:    <GOOGLE_ROUTES_API_KEY>   (backend environment only)
 *   X-Goog-FieldMask:  routes.duration,routes.distanceMeters,
 *                      routes.polyline.encodedPolyline
 *
 * Why this lives in the backend:
 *   The Routes API key must never reach Flutter Web. A browser key can only be
 *   protected by HTTP-referrer restrictions, which are trivially spoofable for
 *   a non-Maps-JS web service such as Routes. The browser therefore calls the
 *   authenticated ERAS endpoint POST /api/routes/compute, and only this module
 *   ever sees the key.
 *
 * The deprecated Maps JavaScript DirectionsService is intentionally NOT used.
 */

const env = require('../config/env');

/**
 * Only the three fields ERAS renders are requested, so Google bills the
 * cheapest Compute Routes SKU and no unnecessary data is transferred.
 */
const ROUTES_FIELD_MASK =
  'routes.duration,routes.distanceMeters,routes.polyline.encodedPolyline';

/** Fixed request options required by the ERAS routing feature. */
const ROUTE_REQUEST_OPTIONS = Object.freeze({
  travelMode: 'DRIVE',
  routingPreference: 'TRAFFIC_AWARE',
  computeAlternativeRoutes: false,
  units: 'METRIC',
});

class RouteServiceError extends Error {
  constructor(message, { statusCode = 502, code = 'ROUTES_UPSTREAM_ERROR' } = {}) {
    super(message);
    this.name = 'RouteServiceError';
    this.statusCode = statusCode;
    this.code = code;
  }
}

/**
 * Defence in depth: even if an upstream error text ever contained the key (for
 * example because Google echoed the request URL back), it can never leave the
 * process. Any `key=` query parameter and any Google-style API key literal is
 * replaced before the text is logged or returned.
 */
function redactApiKey(text) {
  if (text === undefined || text === null) return '';

  let output = String(text);
  const key = env.GOOGLE_ROUTES_API_KEY;

  if (key) {
    output = output.split(key).join('[REDACTED]');
  }
  output = output.replace(/([?&]key=)[^&\s"']+/gi, '$1[REDACTED]');
  output = output.replace(/AIza[0-9A-Za-z_-]{10,}/g, '[REDACTED]');
  return output;
}

function isConfigured() {
  return Boolean(env.GOOGLE_ROUTES_API_KEY);
}

function buildRequestBody({ origin, destination }) {
  return {
    origin: {
      location: {
        latLng: {
          latitude: origin.latitude,
          longitude: origin.longitude,
        },
      },
    },
    destination: {
      location: {
        latLng: {
          latitude: destination.latitude,
          longitude: destination.longitude,
        },
      },
    },
    travelMode: ROUTE_REQUEST_OPTIONS.travelMode,
    routingPreference: ROUTE_REQUEST_OPTIONS.routingPreference,
    computeAlternativeRoutes: ROUTE_REQUEST_OPTIONS.computeAlternativeRoutes,
    units: ROUTE_REQUEST_OPTIONS.units,
    languageCode: env.GOOGLE_ROUTES_LANGUAGE_CODE,
  };
}

/**
 * Routes API durations are protobuf durations serialized as `"165s"`.
 * gRPC-style `{ seconds: 165 }` objects are accepted as well.
 */
function parseDurationSeconds(duration) {
  if (duration === undefined || duration === null) return null;

  if (typeof duration === 'number' && Number.isFinite(duration)) {
    return Math.round(duration);
  }

  if (typeof duration === 'object') {
    const seconds = Number(duration.seconds);
    return Number.isFinite(seconds) ? Math.round(seconds) : null;
  }

  const match = /^(\d+(?:\.\d+)?)s$/.exec(String(duration).trim());
  if (!match) return null;

  return Math.round(Number(match[1]));
}

/** "7.4 km" / "740 m" — metric, matching `units: METRIC`. */
function formatDistance(meters) {
  if (!Number.isFinite(meters)) return '';
  if (meters < 1000) return `${Math.round(meters)} m`;
  return `${(meters / 1000).toFixed(1)} km`;
}

/** "18 min" / "1 h 5 min" / "45 s" — derived from Google's own duration. */
function formatDuration(totalSeconds) {
  if (!Number.isFinite(totalSeconds)) return '';
  if (totalSeconds < 60) return `${Math.round(totalSeconds)} s`;

  const totalMinutes = Math.round(totalSeconds / 60);
  if (totalMinutes < 60) return `${totalMinutes} min`;

  const hours = Math.floor(totalMinutes / 60);
  const minutes = totalMinutes % 60;
  return minutes === 0 ? `${hours} h` : `${hours} h ${minutes} min`;
}

async function readJsonSafely(response) {
  try {
    return await response.json();
  } catch (error) {
    return null;
  }
}

function upstreamMessage(payload) {
  if (!payload || typeof payload !== 'object') return '';
  if (payload.error && typeof payload.error === 'object') {
    return String(payload.error.message || payload.error.status || '');
  }
  return String(payload.message || '');
}

/**
 * Computes a single DRIVE route between two coordinates.
 *
 * Returns only what the ERAS UI needs:
 *   { distanceMeters, durationSeconds, duration, encodedPolyline,
 *     distanceText, durationText }
 *
 * Throws RouteServiceError (with an HTTP statusCode) on any failure; the
 * message is always redacted.
 */
async function computeRoute({ origin, destination }) {
  if (!isConfigured()) {
    throw new RouteServiceError(
      'Routing is not configured on the server. Set GOOGLE_ROUTES_API_KEY in the backend environment.',
      { statusCode: 503, code: 'ROUTES_NOT_CONFIGURED' }
    );
  }

  const fetchImpl = globalThis.fetch;
  if (typeof fetchImpl !== 'function') {
    throw new RouteServiceError(
      'This Node.js runtime has no global fetch available for the Routes API.',
      { statusCode: 500, code: 'ROUTES_RUNTIME_UNSUPPORTED' }
    );
  }

  const controller =
    typeof AbortController === 'function' ? new AbortController() : null;
  const timeout = controller
    ? setTimeout(() => controller.abort(), env.GOOGLE_ROUTES_TIMEOUT_MS)
    : null;

  let response;
  try {
    response = await fetchImpl(env.GOOGLE_ROUTES_API_URL, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        // The server key never leaves this request.
        'X-Goog-Api-Key': env.GOOGLE_ROUTES_API_KEY,
        'X-Goog-FieldMask': ROUTES_FIELD_MASK,
      },
      body: JSON.stringify(buildRequestBody({ origin, destination })),
      signal: controller ? controller.signal : undefined,
    });
  } catch (error) {
    const aborted = error && (error.name === 'AbortError' || error.code === 'ABORT_ERR');
    throw new RouteServiceError(
      aborted
        ? 'The Google Routes API request timed out.'
        : `The Google Routes API could not be reached: ${redactApiKey(error && error.message)}`,
      { statusCode: 502, code: aborted ? 'ROUTES_TIMEOUT' : 'ROUTES_UNREACHABLE' }
    );
  } finally {
    if (timeout) clearTimeout(timeout);
  }

  const payload = await readJsonSafely(response);

  if (!response.ok) {
    const detail = redactApiKey(upstreamMessage(payload)).trim();
    throw new RouteServiceError(
      `Google Routes API error (HTTP ${response.status})${detail ? `: ${detail}` : '.'}`,
      { statusCode: 502, code: 'ROUTES_UPSTREAM_ERROR' }
    );
  }

  const routes = payload && Array.isArray(payload.routes) ? payload.routes : [];
  const route = routes[0];
  if (!route) {
    throw new RouteServiceError(
      'Google returned no drivable route between these coordinates.',
      { statusCode: 404, code: 'ROUTE_NOT_FOUND' }
    );
  }

  const distanceMeters = Number(route.distanceMeters);
  const durationSeconds = parseDurationSeconds(route.duration);
  const encodedPolyline =
    route.polyline && typeof route.polyline.encodedPolyline === 'string'
      ? route.polyline.encodedPolyline
      : '';

  if (!Number.isFinite(distanceMeters) || durationSeconds === null || !encodedPolyline) {
    throw new RouteServiceError(
      'Google returned an incomplete route (distance, duration or polyline missing).',
      { statusCode: 502, code: 'ROUTE_INCOMPLETE' }
    );
  }

  return {
    distanceMeters: Math.round(distanceMeters),
    durationSeconds,
    // Google's own duration string, preserved verbatim ("1080s").
    duration: typeof route.duration === 'string' ? route.duration : `${durationSeconds}s`,
    encodedPolyline,
    // Optional localized readouts, derived from Google's numbers only.
    distanceText: formatDistance(distanceMeters),
    durationText: formatDuration(durationSeconds),
  };
}

module.exports = {
  ROUTES_FIELD_MASK,
  ROUTE_REQUEST_OPTIONS,
  RouteServiceError,
  buildRequestBody,
  computeRoute,
  formatDistance,
  formatDuration,
  isConfigured,
  parseDurationSeconds,
  redactApiKey,
};
