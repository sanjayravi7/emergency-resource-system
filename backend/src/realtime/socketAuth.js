const jwt = require('jsonwebtoken');
const prisma = require('../config/prisma');
const env = require('../config/env');

function tokenFromHandshake(socket) {
  const authToken = socket.handshake?.auth?.token;
  if (typeof authToken === 'string' && authToken.trim()) return authToken.trim();

  const authorization = socket.handshake?.headers?.authorization;
  if (typeof authorization !== 'string') return null;
  const [scheme, token] = authorization.split(' ');
  return scheme === 'Bearer' && token ? token : null;
}

/**
 * Socket identity is derived from the same JWT secret as REST auth. The role
 * in the token is deliberately not trusted for authorization: the current
 * role and active state come from PostgreSQL, just as they do in the REST
 * middleware.
 */
async function authenticateSocket(socket, next) {
  try {
    const token = tokenFromHandshake(socket);
    if (!token) return next(new Error('Authentication token required'));

    const decoded = jwt.verify(token, env.JWT_SECRET);
    const userId = Number(decoded.userId);
    if (!Number.isInteger(userId) || userId <= 0) {
      return next(new Error('Invalid authenticated identity'));
    }

    const user = await prisma.user.findUnique({
      where: { id: userId },
      select: {
        id: true,
        name: true,
        role: true,
        isActive: true,
        responderStatus: true,
      },
    });

    if (!user) return next(new Error('User not found'));
    if (!user.isActive) return next(new Error('User is inactive'));

    socket.user = {
      id: user.id,
      name: user.name,
      role: user.role,
      responderStatus: user.responderStatus,
    };

    return next();
  } catch (error) {
    return next(new Error('Invalid or expired token'));
  }
}

module.exports = {
  authenticateSocket,
  tokenFromHandshake,
};
