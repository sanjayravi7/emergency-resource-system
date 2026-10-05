import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_bootstrap.dart';

/// Shown when this build has no usable Firebase/Google configuration at all.
const String erasGoogleNotConfiguredMessage =
    'Google sign-in is not configured for this ERAS deployment.';

/// Shown for every Google failure that has no more specific explanation.
const String erasGoogleGenericFailureMessage =
    'Google sign-in could not be completed. Please try again. '
    'You can still sign in with your email and password.';

/// Raised when Google sign-in cannot complete. The message is safe to show.
class GoogleAuthException implements Exception {
  const GoogleAuthException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Which mechanism a build uses to obtain a Google identity proof.
enum GoogleSignInStrategy {
  /// Flutter Web: Firebase Auth runs the Google OAuth flow itself
  /// (`signInWithPopup`, falling back to `signInWithRedirect`) and returns a
  /// real Firebase ID token.
  firebaseWebPopup,

  /// Android/iOS/desktop: the platform Google account picker returns a Google
  /// credential, which is then exchanged with Firebase Auth.
  nativeAccountPicker,
}

/// Chooses the Google authentication mechanism for a platform.
///
/// Web and native are deliberately different code paths:
///
///   * On Web, `google_sign_in`'s `signIn()` is an OAuth2 *authorization* flow
///     (`google.accounts.oauth2` token client). The plugin documents that it
///     "can't reliably provide an `idToken`" there and synthesizes identity
///     from the People API, which left ERAS exchanging an access token that
///     Firebase rejected. Firebase Auth's own popup/redirect flow is the
///     supported Web mechanism and returns a Firebase ID token directly.
///   * On Android/iOS the account picker plus `signInWithCredential` is the
///     supported mechanism and keeps working unchanged.
@visibleForTesting
GoogleSignInStrategy resolveGoogleSignInStrategy({required bool isWeb}) {
  if (isWeb) return GoogleSignInStrategy.firebaseWebPopup;
  return GoogleSignInStrategy.nativeAccountPicker;
}

/// Removes credential-like values before a diagnostic is written to logs.
///
/// Shared by the Google auth diagnostics and the global client error handler,
/// so it is part of the production surface, not just a test seam. The returned
/// message is bounded and contains no raw auth payloads.
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

  /// The OAuth client id of the app. Native platforms leave this unset so the
  /// platform configuration file (`google-services.json` /
  /// `GoogleService-Info.plist`) remains authoritative for the installed app;
  /// Flutter Web no longer builds a `GoogleSignIn` at all (see
  /// [resolveGoogleSignInStrategy]).
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

/// Resolves the OAuth client identifiers a native `GoogleSignIn` receives.
///
/// **Android.** The Google Sign-In SDK identifies an Android app by its package
/// name plus the SHA-1 of its signing certificate — not by the Web client id.
/// The Web client id is the ID-token audience (`serverClientId`). It is read
/// from `default_web_client_id` when no Dart value is supplied, but this app
/// passes the configured Web OAuth client explicitly so the native request is
/// deterministic even when the Gradle-generated resource is unavailable.
/// `clientId` remains unset on Android because it is not an Android app client
/// override.
///
/// The value comes from `ErasFirebaseConfig.googleWebClientId` (including the
/// existing `ERAS_GOOGLE_WEB_CLIENT_ID` build configuration), rather than a
/// hardcoded Dart credential. It must still be the Web client linked to this
/// Firebase project and Android app; otherwise Google can reject the request
/// with `CommonStatusCodes.DEVELOPER_ERROR` (status 10).
///
/// So the rule is:
///
///   * Web: this function retains the existing Web configuration. The actual
///     sign-in path uses Firebase Auth's own Google popup/redirect flow.
///   * Android, iOS, macOS and desktop: `clientId` stays null, while a
///     configured Web client id is passed as `serverClientId`. An empty Web
///     client id remains null so platform configuration can supply it.
@visibleForTesting
GoogleSignInClientConfig resolveGoogleSignInClientConfig({
  required bool isWeb,
  required TargetPlatform platform,
  required String googleWebClientId,
}) {
  final webClientId = googleWebClientId.trim();
  if (isWeb) {
    return GoogleSignInClientConfig(
      // Kept for builds that still construct a legacy GoogleSignIn on web: an
      // empty value keeps the plugin's own detection (meta tag) in charge,
      // which is exactly what an unconfigured build needs.
      clientId: webClientId.isEmpty ? null : webClientId,
      serverClientId: null,
    );
  }

  // Native platforms use the Web OAuth client as the ID-token audience. Keep
  // clientId null so the platform-specific app registration remains in charge
  // of identifying the installed app.
  switch (platform) {
    case TargetPlatform.android:
    case TargetPlatform.iOS:
    case TargetPlatform.macOS:
    case TargetPlatform.linux:
    case TargetPlatform.windows:
    case TargetPlatform.fuchsia:
      return GoogleSignInClientConfig(
        serverClientId: webClientId.isEmpty ? null : webClientId,
      );
  }
}

/// The outcome of one Google authentication attempt.
enum GoogleSignInStatus {
  /// A Firebase/Google ID token was obtained and can be exchanged with ERAS.
  completed,

