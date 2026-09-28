require("dotenv").config();

const NODE_ENV = process.env.NODE_ENV || "development";
const IS_PRODUCTION = NODE_ENV === "production";
const IS_TEST = NODE_ENV === "test";

function integerFromEnv(name, fallback, { min = 0 } = {}) {
  const raw = process.env[name];
  if (raw === undefined || raw === null || raw === '') return fallback;

  const value = Number(raw);
  if (!Number.isInteger(value) || value < min) return fallback;
  return value;
}

function booleanFromEnv(name, fallback) {
  const raw = process.env[name];
  if (raw === undefined || raw === null || raw === '') return fallback;
  return /^(1|true|yes|on)$/i.test(String(raw).trim());
}

/**
 * `trust proxy` controls whether Express (and express-rate-limit) trusts the
 * X-Forwarded-* headers set by a reverse proxy / load balancer. It is required
 * in production so client IPs used for rate limiting are the real client, not
 * the proxy. Accepts a boolean, an integer hop count, or a subnet string.
 */
function trustProxyFromEnv() {
  const raw = process.env.TRUST_PROXY;
  if (raw === undefined || raw === null || raw === '') {
    // Behind a managed proxy in production; direct-connect in local dev.
    return IS_PRODUCTION ? 1 : false;
  }
  const trimmed = String(raw).trim();
  if (/^\d+$/.test(trimmed)) return Number(trimmed);
  if (/^(true|yes|on)$/i.test(trimmed)) return true;
  if (/^(false|no|off)$/i.test(trimmed)) return false;
  return trimmed; // e.g. 'loopback' or an explicit subnet
}

/**
 * CORS origins. Unset -> reflect any origin (preserves the historical
 * same-origin Flutter web + native client behaviour). A comma separated list
 * locks the API to a known allowlist. `*` is treated as "allow all".
 */
function corsOriginFromEnv() {
  const raw = process.env.CORS_ORIGINS;
  if (raw === undefined || raw === null || raw.trim() === '' || raw.trim() === '*') {
    return true;
  }
  return raw
    .split(',')
    .map((origin) => origin.trim())
    .filter(Boolean);
}

// Secrets that must never be used in production. Kept short and lowercased.
const WEAK_SECRETS = new Set([
  'change-me',
  'changeme',
  'secret',
  'jwt-secret',
  'password',
  'test',
  'test-secret',
  'dev',
  'development',
]);
const MIN_PRODUCTION_SECRET_LENGTH = 32;

function isWeakSecret(secret) {
  if (!secret) return true;
  const normalized = String(secret).trim().toLowerCase();
  if (WEAK_SECRETS.has(normalized)) return true;
  if (String(secret).length < MIN_PRODUCTION_SECRET_LENGTH) return true;
  return false;
}

const env = {
  NODE_ENV,
  IS_PRODUCTION,
  IS_TEST,

  PORT: process.env.PORT || 5000,
  DATABASE_URL: process.env.DATABASE_URL,
  JWT_SECRET: process.env.JWT_SECRET,
  JWT_EXPIRES_IN: process.env.JWT_EXPIRES_IN || "7d",

  // HTTP hardening knobs.
  TRUST_PROXY: trustProxyFromEnv(),
  CORS_ORIGIN: corsOriginFromEnv(),
  JSON_BODY_LIMIT: (process.env.JSON_BODY_LIMIT || '100kb').trim(),

  // Auth / abuse rate limiting (REST). Location + dispatch traffic is
  // deliberately excluded so emergency GPS streams are never throttled here.
  AUTH_RATE_WINDOW_MS: integerFromEnv('AUTH_RATE_WINDOW_MS', 15 * 60 * 1000, { min: 1000 }),
  AUTH_RATE_MAX: integerFromEnv('AUTH_RATE_MAX', 30, { min: 1 }),
  API_RATE_WINDOW_MS: integerFromEnv('API_RATE_WINDOW_MS', 60 * 1000, { min: 1000 }),
  API_RATE_MAX: integerFromEnv('API_RATE_MAX', 600, { min: 1 }),
  // Rate limiting is disabled during automated tests so the integration suite
  // can drive endpoints at full speed. Can be forced on with RATE_LIMIT_ENABLED.
  RATE_LIMIT_ENABLED: booleanFromEnv('RATE_LIMIT_ENABLED', !IS_TEST),

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

  // Photon public reverse-geocoding service. This is server-side only; no
  // Google Geocoding key is used or sent to Flutter.
  PHOTON_REVERSE_URL: (process.env.PHOTON_REVERSE_URL || 'https://photon.komoot.io/reverse').trim(),
  PHOTON_USER_AGENT: (process.env.PHOTON_USER_AGENT || 'ERAS/1.0 (reverse geocoding)').trim(),
  PHOTON_TIMEOUT_MS: integerFromEnv('PHOTON_TIMEOUT_MS', 5000, { min: 500 }),

  // ---------------------------------------------------------------------------
  // Firebase Cloud Messaging (FCM) push notifications for responders.
  //
  // FCM is an OPTIONAL add-on transport: Socket.IO stays the foreground
  // channel and the EmergencyRequest row in PostgreSQL remains the single
  // source of truth. When none of these variables is set, push sending is a
  // logged no-op and every other feature works unchanged.
  //
  // Credentials are read (in order):
  //   1. FCM_SERVICE_ACCOUNT - inline JSON of a Firebase service-account key
  //      (handy for hosts that only expose plain env vars), or
  //   2. FCM_SERVICE_ACCOUNT_FILE / GOOGLE_APPLICATION_CREDENTIALS - path to
  //      the JSON key file on disk.
  // NEVER commit the key file or its contents; production reads it from the
  // environment/secret store. backend/.gitignore already ignores .env.
  // ---------------------------------------------------------------------------
  FCM_SERVICE_ACCOUNT: process.env.FCM_SERVICE_ACCOUNT || null,
  FCM_SERVICE_ACCOUNT_FILE:
    process.env.FCM_SERVICE_ACCOUNT_FILE || process.env.GOOGLE_APPLICATION_CREDENTIALS || null,
  FCM_SEND_TIMEOUT_MS: integerFromEnv('FCM_SEND_TIMEOUT_MS', 10000, { min: 500 }),
};

if (!env.DATABASE_URL) {
  throw new Error("DATABASE_URL is missing in .env");
}

if (!env.JWT_SECRET) {
  throw new Error("JWT_SECRET is missing in .env");
}

// Production must never boot with a guessable/short signing secret. A leaked or
// default secret lets anyone forge tokens for any role. Outside production this
// is a warning so local development and the test suite stay frictionless.
if (isWeakSecret(env.JWT_SECRET)) {
  const detail =
    `JWT_SECRET is weak or a known default. Use a random secret of at least ` +
    `${MIN_PRODUCTION_SECRET_LENGTH} characters (e.g. \`openssl rand -base64 48\`).`;
  if (IS_PRODUCTION) {
    throw new Error(detail);
  }
  // eslint-disable-next-line no-console
  console.warn(`[config] WARNING: ${detail}`);
}

module.exports = env;
module.exports.isWeakSecret = isWeakSecret;
