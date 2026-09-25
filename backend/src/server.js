const http = require('http');
const app = require('./app');
const env = require('./config/env');
const { createSocketServer } = require('./realtime/socketServer');

function createServer() {
  const httpServer = http.createServer(app);
  const io = createSocketServer(httpServer);
  return { httpServer, io };
}

if (require.main === module) {
  const { httpServer } = createServer();
  httpServer.listen(env.PORT, '0.0.0.0', () => {
    console.log(`Server running on port ${env.PORT}`);
  });
}

module.exports = { createServer };
