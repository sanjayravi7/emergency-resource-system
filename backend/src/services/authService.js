const bcrypt = require('bcrypt');
const crypto = require('crypto');
const jwt = require('jsonwebtoken');

const prisma = require('../config/prisma');
const env = require('../config/env');
const firebaseAdmin = require('../config/firebaseAdmin');
const authEmailService = require('./authEmailService');
const authChallengeService = require('./authChallengeService');

const SALT_ROUNDS = 10;

// Roles that PUBLIC registration may create. ADMIN is deliberately absent:
// administrative accounts must be provisioned through the existing
// administrator-controlled workflow.
const PUBLIC_REGISTRATION_ROLES = ['REQUESTER', 'RESPONDER'];

function createToken(user) {
  return jwt.sign(
    { userId: user.id, role: user.role },
    env.JWT_SECRET,
    { expiresIn: env.JWT_EXPIRES_IN }
  );
}

function toPublicUser(user) {
  return {
    id: user.id,
    name: user.name,
    email: user.email,
    phone: user.phone,
    role: user.role,
    location: user.location,
    latitude: user.latitude,
    longitude: user.longitude,
    isActive: user.isActive,
    emailVerified: user.emailVerified,
    lastActiveAt: user.lastActiveAt,
    responderStatus: user.responderStatus,
    createdAt: user.createdAt,
  };
}

function resolvePublicRegistrationRole(role) {
  const normalized = typeof role === 'string' ? role.trim() : '';
  if (!normalized) throw new Error('REGISTRATION_ROLE_REQUIRED');
  if (!PUBLIC_REGISTRATION_ROLES.includes(normalized)) {
    throw new Error('INVALID_REGISTRATION_ROLE');
  }
  return normalized;
}

function normalizeEmail(email) {
  return String(email || '').trim().toLowerCase();
}

function isPrismaUniqueConstraint(error) {
  return error?.code === 'P2002';
}

async function registerUser({ name, email, password, phone, location, role }) {
  if (!authEmailService.isConfigured()) {
    throw new Error('AUTH_EMAIL_NOT_CONFIGURED');
  }

  const normalizedEmail = normalizeEmail(email);
  const userRole = resolvePublicRegistrationRole(role);
  const existingUser = await prisma.user.findUnique({
    where: { email: normalizedEmail },
  });
  if (existingUser) throw new Error('EMAIL_ALREADY_EXISTS');

  const hashedPassword = await bcrypt.hash(password, SALT_ROUNDS);
  let user;
  try {
    user = await prisma.user.create({
      data: {
        name: name.trim(),
        email: normalizedEmail,
        password: hashedPassword,
        phone: phone || null,
        location: location || null,
        role: userRole,
        emailVerified: false,
      },
    });
  } catch (error) {
    if (isPrismaUniqueConstraint(error)) throw new Error('EMAIL_ALREADY_EXISTS');
    throw error;
  }

  try {
    await authChallengeService.issueChallenge(user, 'EMAIL_VERIFICATION');
  } catch (error) {
    // Do not leave an account that cannot complete the promised verification
    // step when delivery fails. A client can retry registration safely.
    await prisma.user.delete({ where: { id: user.id } }).catch(() => {});
    throw error;
  }

  return {
    user: toPublicUser(user),
    verificationRequired: true,
  };
}

async function loginUser({ email, password }) {
  const normalizedEmail = normalizeEmail(email);
  const user = await prisma.user.findUnique({ where: { email: normalizedEmail } });

  if (!user) throw new Error('INVALID_CREDENTIALS');
  if (!user.isActive) throw new Error('ACCOUNT_INACTIVE');

  const passwordValid = await bcrypt.compare(password, user.password);
  if (!passwordValid) throw new Error('INVALID_CREDENTIALS');
  if (!user.emailVerified) throw new Error('EMAIL_NOT_VERIFIED');

  const updatedUser = await prisma.user.update({
    where: { id: user.id },
    data: { lastActiveAt: new Date() },
  });

  return {
    user: toPublicUser(updatedUser),
    token: createToken(updatedUser),
  };
}

