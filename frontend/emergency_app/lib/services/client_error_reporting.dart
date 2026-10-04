import 'package:flutter/foundation.dart';

import 'google_auth_service.dart';

/// Installs ERAS's last-resort client error handlers.
///
/// In a release web build every Dart exception has to be a message the user can
/// act on. Without this guard an error that escapes a plugin callback (a failed
/// Google Identity Services script, a browser-blocked popup, an unexpected
/// Firebase failure) reaches the browser as a bare `Uncaught Error` against a
/// minified `main.dart.js`, which tells the user nothing and hides the cause.
///
/// The handlers log one bounded, secret-free line and keep the app running.
void installErasClientErrorReporting() {
  FlutterError.onError = (FlutterErrorDetails details) {
    // Keeps the framework's own console output (and the debug error overlay)
    // while adding a sanitized ERAS diagnostic line.
    FlutterError.presentError(details);
    logErasClientDiagnostic('flutter-error', details.exception);
  };

  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    logErasClientDiagnostic('unhandled-async-error', error);
    // Reported as handled: the ERAS UI stays usable instead of surfacing a
    // minified "Uncaught Error".
    return true;
  };
}

/// Writes one safe diagnostic line for [error].
///
/// Only the exception type and a sanitized message are logged: tokens,
/// passwords, OTPs, keys and OAuth payloads are removed before anything is
/// printed. Stack traces are printed in debug builds only.
void logErasClientDiagnostic(
  String event,
  Object? error, {
  StackTrace? stack,
}) {
  final rawMessage = error is String ? error : error?.toString() ?? '<none>';
  final safeMessage = sanitizeGoogleAuthDiagnosticMessage(rawMessage);
  debugPrint(
    '[eras-client] $event type=${error.runtimeType} message=$safeMessage',
  );
  if (kDebugMode && stack != null) {
    debugPrint(stack.toString());
  }
}
