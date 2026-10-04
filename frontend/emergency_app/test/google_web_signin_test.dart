/// Flutter Web Google sign-in through Firebase Auth.
///
/// The web path is deliberately different from the native one:
/// `FirebaseAuth.signInWithPopup` (with a `signInWithRedirect` fallback) owns
/// Google's OAuth UI on web and returns a Firebase ID token, while Android and
/// iOS keep the platform account picker. These tests lock that split, the
/// cancellation/redirect handling, the safe error messages and the persisted
/// first-time registration choice a web redirect needs.
library;

import 'dart:convert';

import 'package:dispatch_console_flutter/services/firebase_bootstrap.dart';
import 'package:dispatch_console_flutter/services/google_auth_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Drives the web branch without a browser or a real Firebase project.
class _FakeWebHandler implements WebGoogleSignInHandler {
  _FakeWebHandler({this.signInOutcome, this.resumeOutcome, this.failure});

  GoogleSignInOutcome? signInOutcome;
  GoogleSignInOutcome? resumeOutcome;

  /// When set, `signIn()` fails the way the real handler would.
  GoogleAuthException? failure;

  int signInCalls = 0;
  int resumeCalls = 0;
  int signOutCalls = 0;

  @override
  Future<GoogleSignInOutcome> signIn() async {
    signInCalls++;
    final error = failure;
    if (error != null) throw error;
    return signInOutcome ?? const GoogleSignInOutcome.cancelled();
  }

  @override
  Future<GoogleSignInOutcome?> resume() async {
    resumeCalls++;
    return resumeOutcome;
  }

  @override
  Future<void> signOut() async {
    signOutCalls++;
  }
}

void _restoreSeams() {
  GoogleAuthService.debugTokenProvider = null;
  GoogleAuthService.debugGoogleWebClientId = null;
  GoogleAuthService.debugUseWebFlow = null;
  GoogleAuthService.debugWebHandler = null;
  GoogleAuthService.debugFirebaseConfigured = null;
  GoogleAuthService.debugEnsureFirebaseReady =
      ErasFirebaseConfig.ensureInitialized;
}

void _useWebFlow(_FakeWebHandler handler) {
  GoogleAuthService.debugUseWebFlow = true;
  GoogleAuthService.debugWebHandler = handler;
  GoogleAuthService.debugFirebaseConfigured = true;
  GoogleAuthService.debugEnsureFirebaseReady = () async => true;
}

