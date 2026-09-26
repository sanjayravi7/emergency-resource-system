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
};

if (!env.DATABASE_URL) {
  throw new Error("DATABASE_URL is missing in .env");
}

if (!env.JWT_SECRET) {
  throw new Error("JWT_SECRET is missing in .env");
}

module.exports = env;
