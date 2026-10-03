import 'package:dispatch_console_flutter/services/google_auth_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('sanitizeGoogleAuthDiagnosticMessage', () {
    test('keeps native error context while redacting credential values', () {
      const message = 'ApiException: 10, idToken=identity-fixture, '
          'access_token=access-fixture, apiKey=maps-fixture, '
          'clientSecret=oauth-fixture, password=password-fixture';

      final safeMessage = sanitizeGoogleAuthDiagnosticMessage(message);

      expect(safeMessage, contains('ApiException: 10'));
      expect(safeMessage, contains('[REDACTED]'));
      for (final credential in <String>[
        'identity-fixture',
        'access-fixture',
        'maps-fixture',
        'oauth-fixture',
        'password-fixture',
      ]) {
        expect(safeMessage, isNot(contains(credential)));
      }
    });

    test('normalizes multiline messages and bounds diagnostic length', () {
      expect(sanitizeGoogleAuthDiagnosticMessage(null), '<empty>');
      expect(sanitizeGoogleAuthDiagnosticMessage(' \n\t '), '<empty>');
      expect(
        sanitizeGoogleAuthDiagnosticMessage('native\nApiException: 10'),
        'native ApiException: 10',
      );

      final safeMessage = sanitizeGoogleAuthDiagnosticMessage(
        List<String>.filled(40, 'ordinary-message').join(' '),
      );

      expect(safeMessage.length, 301);
      expect(safeMessage.endsWith('…'), isTrue);
    });
  });
}
