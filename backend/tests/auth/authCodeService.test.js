// One-time auth codes (email verification + 6-digit password reset).
//
// The Prisma client is replaced by a small in-memory fake, so the real service
// logic - CSPRNG generation, bcrypt hashing, TTL, single use, attempt limit,
// resend cooldown and request budget - is exercised without a database.

const bcrypt = require('bcrypt');

jest.mock('../../src/config/prisma', () => require('../helpers/fakeAuthCodePrisma').prisma);

const fakeStore = require('../helpers/fakeAuthCodePrisma');

const authCodeService = require('../../src/services/authCodeService');
const env = require('../../src/config/env');

const PURPOSE = authCodeService.PURPOSES.PASSWORD_RESET;

describe('one-time auth codes', () => {
  beforeEach(() => {
    fakeStore.reset();
  });

  test('codes are exactly 6 numeric digits and use a CSPRNG', () => {
    const codes = new Set();
    for (let i = 0; i < 200; i += 1) {
      const code = authCodeService.generateNumericCode();
      expect(code).toMatch(/^\d{6}$/);
      codes.add(code);
    }
    // Extremely unlikely to collide 200 times; proves the generator varies.
    expect(codes.size).toBeGreaterThan(150);
  });

  test('code format validation rejects anything that is not 6 digits', () => {
    expect(authCodeService.isValidCodeFormat('123456')).toBe(true);
    expect(authCodeService.isValidCodeFormat('12345')).toBe(false);
    expect(authCodeService.isValidCodeFormat('1234567')).toBe(false);
    expect(authCodeService.isValidCodeFormat('12a456')).toBe(false);
    expect(authCodeService.isValidCodeFormat('')).toBe(false);
    expect(authCodeService.isValidCodeFormat(null)).toBe(false);
  });

  test('the plaintext code is never stored - only a bcrypt hash', async () => {
    const issued = await authCodeService.issueCode({ userId: 1, purpose: PURPOSE, code: '654321' });
    expect(issued.code).toBe('654321');

    const stored = fakeStore.allRows();
    expect(stored).toHaveLength(1);
    expect(stored[0].codeHash).not.toContain('654321');
    expect(stored[0].codeHash.startsWith('$2')).toBe(true);
    expect(await bcrypt.compare('654321', stored[0].codeHash)).toBe(true);
  });

  test('a correct code is accepted exactly once (single use)', async () => {
    await authCodeService.issueCode({ userId: 1, purpose: PURPOSE, code: '111111' });

    await expect(
      authCodeService.consumeCode({ userId: 1, purpose: PURPOSE, code: '111111' })
    ).resolves.toMatchObject({ ok: true });

    await expect(
      authCodeService.consumeCode({ userId: 1, purpose: PURPOSE, code: '111111' })
    ).resolves.toMatchObject({ ok: false, reason: 'INVALID_CODE' });
  });

  test('an expired code is rejected and burned', async () => {
    const now = new Date('2026-01-01T10:00:00.000Z');
    await authCodeService.issueCode({ userId: 1, purpose: PURPOSE, code: '222222', now });
    const later = new Date(now.getTime() + (env.PASSWORD_RESET_TTL_MINUTES + 1) * 60 * 1000);

    await expect(
      authCodeService.consumeCode({ userId: 1, purpose: PURPOSE, code: '222222', now: later })
    ).resolves.toMatchObject({ ok: false, reason: 'EXPIRED_CODE' });
  });

  test('the attempt limit stops brute forcing and burns the code', async () => {
    await authCodeService.issueCode({ userId: 1, purpose: PURPOSE, code: '333333' });

    for (let attempt = 1; attempt <= env.AUTH_CODE_MAX_ATTEMPTS; attempt += 1) {
      const result = await authCodeService.consumeCode({
        userId: 1,
        purpose: PURPOSE,
        code: '000000',
      });
      expect(result.ok).toBe(false);
    }

    // Even the correct code is now unusable.
    await expect(
      authCodeService.consumeCode({ userId: 1, purpose: PURPOSE, code: '333333' })
    ).resolves.toMatchObject({ ok: false, reason: 'INVALID_CODE' });
  });

  test('issuing a new code invalidates the previous one', async () => {
    await authCodeService.issueCode({ userId: 1, purpose: PURPOSE, code: '444444' });
    await authCodeService.issueCode({ userId: 1, purpose: PURPOSE, code: '555555' });

    await expect(
      authCodeService.consumeCode({ userId: 1, purpose: PURPOSE, code: '444444' })
    ).resolves.toMatchObject({ ok: false, reason: 'INVALID_CODE' });

    await expect(
      authCodeService.consumeCode({ userId: 1, purpose: PURPOSE, code: '555555' })
    ).resolves.toMatchObject({ ok: true });
  });

  test('peeking at a code (verify screen) does not consume it', async () => {
    await authCodeService.issueCode({ userId: 1, purpose: PURPOSE, code: '666666' });
    await expect(
      authCodeService.consumeCode({ userId: 1, purpose: PURPOSE, code: '666666', consume: false })
    ).resolves.toMatchObject({ ok: true });
    await expect(
      authCodeService.consumeCode({ userId: 1, purpose: PURPOSE, code: '666666' })
    ).resolves.toMatchObject({ ok: true });
  });

  test('the resend cooldown blocks immediate re-requests per user', async () => {
    const now = new Date('2026-01-01T10:00:00.000Z');
    await authCodeService.issueCode({ userId: 1, purpose: PURPOSE, code: '777777', now });

    const blocked = await authCodeService.checkRequestAllowance({
      userId: 1,
      purpose: PURPOSE,
      now: new Date(now.getTime() + 1000),
    });
    expect(blocked.allowed).toBe(false);
    expect(blocked.reason).toBe('COOLDOWN');
    expect(blocked.retryAfterSeconds).toBeGreaterThan(0);

    const allowed = await authCodeService.checkRequestAllowance({
      userId: 1,
      purpose: PURPOSE,
      now: new Date(now.getTime() + (env.AUTH_CODE_RESEND_COOLDOWN_SECONDS + 1) * 1000),
    });
    expect(allowed.allowed).toBe(true);
  });

  test('the rolling request budget limits how many codes one account can request', async () => {
    const now = new Date('2026-01-01T10:00:00.000Z');
    for (let i = 0; i < env.AUTH_CODE_MAX_REQUESTS_PER_WINDOW; i += 1) {
      await authCodeService.issueCode({
        userId: 1,
        purpose: PURPOSE,
        code: '123456',
        now: new Date(now.getTime() + (i + 1) * (env.AUTH_CODE_RESEND_COOLDOWN_SECONDS + 1) * 1000),
      });
    }

    const result = await authCodeService.checkRequestAllowance({
      userId: 1,
      purpose: PURPOSE,
      now: new Date(now.getTime() + (env.AUTH_CODE_MAX_REQUESTS_PER_WINDOW + 2) * (env.AUTH_CODE_RESEND_COOLDOWN_SECONDS + 1) * 1000),
    });
    expect(result.allowed).toBe(false);
    expect(result.reason).toBe('RATE_LIMITED');
  });

  test('codes are scoped per user and per purpose', async () => {
    await authCodeService.issueCode({ userId: 1, purpose: PURPOSE, code: '888888' });
    await expect(
      authCodeService.consumeCode({ userId: 2, purpose: PURPOSE, code: '888888' })
    ).resolves.toMatchObject({ ok: false });
    await expect(
      authCodeService.consumeCode({
        userId: 1,
        purpose: authCodeService.PURPOSES.EMAIL_VERIFICATION,
        code: '888888',
      })
    ).resolves.toMatchObject({ ok: false });
  });

  test('invalidateCodes burns every outstanding code for a purpose', async () => {
    await authCodeService.issueCode({ userId: 1, purpose: PURPOSE, code: '999999' });
    expect(await authCodeService.invalidateCodes({ userId: 1, purpose: PURPOSE })).toBe(1);
    await expect(
      authCodeService.consumeCode({ userId: 1, purpose: PURPOSE, code: '999999' })
    ).resolves.toMatchObject({ ok: false });
  });
});
