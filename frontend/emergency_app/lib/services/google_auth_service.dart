import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:google_sign_in/google_sign_in.dart';

import 'firebase_bootstrap.dart';

/// Raised when Google sign-in cannot complete. The message is safe to show.
class GoogleAuthException implements Exception {
  const GoogleAuthException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Removes credential-like values before a native diagnostic is written to
/// logs. The returned message is bounded and contains no raw auth payloads.
@visibleForTesting
String sanitizeGoogleAuthDiagnosticMessage(String? message) {
  if (message == null || message.trim().isEmpty) return '<empty>';

  var sanitized = message;
  final sensitiveAssignments = RegExp(
    r'''((?:["']?\b(?:id|access|refresh|firebase|auth)[-_ ]?token\b["']?|'''
    r'''["']?\b(?:api[_-]?key|key|client[_-]?id|server[_-]?client[_-]?id|'''
    r'''client[_-]?secret|oauth[_-]?secret|secret|password|authorization|'''
    r'''server[_-]?auth[_-]?code|auth[_-]?code|oauth[_-]?code|credential|'''
    r'''credentials|private[_-]?key)\b["']?)\s*[:=]\s*)'''
    r'''(?:"[^"]*"|'[^']*'|[^,;&}\r\n]+)''',
    caseSensitive: false,
  );
  sanitized = sanitized.replaceAllMapped(
    sensitiveAssignments,
    (match) => '${match.group(1)}[REDACTED]',
  );
  sanitized = sanitized.replaceAll(
    RegExp(r'\bBearer\s+\S+', caseSensitive: false),
    'Bearer [REDACTED]',
  );
  sanitized = sanitized.replaceAll(
    RegExp(r'\bAIza[0-9A-Za-z_-]{20,}\b'),
    '[REDACTED_API_KEY]',
  );
  sanitized = sanitized.replaceAll(
    RegExp(r'\bGOCSPX-[0-9A-Za-z_-]+\b'),
    '[REDACTED_OAUTH_SECRET]',
  );
  sanitized = sanitized.replaceAll(
    RegExp(r'\bya29\.[0-9A-Za-z._~-]+\b'),
    '[REDACTED_ACCESS_TOKEN]',
  );
  sanitized = sanitized.replaceAll(
    RegExp(
      r'\beyJ[0-9A-Za-z_-]{8,}\.[0-9A-Za-z_-]{8,}\.[0-9A-Za-z_-]{8,}\b',
    ),
    '[REDACTED_ID_TOKEN]',
  );
  sanitized = sanitized.replaceAll(
    RegExp(r'\b[A-Za-z0-9_-]{32,}\b'),
    '[REDACTED_OPAQUE_VALUE]',
  );
  sanitized = sanitized
      .replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  const maxLength = 300;
  if (sanitized.length > maxLength) {
    sanitized = '${sanitized.substring(0, maxLength)}…';
  }
  return sanitized.isEmpty ? '<empty>' : sanitized;
}

/// Renders an OAuth client id as a non-reversible fingerprint.
///
/// Diagnostics must be able to tell two builds apart without ever writing a
/// complete client id into a log, a crash report or a screenshot.
@visibleForTesting
String maskGoogleClientId(String? value) {
  if (value == null || value.trim().isEmpty) return 'unset';

  // Stays well inside the exactly-representable integer range on both the VM
  // and dart2js, so the fingerprint is stable for a given value.
  var hash = 0;
  for (final unit in value.codeUnits) {
    hash = (hash * 31 + unit) & 0x3fffffff;
  }
  final fingerprint = hash.toRadixString(16).padLeft(6, '0');
  return '[client-id:len=${value.length},fp=$fingerprint]';
}

/// The OAuth client identifiers a `GoogleSignIn` instance is constructed with.
///
/// [toString] never prints a complete client id (see [maskGoogleClientId]).
@immutable
class GoogleSignInClientConfig {
  const GoogleSignInClientConfig({this.clientId, this.serverClientId});

  /// The OAuth client id of the app. Flutter Web only: `google_sign_in_web`
  /// reads it (or the `google-signin-client_id` meta tag) to drive Google
  /// Identity Services.
  final String? clientId;

  /// The backend server client id whose audience the returned ID token is
  /// issued for.
  final String? serverClientId;

  @override
  bool operator ==(Object other) =>
      other is GoogleSignInClientConfig &&
      other.clientId == clientId &&
      other.serverClientId == serverClientId;

  @override
  int get hashCode => Object.hash(clientId, serverClientId);

