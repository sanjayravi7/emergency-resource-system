/**
 * Phase I, Part 3/12: JWT secret + environment configuration hardening.
 *
 * These are pure config tests. They reload src/config/env.js under different
 * process.env values using jest.isolateModules so each scenario gets a fresh
 * module evaluation (env validation runs at import time).
 */

const BASE_ENV = {
  DATABASE_URL: 'postgresql://u:p@localhost:5432/db',
};

function loadEnvWith(overrides) {
  let mod;
  jest.isolateModules(() => {
    const saved = { ...process.env };
    Object.assign(process.env, BASE_ENV, overrides);
    try {
      mod = require('../../src/config/env');
    } finally {
      // Restore so other scenarios / suites are unaffected.
      for (const key of Object.keys(process.env)) {
        if (!(key in saved)) delete process.env[key];
      }
      Object.assign(process.env, saved);
    }
  });
  return mod;
}

describe('env config security', () => {
  const STRONG_SECRET = 'S6m2yq0m9k3wq7Zt1v8Xr4Lp6Nc2Bd5Hf8Jk1Mn4Qs7Uw0';

  test('missing DATABASE_URL throws', () => {
    expect(() =>
      loadEnvWith({ DATABASE_URL: '', JWT_SECRET: STRONG_SECRET, NODE_ENV: 'production' })
    ).toThrow(/DATABASE_URL/);
  });

  test('missing JWT_SECRET throws', () => {
    expect(() =>
      loadEnvWith({ JWT_SECRET: '', NODE_ENV: 'production' })
    ).toThrow(/JWT_SECRET/);
  });

  test('production rejects a known weak/default secret', () => {
    expect(() =>
      loadEnvWith({ JWT_SECRET: 'change-me', NODE_ENV: 'production' })
    ).toThrow(/weak or a known default/);
  });

  test('production rejects a too-short secret', () => {
    expect(() =>
      loadEnvWith({ JWT_SECRET: 'short', NODE_ENV: 'production' })
    ).toThrow(/weak or a known default/);
  });

  test('production accepts a strong secret', () => {
    const env = loadEnvWith({ JWT_SECRET: STRONG_SECRET, NODE_ENV: 'production' });
    expect(env.JWT_SECRET).toBe(STRONG_SECRET);
    expect(env.IS_PRODUCTION).toBe(true);
  });

  test('non-production only warns on a weak secret (does not throw)', () => {
    const warn = jest.spyOn(console, 'warn').mockImplementation(() => {});
    const env = loadEnvWith({ JWT_SECRET: 'change-me', NODE_ENV: 'development' });
    expect(env.JWT_SECRET).toBe('change-me');
    expect(warn).toHaveBeenCalled();
    warn.mockRestore();
  });

  test('CORS_ORIGINS unset reflects any origin (true)', () => {
    const env = loadEnvWith({ JWT_SECRET: STRONG_SECRET });
    expect(env.CORS_ORIGIN).toBe(true);
  });

  test('CORS_ORIGINS list is parsed into an allowlist array', () => {
    const env = loadEnvWith({
      JWT_SECRET: STRONG_SECRET,
      CORS_ORIGINS: 'https://a.example, https://b.example',
    });
    expect(env.CORS_ORIGIN).toEqual(['https://a.example', 'https://b.example']);
  });

  test('trust proxy defaults to 1 in production and false in dev', () => {
    const prod = loadEnvWith({ JWT_SECRET: STRONG_SECRET, NODE_ENV: 'production' });
    const dev = loadEnvWith({ JWT_SECRET: STRONG_SECRET, NODE_ENV: 'development' });
    expect(prod.TRUST_PROXY).toBe(1);
    expect(dev.TRUST_PROXY).toBe(false);
  });

  test('rate limiting is disabled by default under NODE_ENV=test', () => {
    const env = loadEnvWith({ JWT_SECRET: STRONG_SECRET, NODE_ENV: 'test' });
    expect(env.RATE_LIMIT_ENABLED).toBe(false);
  });

  test('isWeakSecret helper classifies secrets correctly', () => {
    const env = loadEnvWith({ JWT_SECRET: STRONG_SECRET });
    expect(env.isWeakSecret('change-me')).toBe(true);
    expect(env.isWeakSecret('short')).toBe(true);
    expect(env.isWeakSecret('')).toBe(true);
    expect(env.isWeakSecret(STRONG_SECRET)).toBe(false);
  });
});
