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

  /// True when this build can attempt Google sign-in.
  bool get isConfigured =>
      debugTokenProvider != null || ErasFirebaseConfig.isConfigured;

  GoogleSignIn get _googleSignIn => GoogleSignIn(
        // Web needs the Google *web* client id; an empty value keeps the
        // platform default (which is exactly what unconfigured builds get).
        clientId: kIsWeb && ErasFirebaseConfig.googleWebClientId.isNotEmpty
            ? ErasFirebaseConfig.googleWebClientId
            : null,
        // Native platforms return an ID token whose audience is this client.
        serverClientId: ErasFirebaseConfig.googleWebClientId.isEmpty
            ? null
            : ErasFirebaseConfig.googleWebClientId,
        scopes: const <String>['email', 'profile'],
      );

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
