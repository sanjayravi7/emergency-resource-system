import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

/// Firebase's Web app config is public client configuration and is supplied at
/// build time so this repository never selects or embeds a developer's
/// Firebase project. Android initializes from android/app/google-services.json.
class ErasFirebaseOptions {
  ErasFirebaseOptions._();

  static const String apiKey =
      String.fromEnvironment('ERAS_FIREBASE_API_KEY');
  static const String appId =
      String.fromEnvironment('ERAS_FIREBASE_APP_ID');
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

  /// OAuth 2.0 Web client ID. Android Google Sign-In uses this as the server
  /// client ID to mint a Google ID token for Firebase credential exchange.
  static const String googleWebClientId =
      String.fromEnvironment('ERAS_GOOGLE_WEB_CLIENT_ID');

  static bool get isWebConfigured =>
      apiKey.isNotEmpty &&
      appId.isNotEmpty &&
      messagingSenderId.isNotEmpty &&
      projectId.isNotEmpty &&
      authDomain.isNotEmpty;

  static FirebaseOptions get web => FirebaseOptions(
        apiKey: apiKey,
        appId: appId,
        messagingSenderId: messagingSenderId,
        projectId: projectId,
        authDomain: authDomain,
        storageBucket: storageBucket.isEmpty ? null : storageBucket,
        measurementId: measurementId.isEmpty ? null : measurementId,
      );

  static Future<void> initialize() async {
    if (kIsWeb) {
      if (!isWebConfigured) return;
      await Firebase.initializeApp(options: web);
      return;
    }

    // The Google Services Gradle plugin generates Android Firebase options
    // from the locally supplied google-services.json.
    await Firebase.initializeApp();
  }
}
