import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

/// Single place where ERAS initializes Firebase.
///
/// Firebase is already used by [PushNotificationService]; Google sign-in needs
/// the very same app instance, so initialization lives here once and both
/// services ask for it.
///
/// Configuration comes from the build, never from committed secrets:
///
///   * Android/iOS: the existing `google-services.json` /
///     `GoogleService-Info.plist` are picked up automatically by
///     `Firebase.initializeApp()`.
///   * Web: the Firebase **web** config is public by design but is still kept
///     out of the repository; pass it with `--dart-define`:
///
///       flutter build web --release \
///         --dart-define=ERAS_API_BASE_URL=https://<render-service>.onrender.com/api \
///         --dart-define=ERAS_FIREBASE_API_KEY=... \
///         --dart-define=ERAS_FIREBASE_APP_ID=... \
///         --dart-define=ERAS_FIREBASE_MESSAGING_SENDER_ID=... \
///         --dart-define=ERAS_FIREBASE_PROJECT_ID=... \
///         --dart-define=ERAS_FIREBASE_AUTH_DOMAIN=<project>.firebaseapp.com
///
/// No key is ever hardcoded and no key is ever logged.
class ErasFirebaseConfig {
  ErasFirebaseConfig._();

  static const String apiKey = String.fromEnvironment('ERAS_FIREBASE_API_KEY');
  static const String appId = String.fromEnvironment('ERAS_FIREBASE_APP_ID');
  static const String messagingSenderId =
      String.fromEnvironment('ERAS_FIREBASE_MESSAGING_SENDER_ID');
  static const String projectId =
      String.fromEnvironment('ERAS_FIREBASE_PROJECT_ID');
  static const String authDomain =
      String.fromEnvironment('ERAS_FIREBASE_AUTH_DOMAIN');
  static const String storageBucket =
      String.fromEnvironment('ERAS_FIREBASE_STORAGE_BUCKET');
  static const String measurementId =
      String.fromEnvironment('ERAS_FIREBASE_MEASUREMENT_ID');

  /// The Google OAuth *web* client id. Firebase uses it as the ID-token
  /// audience (`serverClientId`) on Android and as the GIS `clientId` on web.
  static const String googleWebClientId =
      String.fromEnvironment('ERAS_GOOGLE_WEB_CLIENT_ID');

  /// True when a complete explicit web/native configuration was supplied.
  static bool get hasExplicitOptions =>
      apiKey.isNotEmpty &&
      appId.isNotEmpty &&
      messagingSenderId.isNotEmpty &&
      projectId.isNotEmpty;

  /// True when this build can talk to Firebase at all.
  ///
  /// Web builds need the explicit options; Android/iOS can rely on their
  /// platform configuration file, which `Firebase.initializeApp()` reads.
  static bool get isConfigured {
    if (hasExplicitOptions) return true;
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;
  }

  static FirebaseOptions? get options {
    if (!hasExplicitOptions) return null;
    return FirebaseOptions(
      apiKey: apiKey,
      appId: appId,
      messagingSenderId: messagingSenderId,
      projectId: projectId,
      authDomain:
          authDomain.isEmpty ? '$projectId.firebaseapp.com' : authDomain,
      storageBucket:
          storageBucket.isEmpty ? '$projectId.appspot.com' : storageBucket,
      measurementId: measurementId.isEmpty ? null : measurementId,
    );
  }

  /// The shared Future also closes the small race where Google sign-in and
  /// push registration could both observe no Firebase app before either
  /// finishes `Firebase.initializeApp()`.
  static Future<bool>? _initialization;

  /// Initializes (or reuses) the default Firebase app once per app lifecycle.
  ///
  /// Returns false instead of throwing: an unconfigured build must degrade to
  /// "Google sign-in is unavailable" while email/password login, Socket.IO and
  /// every emergency workflow keep working unchanged.
  static Future<bool> ensureInitialized() =>
      _initialization ??= _initializeOnce();

  static Future<bool> _initializeOnce() async {
    try {
      if (Firebase.apps.isNotEmpty) return true;
      final explicit = options;
      if (explicit != null) {
        await Firebase.initializeApp(options: explicit);
      } else if (!kIsWeb) {
        await Firebase.initializeApp();
      } else {
        return false;
      }
      return true;
    } on FirebaseException catch (error) {
      debugPrint('Firebase initialization failed: ${error.code}');
      return false;
    } catch (error) {
      // Avoid stringifying plugin errors, which can include serialized config.
      debugPrint(
        'Firebase initialization failed: unexpected=${error.runtimeType}',
      );
      return false;
    }
  }
}
