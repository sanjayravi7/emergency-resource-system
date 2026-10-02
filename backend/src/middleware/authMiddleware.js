const jwt = require("jsonwebtoken");
const env = require("../config/env");
const prisma = require("../config/prisma");
const logger = require("../config/logger");

async function authMiddleware(req, res, next) {
  try {
    const authHeader = req.headers.authorization;

    if (!authHeader) {
      return res.status(401).json({
        success: false,
        message: "Authorization token required",
      });
    }

    const [type, token] = authHeader.split(" ");

    if (type !== "Bearer" || !token) {
      return res.status(401).json({
        success: false,
        message: "Invalid authorization format",
      });
    }

    const decoded = jwt.verify(token, env.JWT_SECRET);

    const userId = Number(decoded.userId);
    if (!Number.isInteger(userId) || userId <= 0) {
      return res.status(401).json({
        success: false,
        message: "Invalid or expired token",
      });
    }

    const user = await prisma.user.findUnique({
      where: {
        id: userId,
      },
      select: {
        id: true,
        role: true,
        isActive: true,
        passwordChangedAt: true,
      },
    });

    if (!user) {
      return res.status(401).json({
        success: false,
        message: "User not found",
      });
    }

    if (!user.isActive) {
      logger.warn("auth.inactive_user_rejected", { userId: user.id });
      return res.status(401).json({
        success: false,
        message: "User is inactive",
      });
    }

    // SESSION EPOCH: a password reset/change stamps passwordChangedAt. Every
    // token issued before that instant is rejected here, so a stolen or
    // already-open session cannot survive a credential rotation. The check is
    // one extra comparison on data that is already loaded.
    if (user.passwordChangedAt) {
      const issuedAtSeconds = Number(decoded.iat);
      const changedAtSeconds = Math.floor(new Date(user.passwordChangedAt).getTime() / 1000);
      if (!Number.isFinite(issuedAtSeconds) || issuedAtSeconds < changedAtSeconds) {
        logger.warn('auth.stale_session_rejected', { userId: user.id });
        return res.status(401).json({
          success: false,
          message: 'Session expired, please sign in again',
        });
      }
    }

    // Role and identity are sourced from the CURRENT database record, never
    // from the (client-presented) token claims. A demoted or role-changed user
    // therefore loses/gains privileges immediately, and a tampered token cannot
    // assert a role the account does not hold.
    req.user = {
      ...decoded,
      id: user.id,
      userId: user.id,
      role: user.role,
    };

    next();
  } catch (error) {
    return res.status(401).json({
      success: false,
      message: "Invalid or expired token",
    });
  }
}

module.exports = authMiddleware;