  @override
  String toString() {
    return 'GoogleSignInClientConfig('
        'clientId: ${maskGoogleClientId(clientId)}, '
        'serverClientId: ${maskGoogleClientId(serverClientId)})';
  }
}

/// Resolves the OAuth client identifiers `GoogleSignIn` receives, per platform.
///
/// **Android.** The Google Sign-In SDK identifies an Android app by its package
/// name plus the SHA-1 of its signing certificate — never by a client id — and
/// takes the ID-token audience from the `default_web_client_id` string resource
/// that the google-services Gradle plugin generates from
/// `android/app/google-services.json`. `google_sign_in_android` only reads that
/// resource when Dart supplied neither `serverClientId` nor `clientId`; a
/// Dart-supplied value always wins ("The value specified here has precedence
/// over a value from a configuration file"), and `clientId` is explicitly
/// unsupported on Android.
///
/// Hand-copying `ERAS_GOOGLE_WEB_CLIENT_ID` into the APK therefore decouples
/// the OAuth request from the configuration the app is actually registered
/// with. Any drift between the two — a web client that is not linked to this
/// Android client, a value taken from another Google Cloud project, or a stale
/// copy — makes Google reject the request with
/// `CommonStatusCodes.DEVELOPER_ERROR` (status 10), which the plugin reports as
/// `sign_in_failed` with the message `h2: 10`.
///
/// So the rule is:
///
///   * Web: `clientId` MUST be the Firebase OAuth **web** client id
///     (`ERAS_GOOGLE_WEB_CLIENT_ID`) and `serverClientId` MUST stay null —
///     `google_sign_in_web` asserts `serverClientId == null`.
///   * Android, iOS, macOS and desktop: both stay null so
///     `google-services.json` / `GoogleService-Info.plist` supply the
///     identifiers, which is the only source guaranteed to agree with the
///     registered package name and signing fingerprint.
@visibleForTesting
GoogleSignInClientConfig resolveGoogleSignInClientConfig({
  required bool isWeb,
  required TargetPlatform platform,
  required String googleWebClientId,
}) {
  final webClientId = googleWebClientId.trim();
  if (isWeb) {
    return GoogleSignInClientConfig(
      // An empty value keeps the plugin's own detection (meta tag) in charge,
      // which is exactly what an unconfigured build needs.
      clientId: webClientId.isEmpty ? null : webClientId,
      serverClientId: null,
    );
  }

  // Every native platform resolves its OAuth configuration from its Firebase
  // configuration file; see the documentation above.
  switch (platform) {
    case TargetPlatform.android:
    case TargetPlatform.iOS:
    case TargetPlatform.macOS:
    case TargetPlatform.linux:
    case TargetPlatform.windows:
    case TargetPlatform.fuchsia:
      return const GoogleSignInClientConfig();
  }
}

String _safePlatformDetails(Object? details) {
  if (details is int) return '; detailsCode=$details';
  if (details is Map) {
    for (final key in <String>[
      'statusCode',
      'status_code',
      'errorCode',
      'error_code',
      'code',
    ]) {
      final value = details[key];
      if (value is int) return '; detailsCode=$value';
      if (value is String && RegExp(r'^\d{1,6}$').hasMatch(value)) {
        return '; detailsCode=$value';
      }
    }
  }
  return '';
}

void _logPlatformDiagnostic(String operation, PlatformException error) {
  debugPrint(
    '$operation: code=${error.code}; '
    'message=${sanitizeGoogleAuthDiagnosticMessage(error.message)}'
    '${_safePlatformDetails(error.details)}',
  );
}

/// Google identity provider for ERAS.
///
/// Design (mirrors the division of labour on the server):
///
///   1. Firebase Auth (existing Firebase project) performs the Google
///      authentication and returns an ID token. No password and no refresh
///      token ever reaches ERAS.
///   2. This service returns ONLY that ID token.
///   3. `POST /api/auth/google` verifies the token cryptographically against
///      Google's published certificates and then issues the normal ERAS JWT.
///      The client never decides its own role or admin status.
///
/// The service is intentionally thin and testable: it exposes an injectable
/// token provider so widget/unit tests never need a real Google account.
class GoogleAuthService {
  GoogleAuthService._();

  static final GoogleAuthService instance = GoogleAuthService._();

  /// Test seam: replaces the real Firebase/Google round-trip.
  @visibleForTesting
  static Future<String?> Function()? debugTokenProvider;

  /// Test seam: stands in for the `ERAS_GOOGLE_WEB_CLIENT_ID` that a release
  /// build compiles in. `null` means "use the compiled value".
  ///
  /// Without it, `flutter test` always runs with an empty web client id and
  /// could not observe an Android build that wrongly forwards one.
  @visibleForTesting
  static String? debugGoogleWebClientId;

  /// True when this build can attempt Google sign-in.
  bool get isConfigured =>
      debugTokenProvider != null || ErasFirebaseConfig.isConfigured;

  /// The OAuth client configuration this build hands to `GoogleSignIn`.
  ///
  /// Exposed for tests: it is the single place that decides which OAuth
  /// identifiers reach the Google SDK, and [buildSignInClient] is the single
  /// place that turns them into a client.
  @visibleForTesting
  GoogleSignInClientConfig get clientConfig => resolveGoogleSignInClientConfig(
        isWeb: kIsWeb,
        platform: defaultTargetPlatform,
        googleWebClientId:
            debugGoogleWebClientId ?? ErasFirebaseConfig.googleWebClientId,
      );

