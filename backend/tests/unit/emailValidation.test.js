// Email normalization + validation (shared by client-parity checks and every
// server-side endpoint). No SMTP probing: syntax and length only.

const {
  MAX_EMAIL_LENGTH,
  normalizeEmail,
  isValidEmail,
  validateAndNormalizeEmail,
} = require('../../src/domain/emailValidation');

describe('email normalization', () => {
  test('trims surrounding whitespace', () => {
    expect(normalizeEmail('  user@example.com  ')).toBe('user@example.com');
  });

  test('lowercases the address for consistent lookups', () => {
    expect(normalizeEmail('User.Name@Example.COM')).toBe('user.name@example.com');
  });

  test('non-string input becomes an empty string (never throws)', () => {
    expect(normalizeEmail(undefined)).toBe('');
    expect(normalizeEmail(null)).toBe('');
    expect(normalizeEmail(42)).toBe('');
  });
});

describe('email validation', () => {
  test('accepts normal addresses', () => {
    for (const email of [
      'user@example.com',
      'first.last+tag@sub.example.co.uk',
      'responder_1@eras.dev',
    ]) {
      expect(isValidEmail(email)).toBe(true);
    }
  });

  test('rejects obviously malformed input', () => {
    for (const email of [
      'plainaddress',
      '@no-local-part.com',
      'two@@example.com',
      'spaces in@example.com',
      'trailing.dot.@example.com',
      '.leading.dot@example.com',
      'no-tld@example',
      'no-at-sign.example.com',
      '',
      '   ',
    ]) {
      expect(isValidEmail(email)).toBe(false);
    }
  });

  test('rejects control characters and overly long addresses', () => {
    expect(isValidEmail('user\u0000@example.com')).toBe(false);
    expect(isValidEmail(`${'a'.repeat(250)}@example.com`)).toBe(false);
    expect(`${'a'.repeat(250)}@example.com`.length).toBeGreaterThan(MAX_EMAIL_LENGTH);
  });

  test('validateAndNormalizeEmail returns both the normalized value and validity', () => {
    expect(validateAndNormalizeEmail('  USER@Example.com ')).toEqual({
      email: 'user@example.com',
      valid: true,
    });
    expect(validateAndNormalizeEmail('nope')).toEqual({ email: 'nope', valid: false });
  });

  test('accepts an address with a trailing newline only after trimming', () => {
    expect(isValidEmail('user@example.com\n')).toBe(true);
    expect(isValidEmail('user@exa\nmple.com')).toBe(false);
  });
});
