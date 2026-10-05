import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'client_error_reporting.dart';

/// Persistent secure storage for the "Remember me" login option.
///
/// Only the ERAS session JWT and the (non-secret) remember-me preference are
/// ever written here. The account password is never stored anywhere - it
/// exists only inside the login request that authenticates it.
///
/// Platform behaviour:
///   * Android - the Android Keystore (flutter_secure_storage).
///   * iOS/macOS - the Keychain (flutter_secure_storage).
///   * Flutter Web - the plugin's WebCrypto-backed encrypted store.
///   * Anywhere secure storage is unavailable (widget tests, a browser without
///     WebCrypto, an unavailable keystore) every call degrades to "nothing was
///     remembered", so login and logout keep working.
///
/// A remembered token is never trusted on its own: it is re-validated against
/// the existing `GET /api/auth/me` endpoint before a session is restored (see
/// `ApiService.restoreRememberedSession`).
class SessionPersistence {
  SessionPersistence._();

  /// The stored ERAS JWT - the only secret this class ever writes.
  static const String _tokenKey = 'eras.session.token';

  /// The user's last "Remember me" choice. Not a secret: it only drives the
  /// login screen checkbox.
  static const String _rememberKey = 'eras.session.remember_me';

  /// A Flutter Web Google redirect reloads the whole app, so the checkbox
  /// choice is parked here until the interrupted sign-in completes.
  static const String _googleIntentKey = 'eras.session.google_remember_me';

  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  /// Writes [token] as the remembered session and records the choice.
  ///
  /// Returns true only when the token reached secure storage.
  static Future<bool> rememberSession(String token) async {
    try {
      await _storage.write(key: _tokenKey, value: token);
      await _storage.write(key: _rememberKey, value: 'true');
      return true;
    } catch (error) {
      _reportFailure('remember-session', error);
      return false;
    }
  }

  /// Removes the remembered session entirely.
  ///
  /// Used by logout, and by a login that did not ask to be remembered: neither
  /// may leave a long-lived session behind.
  static Future<void> forgetSession() async {
    await _delete(_tokenKey);
    await _delete(_rememberKey);
    await _delete(_googleIntentKey);
  }

  /// Removes only the stored token and keeps the remember-me preference.
  ///
  /// Used when the server no longer accepts a remembered token: there is
  /// nothing left to restore, but the login screen still shows the choice the
  /// user made last time.
  static Future<void> clearToken() async {
    await _delete(_tokenKey);
  }

  /// The remembered ERAS JWT, or null when nothing usable is stored.
  static Future<String?> readToken() async {
    try {
      final token = await _storage.read(key: _tokenKey);
      if (token == null) return null;
      final trimmed = token.trim();
      return trimmed.isEmpty ? null : trimmed;
    } catch (error) {
      _reportFailure('read-token', error);
      return null;
    }
  }

  /// True when the last remembered login asked to be remembered.
  static Future<bool> readRememberPreference() async {
    try {
      return (await _storage.read(key: _rememberKey)) == 'true';
    } catch (error) {
      _reportFailure('read-preference', error);
      return false;
    }
  }

  /// Parks the "Remember me" choice for a Flutter Web Google redirect.
  static Future<void> markGoogleIntent(bool remember) async {
    try {
      await _storage.write(
        key: _googleIntentKey,
        value: remember ? 'true' : 'false',
      );
    } catch (error) {
      _reportFailure('write-google-intent', error);
    }
  }

  /// Reads and clears the parked Google choice.
  ///
  /// Null means no choice was parked (the non-redirect popup path, or a fresh
  /// sign-in).
  static Future<bool?> consumeGoogleIntent() async {
    try {
      final value = await _storage.read(key: _googleIntentKey);
      if (value != null) await _storage.delete(key: _googleIntentKey);
      if (value == 'true') return true;
      if (value == 'false') return false;
      return null;
    } catch (error) {
      _reportFailure('read-google-intent', error);
      return null;
    }
  }

  static Future<void> _delete(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (error) {
      _reportFailure('delete-key', error);
    }
  }

  /// One secret-free diagnostic line; the values themselves are never logged.
  static void _reportFailure(String action, Object error) {
    logErasClientDiagnostic('remember-me-storage:$action', error);
  }
}
