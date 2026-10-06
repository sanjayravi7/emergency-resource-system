@TestOn('browser')
library;

// Web persistence of the ERAS "Remember me" session.
//
// Runs on a browser platform only:
//
//   flutter test --platform chrome test/web_session_persistence_test.dart
//
// It exercises the real `flutter_secure_storage_web` implementation (not the
// in-memory test platform `test/flutter_test_config.dart` installs) and pins
// the three properties the Web requirement depends on:
//
//   * the remembered session is written to PERSISTENT browser storage
//     (`localStorage`, default `WebOptions.useSessionStorage: false`) and never
//     to session-only storage, so it survives a page refresh, a tab close and a
//     browser restart;
//   * what is stored is ciphertext - the ERAS JWT itself never appears in
//     browser storage;
//   * a fresh store instance (what the plugin does after a page reload)
//     decrypts the same entry again, and logout's delete removes it.

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_secure_storage_web/flutter_secure_storage_web.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;

/// The ERAS key names, mirrored from `lib/services/session_persistence.dart`.
const String tokenKey = 'eras.session.token';
const String rememberKey = 'eras.session.remember_me';
const String sampleToken = 'web-session-token';

List<String> _keys(web.Storage storage) {
  final keys = <String>[];
  for (var i = 0; i < storage.length; i++) {
    keys.add(storage.key(i) ?? '');
  }
  return keys;
}

void main() {
  // The shared bootstrap installs the in-memory test platform; this suite must
  // exercise the real browser implementation instead.
  FlutterSecureStoragePlatform.instance = FlutterSecureStorageWeb();

  setUp(() async {
    const store = FlutterSecureStorage();
    await store.delete(key: tokenKey);
    await store.delete(key: rememberKey);
  });

  test('the remembered session is persistent, encrypted and removable',
      () async {
    const store = FlutterSecureStorage();
    await store.write(key: tokenKey, value: sampleToken);
    await store.write(key: rememberKey, value: 'true');

    // Readable through the plugin, exactly like the login screen does.
    expect(await store.read(key: tokenKey), sampleToken);
    expect(await store.read(key: rememberKey), 'true');

    // 1. It lives in PERSISTENT storage: localStorage, never sessionStorage.
    final localEntry = _keys(web.window.localStorage)
        .where((key) => key.endsWith(tokenKey))
        .toList();
    expect(localEntry, hasLength(1),
        reason: 'the session must be in localStorage (persistent)');
    expect(
      _keys(web.window.sessionStorage)
          .where((key) => key.endsWith(tokenKey) || key.endsWith(rememberKey)),
      isEmpty,
      reason: 'nothing session-only may hold the session',
    );

    // 2. What is on disk is ciphertext, not the token.
    final raw = web.window.localStorage.getItem(localEntry.single)!;
    expect(raw, isNotEmpty);
    expect(raw.contains(sampleToken), isFalse,
        reason: 'the session token must never be stored in plaintext');

    // A second, independent instance - the plugin after a page reload - imports
    // its key material from localStorage again and decrypts the same entry.
    const afterReload = FlutterSecureStorage();
    expect(await afterReload.read(key: tokenKey), sampleToken);
    expect(await afterReload.read(key: rememberKey), 'true');

    // Logout removes it from persistent storage.
    await store.delete(key: tokenKey);
    await store.delete(key: rememberKey);
    expect(await afterReload.read(key: tokenKey), isNull);
    expect(web.window.localStorage.getItem(localEntry.single), isNull);
  });
}
