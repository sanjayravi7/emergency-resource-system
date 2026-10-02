const http = require('http');
const app = require('./app');
const env = require('./config/env');
const logger = require('./config/logger');
const { createSocketServer } = require('./realtime/socketServer');
const { expireUnattendedRequests } = require('./services/emergencyExpiryService');
const { pruneExpiredCodes } = require('./services/authCodeService');

// ---------------------------------------------------------------------------
// BACKGROUND MAINTENANCE (best effort, never the source of truth)
//
// Request expiry is authoritative in PostgreSQL (durable `expiresAt` plus
// enforcement on every request listing), so this timer only makes the
// transition prompt. If the Render service sleeps or restarts, nothing is
// missed: the next retrieval re-applies the same policy. The interval is
// intentionally coarse (once a minute) and unref'd so it can never keep the
// process alive or block shutdown.
// ---------------------------------------------------------------------------
const EXPIRY_SWEEP_INTERVAL_MS = 60 * 1000;
const AUTH_CODE_PRUNE_INTERVAL_MS = 60 * 60 * 1000;

function startMaintenanceTasks() {
  const sweep = setInterval(() => {
    expireUnattendedRequests().catch((error) =>
      logger.warn('request.expiry_sweep_failed', { message: error?.message })
    );
  }, EXPIRY_SWEEP_INTERVAL_MS);

  const prune = setInterval(() => {
    pruneExpiredCodes().catch(() => {});
  }, AUTH_CODE_PRUNE_INTERVAL_MS);

  // Never hold the event loop open on these housekeeping timers.
  if (typeof sweep.unref === 'function') sweep.unref();
  if (typeof prune.unref === 'function') prune.unref();

  return () => {
    clearInterval(sweep);
    clearInterval(prune);
  };
}

function createServer({ maintenance = true } = {}) {
  const httpServer = http.createServer(app);
  // The Socket.IO CORS origin follows the same configurable allowlist as the
  // REST API (CORS_ORIGINS). Unset -> reflect any origin (historical behaviour).
  const io = createSocketServer(httpServer, { origin: env.CORS_ORIGIN });
  const stopMaintenance = maintenance ? startMaintenanceTasks() : () => {};
  return { httpServer, io, stopMaintenance };
}

if (require.main === module) {
  const { httpServer } = createServer();
  httpServer.listen(env.PORT, '0.0.0.0', () => {
    logger.info('server.started', { port: env.PORT, env: env.NODE_ENV });
  });
}

module.exports = { createServer, startMaintenanceTasks, EXPIRY_SWEEP_INTERVAL_MS };