  /// The user dismissed Google's UI. Nothing changed; no error to show.
  cancelled,

  /// Flutter Web only: the browser is navigating to Google's redirect handler.
  /// The flow continues through [GoogleAuthService.resumeWebSignIn] once the
  /// page reloads.
  redirecting,
}

/// The result of starting a Google authentication.
///
/// Never carries anything except the Firebase ID token: no Google access
/// token, refresh token, password or OAuth secret is kept or returned.
@immutable
class GoogleSignInOutcome {
  const GoogleSignInOutcome._(this.status, this.idToken);

  const GoogleSignInOutcome.completed(String idToken)
      : this._(GoogleSignInStatus.completed, idToken);

  const GoogleSignInOutcome.cancelled()
      : this._(GoogleSignInStatus.cancelled, null);

  const GoogleSignInOutcome.redirecting()
      : this._(GoogleSignInStatus.redirecting, null);

  final GoogleSignInStatus status;

  /// The Firebase ID token, set only for [GoogleSignInStatus.completed].
  final String? idToken;

  bool get isCompleted => status == GoogleSignInStatus.completed;

  bool get isRedirecting => status == GoogleSignInStatus.redirecting;

  @override
  String toString() => 'GoogleSignInOutcome(status: ${status.name})';
}

/// A sign-in that Flutter Web left pending and that is resumed after a reload.
@immutable
class GoogleWebResumeResult {
  const GoogleWebResumeResult({required this.outcome, this.registration});

  final GoogleSignInOutcome outcome;

  /// The first-time ERAS registration details a redirect was started with, if
  /// the user came from the registration screen.
  final GoogleRegistrationRequest? registration;
}

/// The public ERAS registration choice of a first-time Google user.
///
/// Only ever a *request*: the backend ignores it for a known Firebase UID or an
/// email that already has an ERAS account, and can never create an ADMIN.
/// Flutter Web persists it before a redirect fallback because the page reloads.
@immutable
class GoogleRegistrationRequest {
  const GoogleRegistrationRequest({required this.role, this.name, this.phone});

  /// The only roles public registration may request; mirrors the backend
  /// allowlist.
  static const Set<String> publicRoles = <String>{'REQUESTER', 'RESPONDER'};

  static const String _storageKey = 'eras.google.pending_registration';

  final String role;
  final String? name;
  final String? phone;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'role': role,
        if (name != null && name!.trim().isNotEmpty) 'name': name!.trim(),
        if (phone != null && phone!.trim().isNotEmpty) 'phone': phone!.trim(),
      };

