/// Native Google Sign-In failure classification.
///
/// The release APK reported
///
///   "Google sign-in could not be completed. Please try again. ..."
///
/// for every native failure because the platform error never reached a branch
/// that understood it: `google_sign_in` >= 6.2 raises `GoogleSignInException`
/// (a plain `Exception`), which an `on PlatformException` handler does not
/// catch, so DEVELOPER_ERROR (10) - the signature of an Android OAuth client
/// that does not list this build's signing certificate - was indistinguishable
/// from a network hiccup.
///
/// These tests pin the normalisation that makes the cause diagnosable.
library;

import 'package:dispatch_console_flutter/services/google_auth_service.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';

/// Stands in for the `GoogleSignInException` the pinned plugin raises.
///
/// Only the runtime type name matters: production identifies it the same way
/// so this file does not have to import (and pin) the plugin's own class.
class GoogleSignInException implements Exception {
  const GoogleSignInException(this.code, [this.description]);

  final String code;
  final String? description;

  @override
  String toString() =>
      'GoogleSignInException(code: $code, description: $description)';
}

void main() {
  group('describeGoogleSignInFailure', () {
    test('a PlatformException carries the Google status code', () {
      final failure = describeGoogleSignInFailure(
        PlatformException(code: 'sign_in_failed', message: 'h2: 10'),
      )!;

      expect(failure.code, 'sign_in_failed');
      // 10 == CommonStatusCodes.DEVELOPER_ERROR.
      expect(failure.statusCode, 10);
      expect(failure.isDeveloperError, isTrue);
      expect(failure.cancelled, isFalse);
    });

    test('a status code in `details` wins over the message', () {
      final failure = describeGoogleSignInFailure(
        PlatformException(
          code: 'sign_in_failed',
          message: 'h2: 10',
          details: <String, Object?>{'statusCode': 12501},
        ),
      )!;

      expect(failure.statusCode, 12501);
      expect(failure.isDeveloperError, isFalse);
    });

    test('a dismissed account sheet is a cancellation, not a failure', () {
      final failure = describeGoogleSignInFailure(
        PlatformException(
          code: 'sign_in_canceled',
          message: 'The user canceled the sign-in flow',
        ),
      )!;

      expect(failure.cancelled, isTrue);
      expect(failure.code, 'sign_in_canceled');
    });

    test('GoogleSignInException is recognised by runtime type', () {
      final failure = describeGoogleSignInFailure(
        const GoogleSignInException('unknownError', '10'),
      )!;

      expect(failure.isDeveloperError, isTrue);
      expect(failure.cancelled, isFalse);
      // The diagnostic is sanitized, so nothing raw is kept.
      expect(failure.detail, isNotNull);
    });

    test('a cancelled GoogleSignInException stays a cancellation', () {
      final failure = describeGoogleSignInFailure(
        const GoogleSignInException('canceled'),
      )!;

      expect(failure.cancelled, isTrue);
      expect(failure.isDeveloperError, isFalse);
    });

    test('errors that did not come from Google are not claimed', () {
      expect(describeGoogleSignInFailure(StateError('something else')), isNull);
      expect(describeGoogleSignInFailure(Exception('boom')), isNull);
    });
  });

  group('nativeGoogleSignInMessage', () {
    test('DEVELOPER_ERROR points at the release signing configuration', () {
      final message = nativeGoogleSignInMessage(
        const GoogleNativeSignInFailure(code: 'sign_in_failed', statusCode: 10),
      );

      // "Try again" would be actively wrong: the build is not registered.
      expect(message, contains('not registered'));
      expect(message, contains('SHA-1'));
      expect(message, isNot(contains('try again')));
    });

    test('every other native failure keeps the previous wording', () {
      final message = nativeGoogleSignInMessage(
        const GoogleNativeSignInFailure(code: 'sign_in_failed', statusCode: 7),
      );

      expect(message, contains('could not be completed on this device'));
    });

    test('no message leaks a status code or a client id', () {
      final message = nativeGoogleSignInMessage(
        const GoogleNativeSignInFailure(code: 'sign_in_failed', statusCode: 10),
      );

      expect(message, isNot(contains('10')));
      expect(message, isNot(contains('sign_in_failed')));
    });
  });
}
