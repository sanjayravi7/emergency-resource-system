const bcrypt = require("bcrypt");
const jwt = require("jsonwebtoken");

const prisma = require("../config/prisma");
const env = require("../config/env");

const SALT_ROUNDS = 10;

// Roles that PUBLIC registration may create. ADMIN is deliberately absent:
// administrative accounts must be provisioned through an authenticated,
// administrator-controlled workflow. The client-supplied role field is never
// trusted as-is; it must match this allowlist exactly (no case folding, no
// unknown values) so public signup can never escalate privileges.
const PUBLIC_REGISTRATION_ROLES = ["REQUESTER", "RESPONDER"];

function createToken(user) {
  return jwt.sign(
    {
      userId: user.id,
      role: user.role,
    },
    env.JWT_SECRET,
    {
      expiresIn: env.JWT_EXPIRES_IN,
    }
  );
}

// Resolve the role for a public registration. Throws a stable error code the
// controller maps to a 400 - this is the security boundary, the validator in
// authValidator.js only provides the friendly message for normal clients.
function resolvePublicRegistrationRole(role) {
  const normalized = typeof role === "string" ? role.trim() : "";

  if (!normalized) {
    throw new Error("REGISTRATION_ROLE_REQUIRED");
  }

  if (!PUBLIC_REGISTRATION_ROLES.includes(normalized)) {
    throw new Error("INVALID_REGISTRATION_ROLE");
  }

  // Return the exact allowlisted constant, never the raw client value, so no
  // arbitrary enum can be injected into the create call below.
  return normalized;
}

async function registerUser({
  name,
  email,
  password,
  phone,
  location,
  role,
}) {
  const normalizedEmail = email.trim().toLowerCase();

  const userRole = resolvePublicRegistrationRole(role);

  const existingUser = await prisma.user.findUnique({
    where: {
      email: normalizedEmail,
    },
  });

  if (existingUser) {
    throw new Error("EMAIL_ALREADY_EXISTS");
  }

  const hashedPassword = await bcrypt.hash(
    password,
    SALT_ROUNDS
  );

  // A RESPONDER created through public registration starts exactly like any
  // other responder account: responderStatus OFFLINE and zero
  // ResponderResource rows. Capabilities/resources are provisioned later
  // through the existing responder readiness / responder-resources workflow -
  // registration never fabricates capabilities or availability.
  const user = await prisma.user.create({
    data: {
      name: name.trim(),
      email: normalizedEmail,
      password: hashedPassword,
      phone: phone || null,
      location: location || null,
      role: userRole,
    },
  });

  const token = createToken(user);

  return {
    user: {
      id: user.id,
      name: user.name,
      email: user.email,
      phone: user.phone,
      role: user.role,
      location: user.location,
      latitude: user.latitude,
      longitude: user.longitude,
      isActive: user.isActive,
      lastActiveAt: user.lastActiveAt,
      responderStatus: user.responderStatus,
      createdAt: user.createdAt,
    },
    token,
  };
}

async function loginUser({ email, password }) {
  const normalizedEmail = email.trim().toLowerCase();

  const user = await prisma.user.findUnique({
    where: {
      email: normalizedEmail,
    },
  });

  if (!user) {
    throw new Error("INVALID_CREDENTIALS");
  }

  if (!user.isActive) {
    throw new Error("ACCOUNT_INACTIVE");
  }

  const passwordValid = await bcrypt.compare(
    password,
    user.password
  );

  if (!passwordValid) {
    throw new Error("INVALID_CREDENTIALS");
  }

  const updatedUser = await prisma.user.update({
    where: {
      id: user.id,
    },
    data: {
      lastActiveAt: new Date(),
    },
  });

  const token = createToken(updatedUser);

  return {
    user: {
      id: updatedUser.id,
      name: updatedUser.name,
      email: updatedUser.email,
      phone: updatedUser.phone,
      role: updatedUser.role,
      location: updatedUser.location,
      latitude: updatedUser.latitude,
      longitude: updatedUser.longitude,
      isActive: updatedUser.isActive,
      lastActiveAt: updatedUser.lastActiveAt,
      responderStatus: updatedUser.responderStatus,
    },
    token,
  };
}

async function getCurrentUser(userId) {
  return prisma.user.findUnique({
    where: {
      id: userId,
    },
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
  getCurrentUser,
};