void main() {
  setUp(() {
    _restoreSeams();
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(_restoreSeams);

  group('platform strategy', () {
    test('web authenticates through Firebase Auth, native through the picker',
        () {
      expect(
        resolveGoogleSignInStrategy(isWeb: true),
        GoogleSignInStrategy.firebaseWebPopup,
      );
      expect(
        resolveGoogleSignInStrategy(isWeb: false),
        GoogleSignInStrategy.nativeAccountPicker,
      );
    });

    test('the service reports the strategy of the current build', () {
      // flutter_test runs as a native target.
      expect(
        GoogleAuthService.instance.strategy,
        GoogleSignInStrategy.nativeAccountPicker,
      );

      GoogleAuthService.debugUseWebFlow = true;
      addTearDown(() => GoogleAuthService.debugUseWebFlow = null);
      expect(
        GoogleAuthService.instance.strategy,
        GoogleSignInStrategy.firebaseWebPopup,
      );
      expect(GoogleAuthService.instance.usesWebSignInFlow, isTrue);
    });
  });

  group('web sign-in outcomes', () {
    test('a Firebase ID token is returned to the caller', () async {
      final handler = _FakeWebHandler(
        signInOutcome: const GoogleSignInOutcome.completed('firebase-id-token'),
      );
      _useWebFlow(handler);

      final outcome = await GoogleAuthService.instance.signIn();

      expect(outcome.status, GoogleSignInStatus.completed);
      expect(outcome.idToken, 'firebase-id-token');
      expect(outcome.toString(), isNot(contains('firebase-id-token')));
      expect(handler.signInCalls, 1);
    });

    test('a dismissed popup is a cancellation, never a failure', () async {
      final handler = _FakeWebHandler(
        signInOutcome: const GoogleSignInOutcome.cancelled(),
      );
      _useWebFlow(handler);

      expect(
        await GoogleAuthService.instance.signInAndGetIdToken(),
        isNull,
      );
      expect(handler.signInCalls, 1);
    });

    test('a blocked popup reports the redirect instead of failing', () async {
      final handler = _FakeWebHandler(
        signInOutcome: const GoogleSignInOutcome.redirecting(),
      );
      _useWebFlow(handler);

      final outcome = await GoogleAuthService.instance.signIn();

      expect(outcome.isRedirecting, isTrue);
      expect(outcome.idToken, isNull);
    });

    test('a provider failure is surfaced as a safe ERAS message', () async {
      final handler = _FakeWebHandler(
        failure: const GoogleAuthException('Google sign-in was cancelled.'),
      );
      _useWebFlow(handler);

      await expectLater(
        GoogleAuthService.instance.signIn(),
        throwsA(
          isA<GoogleAuthException>().having(
            (error) => error.message,
            'message',
            'Google sign-in was cancelled.',
          ),
        ),
      );
    });

    test('an unconfigured build never calls the provider', () async {
      final handler = _FakeWebHandler();
      GoogleAuthService.debugUseWebFlow = true;
      GoogleAuthService.debugWebHandler = handler;
      GoogleAuthService.debugFirebaseConfigured = false;
      addTearDown(() => GoogleAuthService.debugFirebaseConfigured = null);

      await expectLater(
        GoogleAuthService.instance.signIn(),
        throwsA(
          isA<GoogleAuthException>().having(
            (error) => error.message,
            'message',
            erasGoogleNotConfiguredMessage,
          ),
        ),
      );
      expect(handler.signInCalls, 0);
    });
  });

  group('pending web registration', () {
    test('the registration choice survives a redirect', () async {
      final handler = _FakeWebHandler(
        signInOutcome: const GoogleSignInOutcome.redirecting(),
      );
      _useWebFlow(handler);

      await GoogleAuthService.instance.signIn(
        registration: const GoogleRegistrationRequest(
          role: 'RESPONDER',
          name: 'Asha Menon',
          phone: '555-0100',
        ),
      );

      final pending = await GoogleRegistrationRequest.consume();
      expect(
        pending,
        const GoogleRegistrationRequest(
          role: 'RESPONDER',
          name: 'Asha Menon',
          phone: '555-0100',
        ),
      );
      // Consuming clears it: a stale role can never reach a later sign-in.
      expect(await GoogleRegistrationRequest.consume(), isNull);
    });

    test('a login attempt clears a stale registration choice', () async {
      await GoogleRegistrationRequest.persist(
        const GoogleRegistrationRequest(role: 'REQUESTER'),
      );

      final handler = _FakeWebHandler();
      _useWebFlow(handler);
      await GoogleAuthService.instance.signIn();

      expect(await GoogleRegistrationRequest.consume(), isNull);
    });

    test('resume returns the token and the pending registration', () async {
      final handler = _FakeWebHandler(
        resumeOutcome: const GoogleSignInOutcome.completed('resumed-token'),
      );
      _useWebFlow(handler);
      await GoogleRegistrationRequest.persist(
        const GoogleRegistrationRequest(role: 'RESPONDER'),
      );

      final result = await GoogleAuthService.instance.resumeWebSignIn();

      expect(result?.outcome.idToken, 'resumed-token');
      expect(result?.registration?.role, 'RESPONDER');
      expect(await GoogleRegistrationRequest.consume(), isNull);
    });

    test('resume is a no-op without a pending Google session', () async {
      final handler = _FakeWebHandler();
      _useWebFlow(handler);

      expect(await GoogleAuthService.instance.resumeWebSignIn(), isNull);
      expect(handler.resumeCalls, 1);
    });

    test('native platforms never resume a web sign-in', () async {
      final handler = _FakeWebHandler();
      GoogleAuthService.debugUseWebFlow = false;
      GoogleAuthService.debugWebHandler = handler;
      GoogleAuthService.debugFirebaseConfigured = true;

      expect(await GoogleAuthService.instance.resumeWebSignIn(), isNull);
      expect(handler.resumeCalls, 0);
    });

    test('stored values the backend would reject are discarded', () async {
      for (final stored in <String>[
        jsonEncode(<String, String>{'role': 'ADMIN'}),
        jsonEncode(<String, String>{'role': ''}),
        '{"role": 42}',
        'not json',
        '[]',
      ]) {
        SharedPreferences.setMockInitialValues(<String, Object>{
          'eras.google.pending_registration': stored,
        });
        expect(
          await GoogleRegistrationRequest.consume(),
          isNull,
          reason: 'stored value: $stored',
        );
      }
    });

    test('a stored role is normalised before use', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'eras.google.pending_registration': jsonEncode(<String, String>{
          'role': ' responder ',
          'name': '  Asha  ',
        }),
      });

      final pending = await GoogleRegistrationRequest.consume();

      expect(pending?.role, 'RESPONDER');
      expect(pending?.name, 'Asha');
      expect(pending?.phone, isNull);
    });
  });

  group('native sign-in stays intact', () {
    test('the service still uses the account picker off the web', () {
      GoogleAuthService.debugGoogleWebClientId = null;
      final client = GoogleAuthService.instance.buildSignInClient();

      // No Dart-side client id: google-services.json / GoogleService-Info.plist
      // stay authoritative, which is what fixed DEVELOPER_ERROR (10).
      expect(client.clientId, isNull);
      expect(client.serverClientId, isNull);
      expect(client.scopes, <String>['email', 'profile']);
    });

    test('a missing platform plugin reports one safe message', () async {
      final handler = _FakeWebHandler();
      GoogleAuthService.debugUseWebFlow = false;
      GoogleAuthService.debugWebHandler = handler;
      GoogleAuthService.debugFirebaseConfigured = true;
      GoogleAuthService.debugEnsureFirebaseReady = () async => true;

      // flutter_test has no Google Sign-In platform implementation, so this is
      // exactly the "plugin unavailable" case the user must never see raw.
      try {
        await GoogleAuthService.instance.signIn();
        fail('signIn() must not succeed without a platform implementation');
      } on GoogleAuthException catch (error) {
        expect(error.message, isNotEmpty);
        expect(error.message, isNot(contains('UnimplementedError')));
        expect(error.message, isNot(contains('implemented')));
      }
      expect(handler.signInCalls, 0);
    });
  });

  group('sign-out', () {
    test('web signs out of the Firebase session', () async {
      final handler = _FakeWebHandler();
      _useWebFlow(handler);

      await GoogleAuthService.instance.signOut();

      expect(handler.signOutCalls, 1);
    });
  });

  group('safe error messages', () {
    test('every code maps to guidance that never repeats the code', () {
      const codes = <String>[
        'popup-blocked',
        'popup-closed-by-user',
        'cancelled-popup-request',
        'unauthorized-domain',
        'operation-not-allowed',
        'account-exists-with-different-credential',
        'network-request-failed',
        'user-disabled',
        'too-many-requests',
        'timeout',
        'invalid-credential',
        'internal-error',
        'something-unexpected',
        'auth/popup-blocked',
        '',
      ];

      for (final code in codes) {
        final message = googleAuthErrorMessageForCode(code);
        expect(message, isNotEmpty);
        if (code.isNotEmpty) {
          expect(message, isNot(contains(code)));
        }
        expect(message, isNot(contains('<'))); // no placeholder leaked
      }
    });

    test('popup blocking and domain misconfiguration are actionable', () {
      expect(
        googleAuthErrorMessageForCode('popup-blocked'),
        contains('pop-up'),
      );
      expect(
        googleAuthErrorMessageForCode('unauthorized-domain'),
        contains('Firebase Authentication'),
      );
      expect(
        googleAuthErrorMessageForCode('network-request-failed'),
        contains('network connection'),
      );
      // The prefixed form the native plugin reports must behave identically.
      expect(
        googleAuthErrorMessageForCode('auth/network-request-failed'),
        googleAuthErrorMessageForCode('network-request-failed'),
      );
      expect(
        googleAuthErrorMessageForCode('unknown-code'),
        erasGoogleGenericFailureMessage,
      );
    });

    test('the generic message stays user-facing and free of internals', () {
      expect(erasGoogleGenericFailureMessage, contains('Please try again'));
      expect(erasGoogleGenericFailureMessage, isNot(contains('Exception')));
      expect(erasGoogleGenericFailureMessage, isNot(contains('Firebase')));
    });
  });
}
