const logger = require('../config/logger');

const authorizeRoles = (...allowedRoles) => {
  return (req, res, next) => {
    if (!req.user) {
      return res.status(401).json({ success: false, message: 'Authentication required' });
    }
    if (!allowedRoles.includes(req.user.role)) {
      logger.warn('authz.denied', {
        userId: req.user.id,
        role: req.user.role,
        required: allowedRoles,
        method: req.method,
        path: req.originalUrl,
      });
      return res.status(403).json({ success: false, message: 'Access denied' });
    }
    next();
  };
};
module.exports = authorizeRoles;
