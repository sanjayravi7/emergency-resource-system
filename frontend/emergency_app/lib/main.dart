import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart';

import 'firebase_options.dart';
import 'screens/login_screen.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await ErasFirebaseOptions.initialize();
  } catch (_) {
    // Firebase is needed only for Google sign-in and optional FCM. Keep the
    // existing email/password ERAS API usable when a local build has no
    // Firebase configuration; the auth controls show a clear setup message.
    debugPrint('Firebase is not configured for this build.');
  }
  await ThemeController.load();
  runApp(const DispatchConsoleApp());
}

class DispatchConsoleApp extends StatelessWidget {
  const DispatchConsoleApp({super.key});
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<ThemeMode>(
        valueListenable: ThemeController.mode,
        builder: (_, mode, __) => MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'ERAS - Emergency Resource Allocation System',
          theme: erasTheme(Brightness.light),
          darkTheme: erasTheme(Brightness.dark),
          themeMode: mode,
          themeAnimationDuration: const Duration(milliseconds: 350),
          home: const LoginScreen(),
        ),
      );
}
