const http = require('http');
const app = require('./app');
const env = require('./config/env');
const logger = require('./config/logger');
const { createSocketServer } = require('./realtime/socketServer');

function createServer() {
  const httpServer = http.createServer(app);
  // The Socket.IO CORS origin follows the same configurable allowlist as the
  // REST API (CORS_ORIGINS). Unset -> reflect any origin (historical behaviour).
  const io = createSocketServer(httpServer, { origin: env.CORS_ORIGIN });
  return { httpServer, io };
}

if (require.main === module) {
  const { httpServer } = createServer();
  httpServer.listen(env.PORT, '0.0.0.0', () => {
    logger.info('server.started', { port: env.PORT, env: env.NODE_ENV });
  });
}

module.exports = { createServer };