async function googleLoginUser({ idToken, intent, role }) {
  if (intent !== 'login' && intent !== 'register') {
    throw new Error('INVALID_GOOGLE_INTENT');
  }

  const identity = await firebaseAdmin.verifyGoogleIdToken(idToken);
  const normalizedEmail = normalizeEmail(identity.email);
  const userRole = intent === 'register' ? resolvePublicRegistrationRole(role) : null;
  let user = await prisma.user.findUnique({ where: { firebaseUid: identity.uid } });

  if (user && intent === 'register') throw new Error('EMAIL_ALREADY_EXISTS');
  if (!user) {
    user = await prisma.user.findUnique({ where: { email: normalizedEmail } });
    if (user && intent === 'register') throw new Error('EMAIL_ALREADY_EXISTS');
    if (!user && intent === 'login') throw new Error('GOOGLE_ACCOUNT_NOT_REGISTERED');
    // Do not silently convert an existing local-password account to Google
    // auth based only on matching email. A future explicit link operation must
    // first require the existing ERAS JWT/password session.
    if (user && !user.firebaseUid) throw new Error('GOOGLE_ACCOUNT_NOT_LINKED');
  }

  if (user) {
    if (!user.isActive) throw new Error('ACCOUNT_INACTIVE');
    if (user.firebaseUid !== identity.uid) {
      throw new Error('GOOGLE_ACCOUNT_CONFLICT');
    }

    // Firebase UID is the stable provider mapping. A verified Google email
    // change may update the ERAS address only when it does not collide with
    // another PostgreSQL account; ERAS still issues its normal JWT.
    if (user.email !== normalizedEmail) {
      const emailOwner = await prisma.user.findUnique({
        where: { email: normalizedEmail },
        select: { id: true },
      });
      if (emailOwner && emailOwner.id !== user.id) {
        throw new Error('GOOGLE_ACCOUNT_CONFLICT');
      }
    }

    const update = {
      email: normalizedEmail,
      emailVerified: true,
      lastActiveAt: new Date(),
    };
    if (identity.name && !user.name.trim()) update.name = identity.name;
    try {
      user = await prisma.user.update({ where: { id: user.id }, data: update });
    } catch (error) {
      if (isPrismaUniqueConstraint(error)) throw new Error('GOOGLE_ACCOUNT_CONFLICT');
      throw error;
    }
  } else {
    // The schema still requires a password because email/password remains an
    // existing supported sign-in method. This unguessable hash is not exposed;
    // a user may explicitly set a local password later via the email reset flow.
    const randomPassword = crypto.randomBytes(48).toString('base64url');
    const passwordHash = await bcrypt.hash(randomPassword, SALT_ROUNDS);
    const safeName = identity.name || normalizedEmail.split('@')[0] || 'ERAS user';
    try {
      user = await prisma.user.create({
        data: {
          name: safeName,
          email: normalizedEmail,
          password: passwordHash,
          role: userRole,
          emailVerified: true,
          firebaseUid: identity.uid,
        },
      });
    } catch (error) {
      if (isPrismaUniqueConstraint(error)) throw new Error('EMAIL_ALREADY_EXISTS');
      throw error;
    }
  }

  return {
    user: toPublicUser(user),
    token: createToken(user),
  };
}

async function resendEmailVerification(email) {
  if (!authEmailService.isConfigured()) throw new Error('AUTH_EMAIL_NOT_CONFIGURED');
  const user = await prisma.user.findUnique({ where: { email: normalizeEmail(email) } });
  if (!user || user.emailVerified || !user.isActive) return { accepted: true };

  try {
    await authChallengeService.issueChallenge(user, 'EMAIL_VERIFICATION');
  } catch (error) {
    if (error.code !== 'AUTH_CODE_RATE_LIMITED') throw error;
  }
  return { accepted: true };
}

async function verifyEmail({ email, code }) {
  const user = await prisma.user.findUnique({ where: { email: normalizeEmail(email) } });
  if (!user || !user.isActive) throw new Error('AUTH_CODE_INVALID');
  if (user.emailVerified) return { emailVerified: true };

  await authChallengeService.consumeChallenge({
    userId: user.id,
    purpose: 'EMAIL_VERIFICATION',
    code,
    transaction: async (tx) => {
      await tx.user.update({
        where: { id: user.id },
        data: { emailVerified: true },
      });
    },
  });

  return { emailVerified: true };
}

async function requestPasswordReset(email) {
  if (!authEmailService.isConfigured()) throw new Error('AUTH_EMAIL_NOT_CONFIGURED');
  const user = await prisma.user.findUnique({ where: { email: normalizeEmail(email) } });
  if (!user || !user.isActive || !user.emailVerified) return { accepted: true };

  try {
    await authChallengeService.issueChallenge(user, 'PASSWORD_RESET');
  } catch (error) {
    if (error.code !== 'AUTH_CODE_RATE_LIMITED') throw error;
  }
  return { accepted: true };
}

async function completePasswordReset({ email, code, password }) {
  const user = await prisma.user.findUnique({ where: { email: normalizeEmail(email) } });
  if (!user || !user.isActive || !user.emailVerified) {
    throw new Error('AUTH_CODE_INVALID');
  }
  const passwordHash = await bcrypt.hash(password, SALT_ROUNDS);

  await authChallengeService.consumeChallenge({
    userId: user.id,
    purpose: 'PASSWORD_RESET',
    code,
    transaction: async (tx) => {
      await tx.user.update({
        where: { id: user.id },
        data: { password: passwordHash },
      });
      await tx.authChallenge.updateMany({
        where: {
          userId: user.id,
          purpose: 'PASSWORD_RESET',
          consumedAt: null,
        },
        data: { consumedAt: new Date() },
      });
    },
  });

  return { passwordReset: true };
}

async function getCurrentUser(userId) {
  return prisma.user.findUnique({
    where: { id: userId },
    select: {
      id: true,
      name: true,
      email: true,
      phone: true,
      role: true,
      location: true,
      latitude: true,
      longitude: true,
      isActive: true,
      emailVerified: true,
      lastActiveAt: true,
      responderStatus: true,
      createdAt: true,
      updatedAt: true,
    },
  });
}

module.exports = {
  registerUser,
  loginUser,
  googleLoginUser,
  resendEmailVerification,
  verifyEmail,
  requestPasswordReset,
  completePasswordReset,
  getCurrentUser,
};
