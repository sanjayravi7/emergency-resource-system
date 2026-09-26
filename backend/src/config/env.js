require("dotenv").config();

function integerFromEnv(name, fallback, { min = 0 } = {}) {
  const raw = process.env[name];
  if (raw === undefined || raw === null || raw === '') return fallback;

  const value = Number(raw);
  if (!Number.isInteger(value) || value < min) return fallback;
  return value;
}

const env = {
  PORT: process.env.PORT || 5000,
  DATABASE_URL: process.env.DATABASE_URL,
  JWT_SECRET: process.env.JWT_SECRET,
  JWT_EXPIRES_IN: process.env.JWT_EXPIRES_IN || "7d",

  // Socket.IO location controls. High-frequency GPS remains a realtime
  // stream; PostgreSQL stores only a throttled latest known point.
  SOCKET_LOCATION_PERSIST_INTERVAL_MS: integerFromEnv(
    'SOCKET_LOCATION_PERSIST_INTERVAL_MS',
    10000,
    { min: 1000 }
  ),
  SOCKET_LOCATION_RATE_WINDOW_MS: integerFromEnv(
    'SOCKET_LOCATION_RATE_WINDOW_MS',
    1000,
    { min: 250 }
  ),
  SOCKET_LOCATION_MAX_UPDATES_PER_WINDOW: integerFromEnv(
    'SOCKET_LOCATION_MAX_UPDATES_PER_WINDOW',
    10,
    { min: 1 }
  ),

  // Connected sockets periodically re-read PostgreSQL so deactivated users do
  // not keep a previously valid JWT-authorized realtime session forever.
  SOCKET_SESSION_REVALIDATE_MS: integerFromEnv(
    'SOCKET_SESSION_REVALIDATE_MS',
    30000,
    { min: 5000 }
  ),

  // ---------------------------------------------------------------------
  // Google Routes API (server side only)
  //
  // This key is DIFFERENT from the browser Maps JavaScript key used by
  // Flutter Web (frontend/emergency_app/web/google_maps_config.js):
  //
  //   * browser key  -> Maps JavaScript API + Places API (New) + Geocoding
  //                     API, restricted by HTTP referrer, necessarily public.
  //   * server key   -> Routes API only, restricted by IP (or unrestricted in
  //                     development), and never shipped to the browser.
  //
  // The key is read from the environment only. It is never returned by an
  // endpoint, never logged and never sent to the Flutter client.
  // ---------------------------------------------------------------------
  GOOGLE_ROUTES_API_KEY: (process.env.GOOGLE_ROUTES_API_KEY || '').trim(),
  GOOGLE_ROUTES_API_URL:
    (process.env.GOOGLE_ROUTES_API_URL || '').trim() ||
    'https://routes.googleapis.com/directions/v2:computeRoutes',
  GOOGLE_ROUTES_LANGUAGE_CODE:
    (process.env.GOOGLE_ROUTES_LANGUAGE_CODE || '').trim() || 'en-US',
  GOOGLE_ROUTES_TIMEOUT_MS: integerFromEnv(
    'GOOGLE_ROUTES_TIMEOUT_MS',
    8000,
    { min: 1000 }
  ),

  // Photon public reverse-geocoding service. This is server-side only; no
  // Google Geocoding key is used or sent to Flutter.
  PHOTON_REVERSE_URL: (process.env.PHOTON_REVERSE_URL || 'https://photon.komoot.io/reverse').trim(),
  PHOTON_USER_AGENT: (process.env.PHOTON_USER_AGENT || 'ERAS/1.0 (reverse geocoding)').trim(),
  PHOTON_TIMEOUT_MS: integerFromEnv('PHOTON_TIMEOUT_MS', 5000, { min: 500 }),
};

if (!env.DATABASE_URL) {
  throw new Error("DATABASE_URL is missing in .env");
}

if (!env.JWT_SECRET) {
  throw new Error("JWT_SECRET is missing in .env");
}

module.exports = env;