  /// Stores [request] for a Web redirect return, or clears the pending request
  /// when [request] is null. Storage failures are never fatal.
  static Future<void> persist(GoogleRegistrationRequest? request) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      if (request == null) {
        await preferences.remove(_storageKey);
        return;
      }
      await preferences.setString(_storageKey, jsonEncode(request.toJson()));
    } catch (error) {
      _logUnexpectedFailure('google registration persistence failed', error);
    }
  }

  /// Reads and clears the pending request.
  ///
  /// Malformed values — including a role the backend would reject — are
  /// discarded instead of being forwarded.
  static Future<GoogleRegistrationRequest?> consume() async {
    String? raw;
    try {
      final preferences = await SharedPreferences.getInstance();
      raw = preferences.getString(_storageKey);
      if (raw != null) await preferences.remove(_storageKey);
    } catch (error) {
      _logUnexpectedFailure('google registration restore failed', error);
      return null;
    }
    if (raw == null || raw.isEmpty) return null;

    dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;

    final role = _nonEmptyText(decoded['role'])?.toUpperCase();
    if (role == null || !publicRoles.contains(role)) return null;

    return GoogleRegistrationRequest(
      role: role,
      name: _nonEmptyText(decoded['name']),
      phone: _nonEmptyText(decoded['phone']),
    );
  }

  /// Returns a trimmed non-empty string, or null for anything else.
  static String? _nonEmptyText(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  @override
  bool operator ==(Object other) =>
      other is GoogleRegistrationRequest &&
      other.role == role &&
      other.name == name &&
      other.phone == phone;

  @override
  int get hashCode => Object.hash(role, name, phone);

  @override
  String toString() => 'GoogleRegistrationRequest(role: $role)';
}

/// The Firebase Auth calls the Flutter Web sign-in path depends on.
///
/// Behind an interface so the Web branch stays unit-testable on the VM (where
/// `kIsWeb` is always false) and so tests never touch a real Firebase project.
abstract class WebGoogleSignInHandler {
  /// Runs the popup flow, or starts the redirect flow when the browser blocks
  /// popups.
  Future<GoogleSignInOutcome> signIn();

  /// Completes a redirect return or restores Firebase's persisted session.
  /// Returns null when there is nothing to resume.
  Future<GoogleSignInOutcome?> resume();

  Future<void> signOut();
}

/// Production Web implementation: Firebase Auth owns Google's OAuth UI.
///
/// Firebase validates the popup/redirect against the `authDomain` of the
/// initialized Firebase app, so the deployed origin must be an authorized
/// domain in Firebase Authentication (the Firebase Hosting domains of the
/// project are authorized by default).
class FirebaseWebGoogleSignInHandler implements WebGoogleSignInHandler {
  const FirebaseWebGoogleSignInHandler();

  @override
  Future<GoogleSignInOutcome> signIn() async {
    final auth = FirebaseAuth.instance;
    try {
      final credential = await auth.signInWithPopup(GoogleAuthProvider());
      return GoogleSignInOutcome.completed(await _firebaseIdToken(credential));
    } on FirebaseAuthException catch (error) {
      return _handleSignInFailure(auth, error);
    } on PlatformException catch (error) {
      _logPlatformDiagnostic('google web sign-in failed', error);
      throw GoogleAuthException(googleAuthErrorMessageForCode(error.code));
    } catch (error) {
      _logUnexpectedFailure('google web sign-in failed', error);
      throw const GoogleAuthException(erasGoogleGenericFailureMessage);
    }
  }

  @override
  Future<GoogleSignInOutcome?> resume() async {
    final auth = FirebaseAuth.instance;

    // 1. An explicit redirect return. This also surfaces a redirect error that
    //    would otherwise be lost with the page reload.
    try {
      final credential = await auth.getRedirectResult();
      if (credential.user != null) {
        return GoogleSignInOutcome.completed(
            await _firebaseIdToken(credential));
      }
    } on FirebaseAuthException catch (error) {
      if (error.code == 'popup-closed-by-user' ||
          error.code == 'cancelled-popup-request') {
        return null;
      }
      _logGoogleAuthDiagnostic('google web redirect failed', code: error.code);
      throw GoogleAuthException(googleAuthErrorMessageForCode(error.code));
    } catch (error) {
      // Nothing pending, or the result was already consumed: the persisted
      // session below decides. Never block the login page on this.
      _logUnexpectedFailure('google web redirect result unavailable', error);
    }

    // 2. Firebase Auth keeps the Google session across reloads (IndexedDB), so
    //    a refresh - or a redirect return the SDK already consumed - only needs
    //    a fresh ID token, never another popup.
    final user = auth.currentUser;
    if (user == null) return null;

    try {
      final token = await user.getIdToken();
      if (token == null || token.isEmpty) return null;
      return GoogleSignInOutcome.completed(token);
    } on FirebaseAuthException catch (error) {
      _logGoogleAuthDiagnostic(
        'google web session restore failed',
        code: error.code,
      );
      await _signOutQuietly(auth);
      return null;
    } catch (error) {
      _logUnexpectedFailure('google web session restore failed', error);
      return null;
    }
  }

