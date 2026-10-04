import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'screens/login_screen.dart';
import 'services/client_error_reporting.dart';
import 'services/firebase_bootstrap.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // One safe diagnostic path for every unhandled error, so a release web build
  // never shows a bare "Uncaught Error" from a minified main.dart.js.
  installErasClientErrorReporting();

  await ThemeController.load();

  // Warm Firebase up before the first Google click. On Flutter Web the popup
  // must open while the click's user activation is still valid; a slow first
  // initialization could otherwise make the browser block it (which the Google
  // flow then recovers from with a redirect).
  unawaited(ErasFirebaseConfig.ensureInitialized());

  runApp(const DispatchConsoleApp());
}

class DispatchConsoleApp extends StatelessWidget {
  const DispatchConsoleApp({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<ThemeMode>(
        valueListenable: ThemeController.mode,
        builder: (context, mode, _) {
          final isDark = mode == ThemeMode.dark ||
              (mode == ThemeMode.system &&
                  MediaQuery.platformBrightnessOf(context) == Brightness.dark);
          final palette = isDark ? ErasPalette.darkPalette : ErasPalette.light;
          final overlayStyle = SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness:
                isDark ? Brightness.light : Brightness.dark,
            statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
            systemNavigationBarColor: palette.sidebar,
            systemNavigationBarDividerColor: palette.border,
            systemNavigationBarIconBrightness:
                isDark ? Brightness.light : Brightness.dark,
            systemNavigationBarContrastEnforced: true,
          );

          return AnnotatedRegion<SystemUiOverlayStyle>(
            value: overlayStyle,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              title: 'ERAS — Emergency Resource Allocation System',
              theme: erasTheme(Brightness.light),
              darkTheme: erasTheme(Brightness.dark),
              themeMode: mode,
              themeAnimationDuration: const Duration(milliseconds: 350),
              home: const LoginScreen(),
            ),
          );
        },
      );
}
