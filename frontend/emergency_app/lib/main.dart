import 'package:flutter/material.dart';

import 'screens/login_screen.dart';
import 'theme/app_theme.dart';

void main() => runApp(const DispatchConsoleApp());

class DispatchConsoleApp extends StatelessWidget {
  const DispatchConsoleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ERAS - Dispatch Console',
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: 'IBM Plex Sans',
        scaffoldBackgroundColor: AppColors.bg,
        colorScheme: ColorScheme.fromSeed(seedColor: AppColors.teal),
      ),
      home: const LoginScreen(),
    );
  }
}