  @override
  Future<void> signOut() async {
    await FirebaseAuth.instance.signOut();
  }

  /// A browser without (allowed) popups continues in the same tab instead of
  /// failing: Firebase restores the session when the page comes back.
  Future<GoogleSignInOutcome> _handleSignInFailure(
    FirebaseAuth auth,
    FirebaseAuthException error,
  ) async {
    switch (error.code) {
      case 'popup-closed-by-user':
      case 'cancelled-popup-request':
        // The user closed Google's window: nothing happened, nothing to show.
        return const GoogleSignInOutcome.cancelled();
      case 'popup-blocked':
      case 'operation-not-supported-in-this-environment':
        _logGoogleAuthDiagnostic(
          'google web popup unavailable, using redirect',
          code: error.code,
        );
        try {
          await auth.signInWithRedirect(GoogleAuthProvider());
        } on FirebaseAuthException catch (redirectError) {
          throw GoogleAuthException(
            googleAuthErrorMessageForCode(redirectError.code),
          );
        }
        return const GoogleSignInOutcome.redirecting();
      default:
        _logGoogleAuthDiagnostic('google web sign-in failed', code: error.code);
        throw GoogleAuthException(googleAuthErrorMessageForCode(error.code));
    }
  }
}

/// Maps a Firebase Auth error code to one safe, actionable sentence.
///
/// The raw code never reaches the user; it is written to the diagnostic log by
/// the caller instead.
@visibleForTesting
String googleAuthErrorMessageForCode(String? code) {
  final normalized = (code ?? '').trim();
  final bareCode = normalized.startsWith('auth/')
      ? normalized.substring('auth/'.length)
      : normalized;
  switch (bareCode) {
    case 'popup-blocked':
      return 'Your browser blocked the Google sign-in window. Allow pop-ups '
          'for this site and try again.';
    case 'popup-closed-by-user':
    case 'cancelled-popup-request':
      return 'Google sign-in was cancelled. Please try again.';
    case 'unauthorized-domain':
      return 'This website is not authorised for Google sign-in yet. Add this '
          'domain to the Firebase Authentication authorized domains.';
    case 'operation-not-allowed':
      return 'Google sign-in is not enabled for this Firebase project.';
    case 'account-exists-with-different-credential':
      return 'An account with this email already uses a different sign-in '
          'method. Sign in with that method to continue.';
    case 'network-request-failed':
      return 'Google sign-in needs a network connection. Please try again.';
    case 'user-disabled':
      return 'This account is disabled. Please contact your ERAS '
          'administrator.';
    case 'too-many-requests':
      return 'Too many Google sign-in attempts. Please wait a moment and try '
          'again.';
    case 'timeout':
      return 'Google sign-in timed out. Please try again.';
    case 'invalid-credential':
    case 'user-mismatch':
    case 'internal-error':
      return 'Google sign-in could not verify this account. Please try again.';
    case 'invalid-api-key':
    case 'api-key-not-valid':
    case 'app-not-authorized':
    case 'configuration-not-found':
      return 'This ERAS build is not accepted by Firebase for Google sign-in. '
          'Please contact your ERAS administrator.';
    case 'web-storage-unsupported':
      return 'Google sign-in needs browser storage to finish. Allow site data '
          'for this site (private windows block it) and try again.';
    default:
      return erasGoogleGenericFailureMessage;
  }
}

/// `CommonStatusCodes.DEVELOPER_ERROR`.
///
/// Google Play services returns this status when the request itself is not
/// authorized: the package name or the signing certificate fingerprint does
/// not match the Android OAuth client the Firebase/Google Cloud project has
/// registered for this app. It is a build/console problem, never a user
/// problem, and no retry or code path can work around it.
const int googleDeveloperErrorStatusCode = 10;

