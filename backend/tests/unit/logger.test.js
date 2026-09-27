/**
 * Phase I, Part 11: the logger must never emit secrets, even if a caller
 * carelessly passes them in the metadata object.
 */

process.env.DATABASE_URL = process.env.DATABASE_URL || 'postgresql://u:p@localhost:5432/db';
process.env.JWT_SECRET =
  process.env.JWT_SECRET || 'S6m2yq0m9k3wq7Zt1v8Xr4Lp6Nc2Bd5Hf8Jk1Mn4Qs7Uw0';

const logger = require('../../src/config/logger');

describe('logger redaction', () => {
  test('redacts sensitive keys at any depth', () => {
    const out = logger.redact({
      userId: 7,
      password: 'hunter2',
      token: 'ey.jwt.here',
      authorization: 'Bearer abc',
      nested: {
        secret: 'topsecret',
        DATABASE_URL: 'postgresql://user:pw@host/db',
        keep: 'visible',
      },
    });

    expect(out.userId).toBe(7);
    expect(out.password).toBe('[REDACTED]');
    expect(out.token).toBe('[REDACTED]');
    expect(out.authorization).toBe('[REDACTED]');
    expect(out.nested.secret).toBe('[REDACTED]');
    expect(out.nested.DATABASE_URL).toBe('[REDACTED]');
    expect(out.nested.keep).toBe('visible');
  });

  test('truncates very long strings', () => {
    const out = logger.redact({ blob: 'x'.repeat(2000) });
    expect(out.blob.length).toBeLessThan(2000);
    expect(out.blob.endsWith('…')).toBe(true);
  });

  test('handles arrays and primitives without throwing', () => {
    expect(logger.redact([1, 2, { token: 'a' }])).toEqual([1, 2, { token: '[REDACTED]' }]);
    expect(logger.redact(null)).toBeNull();
    expect(logger.redact('plain')).toBe('plain');
  });
});
