import 'package:flutter/material.dart';
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