/// A failure reported by the platform Google Sign-In SDK.
///
/// `google_sign_in` surfaces native failures in two shapes depending on the
/// pinned plugin version: a `PlatformException` (code `sign_in_failed`,
/// message `h2: 10` for DEVELOPER_ERROR) or the newer `GoogleSignInException`,
/// which is a plain `Exception` and therefore slips past an
/// `on PlatformException` handler. Both carry the same facts, so ERAS
/// normalises them into one value that is safe to log and easy to map to an
/// honest user-facing sentence.
@immutable
class GoogleNativeSignInFailure {
  const GoogleNativeSignInFailure({
    required this.code,
    this.statusCode,
    this.detail,
    this.cancelled = false,
  });

  /// The plugin/SDK error code (for example `sign_in_failed`).
  final String code;

  /// The Google Play services status code when it can be recovered.
  final int? statusCode;

  /// Sanitized one-line detail for the diagnostic log. Never raw.
  final String? detail;

  /// True when the user dismissed Google's account picker.
  final bool cancelled;

  /// Google refused the request because this build is not registered for it.
  bool get isDeveloperError => statusCode == googleDeveloperErrorStatusCode;

  @override
  String toString() =>
      'GoogleNativeSignInFailure(code: $code, statusCode: $statusCode)';
}

int? _nativeStatusCode(Object? details) {
  if (details is int) return details;
  if (details is Map) {
    for (final key in <String>[
      'statusCode',
      'status_code',
      'errorCode',
      'error_code',
      'code',
    ]) {
      final value = details[key];
      if (value is int) return value;
      if (value is String) return int.tryParse(value);
    }
  }
  return null;
}

/// Recovers a status code from a plugin message such as `h2: 10`.
///
/// The class name is R8-obfuscated and changes with every build, so the
/// trailing integer is the only stable part.
int? _statusCodeFromText(String? text) {
  if (text == null || text.isEmpty) return null;
  final matches = RegExp(r'\b(\d{1,6})\b').allMatches(text).toList();
  if (matches.isEmpty) return null;
  return int.tryParse(matches.last.group(1)!);
}

bool _isCancellation(String? value) {
  if (value == null || value.isEmpty) return false;
  return value.toLowerCase().contains('cancel');
}

/// Normalises an error raised by the platform Google Sign-In SDK.
///
/// Returns null when [error] did not come from Google Sign-In, so callers can
/// keep their existing "unexpected failure" handling for everything else.
///
/// The runtime type - not a type test - is what identifies
/// `GoogleSignInException`: importing a class the pinned plugin may not export
/// would couple this file to one plugin version, while the runtime type check
/// works with every shape the plugin uses.
@visibleForTesting
GoogleNativeSignInFailure? describeGoogleSignInFailure(Object error) {
  if (error is PlatformException) {
    return GoogleNativeSignInFailure(
      code: error.code,
      statusCode: _nativeStatusCode(error.details) ??
          _statusCodeFromText(error.message),
      detail: sanitizeGoogleAuthDiagnosticMessage(error.message),
      cancelled: _isCancellation(error.code) || _isCancellation(error.message),
    );
  }

  final type = error.runtimeType.toString();
  if (type.endsWith('GoogleSignInException')) {
    final detail = sanitizeGoogleAuthDiagnosticMessage(error.toString());
    return GoogleNativeSignInFailure(
      code: type,
      statusCode: _statusCodeFromText(detail),
      detail: detail,
      cancelled: _isCancellation(detail),
    );
  }

  return null;
}

/// One honest sentence for a native Google Sign-In failure.
///
/// DEVELOPER_ERROR is called out because "try again" is actively wrong there:
/// the build is not registered with Google, so the administrator has to add
/// the release signing fingerprint to the Firebase Android app (Google Cloud
/// Console -> the auto-created Android OAuth client) and ship a new build.
/// Every other native failure keeps the previous wording.
@visibleForTesting
String nativeGoogleSignInMessage(GoogleNativeSignInFailure failure) {
  if (failure.isDeveloperError) {
    return 'Google sign-in is not registered for this ERAS build yet. '
        'Ask your ERAS administrator to add this app\'s release signing '
        'certificate (SHA-1) to the Firebase Android app and install a new '
        'build. You can still sign in with your email and password.';
  }
  return 'Google sign-in could not be completed on this device. '
      'You can still sign in with your email and password.';
}

