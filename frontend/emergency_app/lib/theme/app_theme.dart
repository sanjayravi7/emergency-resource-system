import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppColors {
  static const bg = Color(0xFFF5F8FC);
  static const surface = Color(0xFFFFFFFF);
  static const surface2 = Color(0xFFF1F5FA);
  static const border = Color(0xFFDCE5F0);
  static const text = Color(0xFF10213B);
  static const textDim = Color(0xFF5A6B82);
  static const textFaint = Color(0xFF8997A9);
  static const teal = Color(0xFF08A88A);
  static const tealDim = Color(0xFFE4F7F3);
  static const amber = Color(0xFFB4740A);
  static const amberDim = Color(0xFFFDF0DA);
  static const red = Color(0xFFD6304A);
  static const redDim = Color(0xFFFCE7EA);
  static const blue = Color(0xFF2478E5);
  static const blueDim = Color(0xFFE7F0FC);
}

class ThemeController {
  ThemeController._();
  static final mode = ValueNotifier<ThemeMode>(ThemeMode.light);
  static const _key = 'eras_dark_mode';

  static Future<void> load() async {
    final preferences = await SharedPreferences.getInstance();
    mode.value = (preferences.getBool(_key) ?? false)
        ? ThemeMode.dark
        : ThemeMode.light;
  }

  static Future<void> toggle() async {
    final dark = mode.value != ThemeMode.dark;
    mode.value = dark ? ThemeMode.dark : ThemeMode.light;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_key, dark);
  }
}

ThemeData erasTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: dark ? const Color(0xFF19D3C5) : AppColors.teal,
    brightness: brightness,
    surface: dark ? const Color(0xFF101F35) : Colors.white,
  );
  final border = dark ? const Color(0xFF29425F) : AppColors.border;
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    fontFamily: 'Arial',
    scaffoldBackgroundColor:
        dark ? const Color(0xFF071321) : const Color(0xFFF7F9FC),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? const Color(0xB30B1A2E) : const Color(0xFFF9FBFD),
      labelStyle: TextStyle(color: dark ? const Color(0xFFA9B8CC) : AppColors.textDim),
      hintStyle: TextStyle(color: dark ? const Color(0xFF71839B) : AppColors.textFaint),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 17),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: border)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: border)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: dark ? const Color(0xFF20D4C3) : AppColors.blue, width: 1.7)),
      errorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.red)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
        backgroundColor: AppColors.blue,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
      ),
    ),
    cardTheme: CardThemeData(
      color: dark ? const Color(0xE6101F35) : Colors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: border)),
    ),
  );
}

class PillColors {
  const PillColors(this.background, this.text);
  final Color background, text;
}

InputDecoration fieldDecoration({String? hintText}) => InputDecoration(isDense: true, filled: true, hintText: hintText);
TextStyle monoStyle({required double size, required Color color, FontWeight? weight}) => TextStyle(fontFamily: 'IBM Plex Mono', fontSize: size, color: color, fontWeight: weight);
TextStyle tableHeadStyle() => const TextStyle(fontSize: 10.5, color: AppColors.textFaint, letterSpacing: .6, fontWeight: FontWeight.w500);
String titleCase(String value) => value.isEmpty ? value : value.substring(0, 1).toUpperCase() + value.substring(1).toLowerCase();
T? firstWhereOrNull<T>(Iterable<T> items, bool Function(T) test) { for (final item in items) { if (test(item)) return item; } return null; }
String formatDateTime(DateTime? value) { if (value == null) return '-'; final local = value.toLocal(); String two(int v) => v.toString().padLeft(2, '0'); return '${two(local.day)}/${two(local.month)} ${two(local.hour)}:${two(local.minute)}'; }
String formatRelative(DateTime? value) { if (value == null) return '-'; final diff = DateTime.now().difference(value.toLocal()); if (diff.inMinutes < 1) return 'just now'; if (diff.inMinutes < 60) return '${diff.inMinutes} min ago'; if (diff.inHours < 24) return '${diff.inHours} h ago'; return '${diff.inDays} d ago'; }
