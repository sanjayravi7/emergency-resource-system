/// Email masking (shared helper).
///
/// Mirrors `backend/src/domain/emailMasking.js`. The helper is used by every
/// surface that renders another ERAS user's address (responder directory,
/// dispatch board, request details), so its behaviour is locked down here:
/// mask the local part, keep the domain, never throw.
library;

import 'package:dispatch_console_flutter/services/email_privacy.dart';
import 'package:flutter_test/flutter_test.dart';

String stars(int count) => List<String>.filled(count, '*').join();

void main() {
  group('maskEmail', () {
    test('masks the local part and preserves the domain', () {
      expect(
        maskEmail('athulkrishna4155@gmail.com'),
        'a${stars(15)}@gmail.com',
      );
      expect(maskEmail('sanjayravit7@gmail.com'), 's${stars(11)}@gmail.com');
      expect(
        maskEmail('lonelyoneindarkness@gmail.com'),
        'l${stars(erasMaxMaskCharacters)}@gmail.com',
      );
    });

    test('keeps exactly one character of the local part', () {
      final masked = maskEmail('abcdefghij@example.org');
      expect(masked, startsWith('a'));
      expect(masked, endsWith('@example.org'));
      expect(masked.split('@').first.substring(1), matches(r'^\*+$'));
    });

    test('never throws on null, empty or malformed input', () {
      for (final value in <String?>[
        null,
        '',
        '   ',
        'nobody',
        '@example.com',
        'someone@',
        'someone@localhost',
        'someone@.com',
      ]) {
        expect(maskEmail(value), '', reason: 'input: $value');
      }
    });

    test('a one-character local part is still masked', () {
      expect(maskEmail('a@b.co'), 'a*@b.co');
    });

    test('the number of mask characters is bounded', () {
      final masked = maskEmail('${'x' * 200}@example.com');
      expect(masked, isNotEmpty);
      expect(
        masked.split('@').first.length,
        lessThanOrEqualTo(1 + erasMaxMaskCharacters),
      );
    });

    test('whitespace is ignored and the domain case is preserved', () {
      expect(maskEmail('  Someone@Example.COM  '), 'S${stars(6)}@Example.COM');
    });

    test('only the last @ splits the address', () {
      expect(maskEmail('weird@local@example.com'), 'w${stars(10)}@example.com');
    });
  });

  group('displayEmailForOthers', () {
    test('masks another account and keeps the owner’s own address', () {
      const email = 'ravi@example.com';
      expect(displayEmailForOthers(email), 'r${stars(3)}@example.com');
      expect(displayEmailForOthers(email, isOwnAccount: true), email);
    });

    test('falls back instead of rendering an empty row', () {
      expect(displayEmailForOthers(null, fallback: '-'), '-');
      expect(displayEmailForOthers('  ', fallback: '-'), '-');
      expect(displayEmailForOthers('not-an-email', fallback: '-'), '-');
    });
  });
}
