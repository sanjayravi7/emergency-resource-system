import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// ERAS test bootstrap.
///
/// The "Remember me" session lives in `flutter_secure_storage`, which delegates
/// to the platform keystore (Android Keystore / Keychain / the Web build's
/// encrypted store). The Flutter test VM has no platform implementation, so a
/// plugin call there never resolves at all - read, write and delete all stay
/// pending forever (measured under `testWidgets`' fake async). Authentication
/// awaits the persistence step, so a test that signs in would stall before it
/// ever reaches a console.
///
/// Installing the plugin's own in-memory test platform keeps every suite on the
/// real application code with a deterministic keystore. Only tests are
/// affected: a release build still writes the ERAS session to the platform's
/// secure storage.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  FlutterSecureStorage.setMockInitialValues(<String, String>{});
  await testMain();
}