/// Writes one sanitized line for a native failure.
///
/// The status code is what makes a release-APK failure diagnosable from
/// `adb logcat`: it distinguishes a configuration problem (10) from a network
/// or account problem without ever logging credential material.
void _logNativeFailure(String operation, GoogleNativeSignInFailure failure) {
  _logGoogleAuthDiagnostic(
    operation,
    code: failure.code,
    detail: failure.detail,
  );
  if (failure.statusCode != null) {
    debugPrint('[eras-auth] $operation statusCode=${failure.statusCode}');
  }
}

/// The Firebase ID token of a completed sign-in.
///
/// A missing token is a failed sign-in, never a silent success: the ERAS
/// backend can only be reached with a verifiable token.
Future<String> _firebaseIdToken(UserCredential credential) async {
  final user = credential.user;
  if (user == null) {
    throw const GoogleAuthException(
      'Google did not return a signed-in account. Please try again.',
    );
  }
  final token = await user.getIdToken();
  if (token == null || token.isEmpty) {
    throw const GoogleAuthException(
      'Google sign-in did not return a usable token. Please try again.',
    );
  }
  return token;
}

/// Signs out of Firebase without letting a provider failure escape.
Future<void> _signOutQuietly(FirebaseAuth auth) async {
  try {
    await auth.signOut();
  } catch (error) {
    _logUnexpectedFailure('google sign-out failed', error);
  }
}

void _logGoogleAuthDiagnostic(String event, {String? code, String? detail}) {
  final buffer = StringBuffer('[eras-auth] $event');
  if (code != null && code.isNotEmpty) {
    buffer.write(' code=$code');
  }
  if (detail != null && detail.isNotEmpty) {
    buffer.write(' detail=${sanitizeGoogleAuthDiagnosticMessage(detail)}');
  }
  debugPrint(buffer.toString());
}

