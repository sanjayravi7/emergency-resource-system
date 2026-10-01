import 'dart:io' show Platform;

/// True when the current process is `flutter test` (the test runner sets
/// this environment variable on the Dart VM). Used ONLY to keep perpetual
/// ambient motion (the gentle shield float, connection-line pulse, idle
/// button sheen, background drift) from fighting `pumpAndSettle` in widget
/// tests that never touch reduced-motion settings. It has no effect on the
/// real reduced-motion accessibility path, which is handled separately via
/// `MediaQuery.of(context).disableAnimations`.
bool get isFlutterTestProcess {
  try {
    return Platform.environment.containsKey('FLUTTER_TEST');
  } catch (_) {
    return false;
  }
}
