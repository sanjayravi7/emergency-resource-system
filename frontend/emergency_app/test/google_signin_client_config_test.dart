/// Which OAuth client identifiers ERAS hands to the Google Sign-In SDK.
///
/// Android identifies the app by its package name plus the SHA-1 of its
/// signing certificate and reads the ID-token audience from the
/// `default_web_client_id` string resource that the google-services Gradle
/// plugin generates from `android/app/google-services.json`.
/// `google_sign_in_android` only consults that resource when Dart supplied
/// neither `serverClientId` nor `clientId`; anything Dart passes takes
/// precedence over the configuration file. Supplying a hand-copied web client
/// id therefore decoupled the release APK from the configuration it is
/// actually registered with, and Google rejected the request with
/// `CommonStatusCodes.DEVELOPER_ERROR` (10) - reported by the plugin as
/// `sign_in_failed` with the message `h2: 10`.
///
/// Flutter Web is the opposite case and stays exactly as it was: the Firebase
/// OAuth **web** client id must be passed as `clientId`, and
/// `google_sign_in_web` asserts that `serverClientId` is null.
library;

import 'package:dispatch_console_flutter/services/google_auth_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// A synthetic OAuth client id. It is not a real credential; tests compare it
/// by identity and never print it.
const String kWebClientIdFixture =
    '123456789012-abcdefghijklmnop.apps.googleusercontent.com';

