import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:google_sign_in/google_sign_in.dart';

import '../firebase_options.dart';

class GoogleSignInCancelled implements Exception {
  const GoogleSignInCancelled();
}

/// Obtains a Firebase-signed ID token from Google's provider. ERAS still sends
/// that proof to its existing backend, which verifies it and issues the normal
/// ERAS JWT used by REST and Socket.IO.
class GoogleAuthService {
  GoogleAuthService._();

  static Future<String?> signInAndGetFirebaseIdToken() async {
    if (Firebase.apps.isEmpty) {
      throw Exception('Google sign-in is not configured for this build.');
    }

    UserCredential result;
    if (kIsWeb) {
      final provider = GoogleAuthProvider();
      result = await FirebaseAuth.instance.signInWithPopup(provider);
    } else {
      if (ErasFirebaseOptions.googleWebClientId.isEmpty) {
        throw Exception(
          'Google Sign-In Web client ID is missing from this Android build.',
        );
      }

      final googleSignIn = GoogleSignIn(
        scopes: const ['email'],
        serverClientId: ErasFirebaseOptions.googleWebClientId,
      );
      final googleUser = await googleSignIn.signIn();
      if (googleUser == null) throw const GoogleSignInCancelled();

      final googleAuthentication = await googleUser.authentication;
      final googleCredential = GoogleAuthProvider.credential(
        accessToken: googleAuthentication.accessToken,
        idToken: googleAuthentication.idToken,
      );
      result = await FirebaseAuth.instance
          .signInWithCredential(googleCredential);
    }

    final user = result.user;
    if (user == null) {
      throw Exception('Google did not return an ERAS sign-in account.');
    }
    final firebaseIdToken = await user.getIdToken(true);
    if (firebaseIdToken == null || firebaseIdToken.isEmpty) {
      throw Exception('Firebase did not return a sign-in token. Try again.');
    }
    return firebaseIdToken;
  }

  static Future<void> clearProviderSession() async {
    if (Firebase.apps.isNotEmpty) {
      try {
        await FirebaseAuth.instance.signOut();
      } catch (_) {}
    }
    if (!kIsWeb) {
      try {
        await GoogleSignIn().signOut();
      } catch (_) {}
    }
  }
}
