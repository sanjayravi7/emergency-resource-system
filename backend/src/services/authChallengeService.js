const crypto = require('crypto');
const env = require('../config/env');
const prisma = require('../config/prisma');
const emailService = require('./authEmailService');

const PURPOSES = new Set(['EMAIL_VERIFICATION', 'PASSWORD_RESET']);

function codeDigest({ userId, purpose, code }) {
  return crypto
    .createHmac('sha256', env.AUTH_OTP_SECRET)
    .update(`${userId}:${purpose}:${code}`)
    .digest('hex');
}

function matchesDigest(expected, actual) {
  const expectedBytes = Buffer.from(expected, 'hex');
  const actualBytes = Buffer.from(actual, 'hex');
  return (
    expectedBytes.length === actualBytes.length &&
    crypto.timingSafeEqual(expectedBytes, actualBytes)
  );
}

function codedError(code) {
  const error = new Error(code);
  error.code = code;
  return error;
}

function createCode() {
  return String(crypto.randomInt(0, 1_000_000)).padStart(6, '0');
}

async function issueChallenge(user, purpose) {
  if (!PURPOSES.has(purpose)) throw new Error('INVALID_AUTH_CHALLENGE_PURPOSE');
  if (!emailService.isConfigured()) throw codedError('AUTH_EMAIL_NOT_CONFIGURED');

  const now = new Date();
  const recentCount = await prisma.authChallenge.count({
    where: {
      userId: user.id,
      purpose,
      createdAt: { gte: new Date(now.getTime() - 60 * 60 * 1000) },
    },
  });
  if (recentCount >= env.AUTH_OTP_MAX_ISSUES_PER_HOUR) {
    throw codedError('AUTH_CODE_RATE_LIMITED');
  }

  const code = createCode();
  await prisma.authChallenge.updateMany({
    where: { userId: user.id, purpose, consumedAt: null },
    data: { consumedAt: now },
  });

  const challenge = await prisma.authChallenge.create({
    data: {
      userId: user.id,
      purpose,
      codeHash: codeDigest({ userId: user.id, purpose, code }),
      expiresAt: new Date(now.getTime() + env.AUTH_OTP_TTL_MINUTES * 60 * 1000),
    },
  });

  try {
    await emailService.sendAuthCode({ to: user.email, purpose, code });
  } catch (error) {
    await prisma.authChallenge.updateMany({
      where: { id: challenge.id, consumedAt: null },
      data: { consumedAt: new Date() },
    });
    throw error;
  }

  return challenge;
}

async function consumeChallenge({ userId, purpose, code, transaction }) {
  if (!PURPOSES.has(purpose) || !/^\d{6}$/.test(String(code || ''))) {
    throw codedError('AUTH_CODE_INVALID');
  }

  const now = new Date();
  const challenge = await prisma.authChallenge.findFirst({
    where: {
      userId,
      purpose,
      consumedAt: null,
      expiresAt: { gt: now },
    },
    orderBy: { createdAt: 'desc' },
  });
  if (!challenge || challenge.attempts >= env.AUTH_OTP_MAX_ATTEMPTS) {
    throw codedError('AUTH_CODE_INVALID');
  }

  const suppliedDigest = codeDigest({ userId, purpose, code: String(code) });
  if (!matchesDigest(challenge.codeHash, suppliedDigest)) {
    const nextAttempts = challenge.attempts + 1;
    await prisma.authChallenge.updateMany({
      where: { id: challenge.id, consumedAt: null },
      data: {
        attempts: { increment: 1 },
        ...(nextAttempts >= env.AUTH_OTP_MAX_ATTEMPTS ? { consumedAt: now } : {}),
      },
    });
    throw codedError('AUTH_CODE_INVALID');
  }

  return prisma.$transaction(async (tx) => {
    const consumed = await tx.authChallenge.updateMany({
      where: { id: challenge.id, consumedAt: null, expiresAt: { gt: now } },
      data: { consumedAt: now },
    });
    if (consumed.count !== 1) throw codedError('AUTH_CODE_INVALID');
    return transaction(tx);
  });
}

module.exports = {
  issueChallenge,
  consumeChallenge,
  createCode,
  codeDigest,
};
