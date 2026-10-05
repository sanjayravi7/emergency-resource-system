// EMAIL MASKING: one shared helper, applied at the serialization boundary.
// It must never throw, never leak more than the first character of the local
// part, and always preserve the domain.

const {
  MAX_MASK_CHARACTERS,
  maskEmail,
  maskEmailOrFallback,
  isMaskableEmail,
} = require('../../src/domain/emailMasking');

describe('maskEmail', () => {
  test('masks the local part and keeps the domain', () => {
    expect(maskEmail('athulkrishna4155@gmail.com')).toBe(
      `a${'*'.repeat(15)}@gmail.com`
    );
    expect(maskEmail('sanjayravit7@gmail.com')).toBe(
      `s${'*'.repeat(11)}@gmail.com`
    );
    expect(maskEmail('lonelyoneindarkness@gmail.com')).toBe(
      `l${'*'.repeat(MAX_MASK_CHARACTERS)}@gmail.com`
    );
  });

  test('never exposes more than the first character of the local part', () => {
    const masked = maskEmail('abcdefghijklmnop@example.org');
    expect(masked.startsWith('a')).toBe(true);
    expect(masked.split('@')[0].slice(1)).toMatch(/^\*+$/);
    expect(masked.endsWith('@example.org')).toBe(true);
  });

  test('is null-safe and never throws on malformed input', () => {
    for (const value of [
      null,
      undefined,
      '',
      '   ',
      42,
      {},
      [],
      true,
      'nobody',
      '@example.com',
      'someone@',
      'someone@localhost',
      'someone@.com',
    ]) {
      expect(() => maskEmail(value)).not.toThrow();
      expect(maskEmail(value)).toBeNull();
    }
  });

  test('a one-character local part still yields a masked address', () => {
    expect(maskEmail('a@b.co')).toBe('a*@b.co');
  });

  test('the number of mask characters is bounded', () => {
    const long = `${'x'.repeat(200)}@example.com`;
    const masked = maskEmail(long);
    expect(masked).not.toBeNull();
    expect(masked.split('@')[0].length).toBeLessThanOrEqual(1 + MAX_MASK_CHARACTERS);
  });

  test('an absurdly long address is refused instead of copied', () => {
    expect(maskEmail(`${'x'.repeat(300)}@example.com`)).toBeNull();
  });

  test('surrounding whitespace is ignored but the domain case is preserved', () => {
    expect(maskEmail('  Someone@Example.COM  ')).toBe('S******@Example.COM');
  });

  test('only the LAST @ splits the address', () => {
    expect(maskEmail('weird@local@example.com')).toBe('w**********@example.com');
  });
});

describe('maskEmailOrFallback', () => {
  test('falls back when there is nothing maskable', () => {
    expect(maskEmailOrFallback(null)).toBe('***');
    expect(maskEmailOrFallback('not-an-email', 'hidden')).toBe('hidden');
  });

  test('returns the masked address when there is one', () => {
    expect(maskEmailOrFallback('meera@example.com')).toBe('m****@example.com');
  });
});

describe('isMaskableEmail', () => {
  test('recognises addresses ERAS would mask', () => {
    expect(isMaskableEmail('meera@example.com')).toBe(true);
    expect(isMaskableEmail('nope')).toBe(false);
    expect(isMaskableEmail(null)).toBe(false);
  });
});