void main() {
  group('Android / native configuration path', () {
    test('Android passes no client id or server client id', () {
      final config = resolveGoogleSignInClientConfig(
        isWeb: false,
        platform: TargetPlatform.android,
        googleWebClientId: kWebClientIdFixture,
      );

      // google_sign_in_android falls back to the `default_web_client_id`
      // resource generated from google-services.json only when both are
      // absent, so both must be absent.
      expect(config.clientId, isNull);
      expect(config.serverClientId, isNull);
      expect(config, const GoogleSignInClientConfig());
    });

    test('every native platform defers to its config file', () {
      for (final platform in TargetPlatform.values) {
        final config = resolveGoogleSignInClientConfig(
          isWeb: false,
          platform: platform,
          googleWebClientId: kWebClientIdFixture,
        );
        // google-services.json on Android, GoogleService-Info.plist on
        // iOS/macOS: never a value copied into the Dart build.
        expect(config, const GoogleSignInClientConfig());
      }
    });

    test('a blank web client id changes nothing on Android', () {
      for (final webClientId in <String>['', '   ']) {
        final config = resolveGoogleSignInClientConfig(
          isWeb: false,
          platform: TargetPlatform.android,
          googleWebClientId: webClientId,
        );
        expect(config, const GoogleSignInClientConfig());
      }
    });
  });

  group('Web configuration path', () {
    test('Web sends the Firebase web client id as clientId', () {
      final config = resolveGoogleSignInClientConfig(
        isWeb: true,
        // `defaultTargetPlatform` is irrelevant once kIsWeb is true.
        platform: TargetPlatform.android,
        googleWebClientId: '  $kWebClientIdFixture  ',
      );

      // Trimmed, so a stray space in --dart-define cannot break GIS.
      expect(config.clientId, kWebClientIdFixture);
      // google_sign_in_web asserts `serverClientId == null`.
      expect(config.serverClientId, isNull);
    });

    test('an unconfigured web build keeps plugin detection', () {
      final config = resolveGoogleSignInClientConfig(
        isWeb: true,
        platform: TargetPlatform.android,
        googleWebClientId: '',
      );

      // Null keeps google_sign_in_web's `google-signin-client_id` meta tag in
      // charge instead of sending an empty client id.
      expect(config.clientId, isNull);
      expect(config.serverClientId, isNull);
    });

    test('only web receives the web client id', () {
      final web = resolveGoogleSignInClientConfig(
        isWeb: true,
        platform: TargetPlatform.android,
        googleWebClientId: kWebClientIdFixture,
      );
      final android = resolveGoogleSignInClientConfig(
        isWeb: false,
        platform: TargetPlatform.android,
        googleWebClientId: kWebClientIdFixture,
      );

      expect(web.clientId, kWebClientIdFixture);
      expect(web.serverClientId, isNull);
      expect(android.clientId, isNull);
      expect(android.serverClientId, isNull);
    });
  });

  group('no web client id as an Android client id', () {
    test('no native config carries the web client id', () {
      for (final platform in TargetPlatform.values) {
        final config = resolveGoogleSignInClientConfig(
          isWeb: false,
          platform: platform,
          googleWebClientId: kWebClientIdFixture,
        );

        expect(config.clientId, isNull);
        expect(config.serverClientId, isNull);
        expect(config.clientId, isNot(kWebClientIdFixture));
        expect(config.serverClientId, isNot(kWebClientIdFixture));
        // Diagnostics must not leak it either.
        expect(config.toString(), isNot(contains(kWebClientIdFixture)));
        expect(config.toString(), contains('unset'));
      }
    });

    test('the built client carries no client override', () {
      // flutter_test runs with kIsWeb == false and an Android target
      // platform, i.e. exactly the release APK configuration path.
      expect(kIsWeb, isFalse);
      expect(defaultTargetPlatform, TargetPlatform.android);

      // Simulate a release build, where the web client id IS compiled in.
      // This is the configuration that produced DEVELOPER_ERROR (10): the old
      // code forwarded it as `serverClientId` and overrode
      // `default_web_client_id` from google-services.json.
      GoogleAuthService.debugGoogleWebClientId = kWebClientIdFixture;
      addTearDown(() => GoogleAuthService.debugGoogleWebClientId = null);

      // `GoogleSignIn` forwards these two fields verbatim to
      // GoogleSignInPlatform.initWithParams, so asserting on the constructed
      // client asserts on what the Android plugin receives.
      final GoogleSignIn client =
          GoogleAuthService.instance.buildSignInClient();
      expect(client.clientId, isNull);
      expect(client.serverClientId, isNull);
      expect(client.scopes, <String>['email', 'profile']);
      expect(
        GoogleAuthService.instance.clientConfig,
        const GoogleSignInClientConfig(),
      );
    });
  });

  group('safe diagnostics', () {
    test('client ids are fingerprinted, never printed', () {
      expect(maskGoogleClientId(null), 'unset');
      expect(maskGoogleClientId('   '), 'unset');

      final masked = maskGoogleClientId(kWebClientIdFixture);
      expect(masked, isNot(contains(kWebClientIdFixture)));
      expect(masked, isNot(contains('apps.googleusercontent.com')));
      expect(masked, contains('len=${kWebClientIdFixture.length}'));
      // Stable, so two builds can be compared, and value-specific.
      expect(maskGoogleClientId(kWebClientIdFixture), masked);
      expect(maskGoogleClientId('other-fixture-client-id'), isNot(masked));
    });

    test('toString hides both slots', () {
      const config = GoogleSignInClientConfig(
        clientId: kWebClientIdFixture,
        serverClientId: kWebClientIdFixture,
      );
      final rendered = config.toString();

      expect(rendered, contains('clientId:'));
      expect(rendered, contains('serverClientId:'));
      expect(rendered, isNot(contains(kWebClientIdFixture)));
      expect(rendered, contains('client-id:len='));
    });
  });

  group('existing Google auth flow', () {
    test('the FirebaseAuth hand-off still returns a token', () async {
      GoogleAuthService.debugTokenProvider =
          () async => 'firebase-id-token-fixture';
      addTearDown(() => GoogleAuthService.debugTokenProvider = null);

      // POST /api/auth/google receives this value verbatim; see
      // test/google_signin_flow_test.dart for the full contract.
      expect(
        await GoogleAuthService.instance.signInAndGetIdToken(),
        'firebase-id-token-fixture',
      );
    });

    test('sign-out degrades safely without a native plugin', () async {
      // No Firebase app and no Google plugin exist under flutter_test: both
      // must be swallowed so logging out can never strand the user. This also
      // drives the new `_googleSignIn` getter end to end.
      await GoogleAuthService.instance.signOut();
    });
  });
}
