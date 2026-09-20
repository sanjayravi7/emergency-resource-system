const bcrypt = require("bcrypt");
const jwt = require("jsonwebtoken");

const prisma = require("../config/prisma");
const env = require("../config/env");

const SALT_ROUNDS = 10;

function createToken(user) {
  return jwt.sign(
    {
      userId: user.id,
      role: user.role,
    },
    env.jwtSecret,
    {
      expiresIn: env.jwtExpiresIn,
    }
  );
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

  const existingUser = await prisma.user.findUnique({
    where: {
      email: normalizedEmail,
    },
  });

  if (existingUser) {
    throw new Error("EMAIL_ALREADY_EXISTS");
  }

  // Never store the real password
  const hashedPassword = await bcrypt.hash(
    password,
    SALT_ROUNDS
  );

  // Do not allow registration as ADMIN
  const userRole =
    role === "RESPONDER" ? "RESPONDER" : "REQUESTER";

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

  // Update activity
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