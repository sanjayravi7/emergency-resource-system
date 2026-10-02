/// Client-side email validation must stay in lock-step with the backend
/// (`backend/src/domain/emailValidation.js`). Two failure modes matter:
///
///   * too permissive  -> a malformed address reaches the API and only fails
///     later (or creates a bounce),
///   * too strict      -> a valid responder address is rejected client-side and
///     the account can never be created.
///
/// There is deliberately NO mailbox probing: validity is syntax + length only,
/// which these tests also lock down.
library;

import 'package:dispatch_console_flutter/services/email_validation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('normalizeEmail', () {
    test('trims and lowercases', () {
      expect(
          normalizeEmail('  Asha.Nair@Example.COM '), 'asha.nair@example.com');
    });

    test('tolerates null and other non-string input', () {
      expect(normalizeEmail(null), '');
      expect(normalizeEmail(''), '');
    });
  });

  group('isValidEmail', () {
    test('accepts the addresses ERAS accounts actually use', () {
      for (final email in <String>[
        'user@example.com',
        'first.last+tag@sub.example.co.uk',
        'responder_1@eras.dev',
        'a@b.co',
        'x!#\$%&\'*+/=?^_`{|}~-@example.com',
      ]) {
        expect(isValidEmail(email), isTrue, reason: email);
      }
    });

    test('rejects malformed input the old regex let through', () {
      for (final email in <String>[
        'plainaddress',
        'user@',
        '@example.com',
        'user@example',
        'user@@example.com',
        'user@example.com extra',
        'user @example.com',
        '.user@example.com',
        'user.@example.com',
        'us..er@example.com',
        'user@example..com',
        'user@-example.com',
        'user@example.c',
        'user@example.123',
        'user@exam ple.com',
      ]) {
        expect(isValidEmail(email), isFalse, reason: email);
      }
    });

    test('enforces the same length ceilings as the server', () {
      final longLocal = 'a' * (maxLocalPartLength + 1);
      expect(isValidEmail('$longLocal@example.com'), isFalse);

      final local = 'a' * maxLocalPartLength;
      expect(isValidEmail('$local@example.com'), isTrue);

      final longDomain = 'b' * (maxEmailLength + 1);
      expect(isValidEmail('user@$longDomain.com'), isFalse);
    });

    test('never performs a mailbox existence probe', () {
      // A syntactically perfect but non-existent mailbox is still "valid" here:
      // validity is a syntax question and the server never probes SMTP either.
      expect(isValidEmail('definitely-not-a-real-person@example.com'), isTrue);
    });
  });
}
