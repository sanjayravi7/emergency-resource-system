const { Server } = require('socket.io');

let io = null;

const rooms = {
  user: (userId) => `user:${Number(userId)}`,
  request: (requestId) => `request:${Number(requestId)}`,
  responders: 'responders',
  admins: 'admins',
};

function attachSocketServer(httpServer, options = {}) {
  if (io) return io;

  io = new Server(httpServer, {
    cors: {
      origin: options.origin || true,
      credentials: true,
    },
    // The Flutter client uses websocket when available and Socket.IO's
    // fallback transport during reconnects. Keeping the default path makes
    // this work with the existing same-origin Flutter web deployment.
    path: options.path || '/socket.io',
  });

  return io;
}

function getIO() {
  return io;
}

function emitToRooms(eventName, payload, roomNames = []) {
  if (!io || !roomNames.length) return false;
  const uniqueRooms = [...new Set(roomNames.filter(Boolean))];
  let broadcaster = io;
  for (const roomName of uniqueRooms) broadcaster = broadcaster.to(roomName);
  broadcaster.emit(eventName, payload);
  return true;
}

function emitToRoom(eventName, payload, roomName) {
  return emitToRooms(eventName, payload, [roomName]);
}

function closeSocketServer() {
  if (!io) return Promise.resolve();
  const current = io;
  io = null;
  return new Promise((resolve) => current.close(resolve));
}

module.exports = {
  attachSocketServer,
  closeSocketServer,
  getIO,
  emitToRoom,
  emitToRooms,
  rooms,
};