/// Logs the exception type only: plugin payloads can carry auth material.
void _logUnexpectedFailure(String event, Object? error) {
  _logGoogleAuthDiagnostic(event, detail: 'unexpected=${error.runtimeType}');
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
  _logGoogleAuthDiagnostic(
    operation,
    code: error.code,
    detail: sanitizeGoogleAuthDiagnosticMessage(error.message),
  );
  final details = _safePlatformDetails(error.details);
  if (details.isNotEmpty) debugPrint('[eras-auth] $operation$details');
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
/// Flutter Web uses Firebase Auth's popup (with a redirect fallback); Android
/// and iOS keep the platform Google account picker. The service is
/// intentionally thin and testable: it exposes injectable seams so widget/unit
/// tests never need a real Google account or browser.
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

  /// Test seam: forces the Flutter Web strategy on the VM test runner.
  @visibleForTesting
  static bool? debugUseWebFlow;

  /// Test seam: replaces the Firebase Auth Web calls.
  @visibleForTesting
  static WebGoogleSignInHandler? debugWebHandler;

  /// Test seam: replaces the "this build has Firebase configuration" check.
  @visibleForTesting
  static bool? debugFirebaseConfigured;

  /// Test seam: replaces `Firebase.initializeApp` readiness.
  @visibleForTesting
  static Future<bool> Function() debugEnsureFirebaseReady =
      ErasFirebaseConfig.ensureInitialized;

  /// True when this build can attempt Google sign-in.
  bool get isConfigured {
    final forced = debugFirebaseConfigured;
    if (forced != null) return forced;
    if (debugTokenProvider != null) return true;
    return ErasFirebaseConfig.isConfigured;
  }

  /// True when Google authentication runs through Firebase Auth's Web flow.
  bool get usesWebSignInFlow => debugUseWebFlow ?? kIsWeb;

  /// The mechanism this build uses (see [resolveGoogleSignInStrategy]).
  GoogleSignInStrategy get strategy =>
      resolveGoogleSignInStrategy(isWeb: usesWebSignInFlow);

  /// The OAuth client configuration this build hands to `GoogleSignIn`.
  ///
  /// Native only: the Web path never constructs a `GoogleSignIn`. Exposed for
  /// tests because it is the single place that decides which OAuth identifiers
  /// reach the Google SDK, and [buildSignInClient] is the single place that
  /// turns them into a client.
  @visibleForTesting
  GoogleSignInClientConfig get clientConfig {
    final webClientId =
        debugGoogleWebClientId ?? ErasFirebaseConfig.googleWebClientId;
    return resolveGoogleSignInClientConfig(
      isWeb: usesWebSignInFlow,
      platform: defaultTargetPlatform,
      googleWebClientId: webClientId,
    );
  }

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

  /// The native Google Sign-In client, created at most once.
  ///
  /// `GoogleSignIn` keeps the account that completed `signIn()` on the
  /// instance that produced it, so `signOut()` has to talk to that same client
  /// - building a fresh one on every access re-runs `initWithParams` against
  /// the native SDK and would leave the previous account behind.
  GoogleSignIn get _googleSignIn => _signInClient ??= buildSignInClient();

  GoogleSignIn? _signInClient;

  WebGoogleSignInHandler get _webHandler =>
      debugWebHandler ?? const FirebaseWebGoogleSignInHandler();

  /// Runs the Google flow and returns the Firebase **ID token**.
  ///
  /// Returns null when the user dismissed the Google UI (not an error: nothing
  /// is created and no session changes) or when Flutter Web switched to a
  /// redirect and the flow resumes after the reload.
  ///
  /// Throws [GoogleAuthException] with a user-safe message on any real
  /// failure, so the UI can show one honest, non-technical string.
  Future<String?> signInAndGetIdToken() async => (await signIn()).idToken;

  /// Starts Google authentication.
  ///
  /// [registration] is the public role a first-time Google user selected on the
  /// registration screen. It is only ever a request for a brand-new ERAS
  /// account; the backend ignores it for an existing account.
  Future<GoogleSignInOutcome> signIn({
    GoogleRegistrationRequest? registration,
  }) async {
    final injected = debugTokenProvider;
    if (injected != null) {
      final token = await injected();
      if (token == null || token.isEmpty) {
        return const GoogleSignInOutcome.cancelled();
      }
      return GoogleSignInOutcome.completed(token);
    }

    if (!isConfigured) {
      throw const GoogleAuthException(erasGoogleNotConfiguredMessage);
    }

    final ready = await debugEnsureFirebaseReady();
    if (!ready) {
      throw const GoogleAuthException(erasGoogleNotConfiguredMessage);
    }

    switch (strategy) {
      case GoogleSignInStrategy.firebaseWebPopup:
        // A Web redirect reloads the page, so the registration choice must
        // survive it. Login attempts clear anything a previous aborted
        // redirect left behind.
        await GoogleRegistrationRequest.persist(registration);
        return _webHandler.signIn();
      case GoogleSignInStrategy.nativeAccountPicker:
        // Native sign-in never reloads the page: nothing to persist.
        await GoogleRegistrationRequest.persist(null);
        return _signInWithAccountPicker();
    }
  }

  /// Flutter Web only: completes a Google sign-in that Firebase left pending.
  ///
  /// Called once when the login/registration screen appears. Returns null when
  /// there is nothing to resume, which is the normal case for every native
  /// platform and for a browser with no Google session.
  Future<GoogleWebResumeResult?> resumeWebSignIn() async {
    if (!usesWebSignInFlow) return null;
    if (debugTokenProvider != null) return null;
    if (!isConfigured) return null;
    if (!await debugEnsureFirebaseReady()) return null;

    final outcome = await _webHandler.resume();
    if (outcome == null) {
      // No pending Google session: drop a stale registration choice so it can
      // never be applied to an unrelated later sign-in.
      await GoogleRegistrationRequest.persist(null);
      return null;
    }

    return GoogleWebResumeResult(
      outcome: outcome,
      registration: await GoogleRegistrationRequest.consume(),
    );
  }

  /// Android/iOS/desktop: account picker plus Firebase credential exchange.
  Future<GoogleSignInOutcome> _signInWithAccountPicker() async {
    try {
      final account = await _googleSignIn.signIn();
      if (account == null) return const GoogleSignInOutcome.cancelled();

      final authentication = await account.authentication;
      final idToken = authentication.idToken;
      final accessToken = authentication.accessToken;
      if (idToken == null) {
        // google_sign_in only asks Google for an ID token when a server
        // client id is configured. Native builds receive that audience from
        // the configured Web OAuth client (with the generated resource as a
        // platform fallback), so a missing ID token indicates incomplete
        // native OAuth configuration. Firebase can still exchange an access
        // token, so this is a diagnostic, not a failure.
        _logGoogleAuthDiagnostic(
          'google sign-in returned no id token',
          detail: accessToken == null ? 'no-token' : 'access-token-only',
        );
      }
      if (idToken == null && accessToken == null) {
        throw const GoogleAuthException(
          'Google did not return an identity token for this account.',
        );
      }

      final credential = GoogleAuthProvider.credential(
        idToken: idToken,
        accessToken: accessToken,
      );
      final userCredential =
          await FirebaseAuth.instance.signInWithCredential(credential);

      // Always read the token from Firebase Auth, so the value sent to ERAS is
      // a fresh Firebase ID token (never a raw Google token from the sheet).
      final token = await userCredential.user?.getIdToken();
      if (token == null || token.isEmpty) {
        throw const GoogleAuthException(
          'Google sign-in did not return a usable token. Please try again.',
        );
      }
      return GoogleSignInOutcome.completed(token);
    } on GoogleAuthException {
      rethrow;
    } on FirebaseAuthException catch (error) {
      _logGoogleAuthDiagnostic('google sign-in failed', code: error.code);
      throw GoogleAuthException(googleAuthErrorMessageForCode(error.code));
    } on PlatformException catch (error) {
      // Keep the native code and a redacted one-line message for diagnostics.
      // google_sign_in reports a dismissed account sheet as
      // `sign_in_canceled`. That is a normal user choice - no error, no
      // session change - so it must not be shown as a failure.
      final failure = describeGoogleSignInFailure(error) ??
          GoogleNativeSignInFailure(
            code: error.code,
            detail: sanitizeGoogleAuthDiagnosticMessage(error.message),
          );
      _logNativeFailure('google sign-in cancelled/failed', failure);
      if (failure.cancelled) return const GoogleSignInOutcome.cancelled();
      throw GoogleAuthException(nativeGoogleSignInMessage(failure));
    } catch (error) {
      // google_sign_in >= 6.2 raises `GoogleSignInException` - a plain
      // Exception, not a PlatformException - for native failures. Without this
      // branch a release-APK DEVELOPER_ERROR (10), the signature of an Android
      // OAuth client that does not list this build's signing certificate, was
      // swallowed by the generic message and could not be told apart from a
      // network hiccup.
      final nativeFailure = describeGoogleSignInFailure(error);
      if (nativeFailure != null) {
        _logNativeFailure('google sign-in cancelled/failed', nativeFailure);
        if (nativeFailure.cancelled) {
          return const GoogleSignInOutcome.cancelled();
        }
        throw GoogleAuthException(nativeGoogleSignInMessage(nativeFailure));
      }
      // Never stringify unexpected plugin errors: their payload may contain
      // auth material. The exception type is sufficient for safe diagnostics.
      _logUnexpectedFailure('google sign-in failed', error);
      throw const GoogleAuthException(erasGoogleGenericFailureMessage);
    }
  }

  /// Best-effort local sign-out of the Google/Firebase session.
  ///
  /// ERAS session teardown is owned by `ApiService.logout`; this only clears
  /// the upstream provider so the next attempt shows the account picker.
  Future<void> signOut() async {
    try {
      if (usesWebSignInFlow) {
        // The web session lives in Firebase Auth; the handler owns that call
        // so the path stays testable (and cannot throw) without a Firebase
        // project initialised on the VM.
        try {
          await _webHandler.signOut();
        } catch (error) {
          _logUnexpectedFailure('google sign-out failed', error);
        }
        return;
      }
      if (!isConfigured) return;
      await _signOutQuietly(FirebaseAuth.instance);
      await _googleSignIn.signOut();
    } on PlatformException catch (error) {
      _logPlatformDiagnostic('google sign-out failed', error);
    } catch (error) {
      _logUnexpectedFailure('google sign-out failed', error);
    }
  }
}