  /// Builds the platform Google sign-in client from [clientConfig].
  ///
  /// `GoogleSignIn` forwards `clientId` and `serverClientId` verbatim to
  /// `GoogleSignInPlatform.initWithParams`, so what these two fields hold is
  /// exactly what the platform plugin receives.
  @visibleForTesting
  GoogleSignIn buildSignInClient() {
    final config = clientConfig;
    return GoogleSignIn(
      clientId: config.clientId,
      serverClientId: config.serverClientId,
      scopes: const <String>['email', 'profile'],
    );
  }

  GoogleSignIn get _googleSignIn => buildSignInClient();

  /// Runs the Google flow and returns the Firebase **ID token**.
  ///
  /// Returns null when the user dismissed the Google sheet without choosing an
  /// account (not an error: nothing is created and no session changes).
  ///
  /// Throws [GoogleAuthException] with a user-safe message on any real
  /// failure, so the UI can show one honest, non-technical string.
  Future<String?> signInAndGetIdToken() async {
    final injected = debugTokenProvider;
    if (injected != null) return injected();

    if (!ErasFirebaseConfig.isConfigured) {
      throw const GoogleAuthException(
        'Google sign-in is not configured for this ERAS deployment.',
      );
    }

    final ready = await ErasFirebaseConfig.ensureInitialized();
    if (!ready) {
      throw const GoogleAuthException(
        'Google sign-in is not configured for this ERAS deployment.',
      );
    }

    try {
      final account = await _googleSignIn.signIn();
      if (account == null) return null;

      final authentication = await account.authentication;
      if (authentication.idToken == null &&
          authentication.accessToken == null) {
        throw const GoogleAuthException(
          'Google did not return an identity token for this account.',
        );
      }

      final credential = GoogleAuthProvider.credential(
        idToken: authentication.idToken,
        accessToken: authentication.accessToken,
      );
      final userCredential =
          await FirebaseAuth.instance.signInWithCredential(credential);

      // Always read the token from Firebase Auth, so the value sent to ERAS is
      // a fresh Firebase ID token (never a raw Google token from the sheet).
      final idToken = await userCredential.user?.getIdToken();
      if (idToken == null || idToken.isEmpty) {
        throw const GoogleAuthException(
          'Google sign-in did not return a usable token. Please try again.',
        );
      }
      return idToken;
    } on GoogleAuthException {
      rethrow;
    } on FirebaseAuthException catch (error) {
      debugPrint('google sign-in failed: ${error.code}');
      throw GoogleAuthException(_messageForCode(error.code));
    } on PlatformException catch (error) {
      // Keep the native code and a redacted one-line message for diagnostics.
      // google_sign_in reports a dismissed account sheet as
      // `sign_in_canceled`. That is a normal user choice - no error, no
      // session change - so it must not be shown as a failure.
      _logPlatformDiagnostic('google sign-in cancelled/failed', error);
      if (error.code == 'sign_in_canceled') return null;
      throw const GoogleAuthException(
        'Google sign-in could not be completed on this device. '
        'You can still sign in with your email and password.',
      );
    } catch (error) {
      // Never stringify unexpected plugin errors: their payload may contain
      // auth material. The exception type is sufficient for safe diagnostics.
      debugPrint('google sign-in failed: unexpected=${error.runtimeType}');
      throw const GoogleAuthException(
        'Google sign-in could not be completed. '
        'You can still sign in with your email and password.',
      );
    }
  }

  /// Best-effort local sign-out of the Google/Firebase session.
  ///
  /// ERAS session teardown is owned by `ApiService.logout`; this only clears
  /// the upstream provider so the next attempt shows the account picker.
  Future<void> signOut() async {
    try {
      if (FirebaseAuth.instance.currentUser != null) {
        await FirebaseAuth.instance.signOut();
      }
      if (ErasFirebaseConfig.isConfigured) {
        await _googleSignIn.signOut();
      }
    } on PlatformException catch (error) {
      _logPlatformDiagnostic('google sign-out failed', error);
    } on FirebaseAuthException catch (error) {
      debugPrint('google sign-out failed: ${error.code}');
    } catch (error) {
      debugPrint('google sign-out failed: unexpected=${error.runtimeType}');
    }
  }

  /// Never surfaces raw Firebase codes; the user gets one actionable sentence.
  String _messageForCode(String code) {
    switch (code) {
      case 'account-exists-with-different-credential':
        return 'An account with this email already uses a different sign-in '
            'method. Sign in with that method to continue.';
      case 'network-request-failed':
        return 'Google sign-in needs a network connection. Please try again.';
      case 'user-disabled':
        return 'This account is disabled. Please contact your ERAS '
            'administrator.';
      case 'operation-not-allowed':
        return 'Google sign-in is not enabled for this Firebase project.';
      case 'user-mismatch':
      case 'invalid-credential':
        return 'Google sign-in could not verify this account. Please try again.';
      default:
        return 'Google sign-in could not be completed. '
            'You can still sign in with your email and password.';
    }
  }
}
