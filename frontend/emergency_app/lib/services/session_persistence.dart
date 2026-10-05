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

  /// Tail of the storage operation queue (see [_enqueue]).
  static Future<void> _tail = Future<void>.value();

  /// Runs [operation] after every storage operation the app queued before it.
  ///
  /// Login and logout never wait for the keystore before showing the next
  /// screen - a slow or unavailable keystore must not delay them - so their
  /// storage work runs in the background. The queue keeps those background
  /// operations in the order the app requested them: the delete issued by a
  /// logout can never overtake the write of the login that preceded it, which
  /// would otherwise leave a stale token behind.
  static Future<T> _enqueue<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  /// Writes [token] as the remembered session and records the choice.
  ///
  /// Returns true only when the token reached secure storage.
  static Future<bool> rememberSession(String token) {
    return _enqueue(() async {
      try {
        await _storage.write(key: _tokenKey, value: token);
        await _storage.write(key: _rememberKey, value: 'true');
        return true;
      } catch (error) {
        _reportFailure('remember-session', error);
        return false;
      }
    });
  }

  /// Removes the remembered session entirely.
  ///
  /// Used by logout, and by a login that did not ask to be remembered: neither
  /// may leave a long-lived session behind.
  static Future<void> forgetSession() {
    return _enqueue(() async {
      await _delete(_tokenKey);
      await _delete(_rememberKey);
      await _delete(_googleIntentKey);
    });
  }

  /// Removes only the stored token and keeps the remember-me preference.
  ///
  /// Used when the server no longer accepts a remembered token: there is
  /// nothing left to restore, but the login screen still shows the choice the
  /// user made last time.
  static Future<void> clearToken() {
    return _enqueue(() => _delete(_tokenKey));
  }

  /// The remembered ERAS JWT, or null when nothing usable is stored.
  static Future<String?> readToken() {
    return _enqueue(() async {
      try {
        final token = await _storage.read(key: _tokenKey);
        if (token == null) return null;
        final trimmed = token.trim();
        return trimmed.isEmpty ? null : trimmed;
      } catch (error) {
        _reportFailure('read-token', error);
        return null;
      }
    });
  }

  /// True when the last remembered login asked to be remembered.
  static Future<bool> readRememberPreference() {
    return _enqueue(() async {
      try {
        return (await _storage.read(key: _rememberKey)) == 'true';
      } catch (error) {
        _reportFailure('read-preference', error);
        return false;
      }
    });
  }

  /// Parks the "Remember me" choice for a Flutter Web Google redirect.
  static Future<void> markGoogleIntent(bool remember) {
    return _enqueue(() async {
      try {
        await _storage.write(
          key: _googleIntentKey,
          value: remember ? 'true' : 'false',
        );
      } catch (error) {
        _reportFailure('write-google-intent', error);
      }
    });
  }

  /// Reads and clears the parked Google choice.
  ///
  /// Null means no choice was parked (the non-redirect popup path, or a fresh
  /// sign-in).
  static Future<bool?> consumeGoogleIntent() {
    return _enqueue(() async {
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
    });
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
