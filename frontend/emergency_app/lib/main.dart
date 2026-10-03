import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'screens/login_screen.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ThemeController.load();
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
          final palette =
              isDark ? ErasPalette.darkPalette : ErasPalette.light;
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
              title: 'ERAS - Emergency Resource Allocation System',
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
