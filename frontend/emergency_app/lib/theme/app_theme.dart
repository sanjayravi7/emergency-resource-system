import 'package:flutter/material.dart';

class AppColors {
  static const bg = Color(0xFFF5F6FA);
  static const surface = Color(0xFFFFFFFF);
  static const surface2 = Color(0xFFEEF1F8);
  static const border = Color(0xFFDCE1EE);
  static const text = Color(0xFF111A2E);
  static const textDim = Color(0xFF525C7A);
  static const textFaint = Color(0xFF8A93AE);
  static const teal = Color(0xFF0E9C8C);
  static const tealDim = Color(0xFFE1F7F2);
  static const amber = Color(0xFFB4740A);
  static const amberDim = Color(0xFFFDF0DA);
  static const red = Color(0xFFD6304A);
  static const redDim = Color(0xFFFCE7EA);
  static const blue = Color(0xFF3B63D6);
  static const blueDim = Color(0xFFE7EDFB);
}

class PillColors {
  const PillColors(this.background, this.text);
  final Color background, text;
}

InputDecoration fieldDecoration({String? hintText}) => InputDecoration(
      isDense: true,
      filled: true,
      hintText: hintText,
      fillColor: AppColors.surface2,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      enabledBorder: OutlineInputBorder(
          borderSide: const BorderSide(color: AppColors.border),
          borderRadius: BorderRadius.circular(5)),
      focusedBorder: OutlineInputBorder(
          borderSide: const BorderSide(color: AppColors.blue, width: 2),
          borderRadius: BorderRadius.circular(5)),
      border: OutlineInputBorder(
          borderSide: const BorderSide(color: AppColors.border),
          borderRadius: BorderRadius.circular(5)),
    );

TextStyle monoStyle(
        {required double size, required Color color, FontWeight? weight}) =>
    TextStyle(
        fontFamily: 'IBM Plex Mono',
        fontSize: size,
        color: color,
        fontWeight: weight);

TextStyle tableHeadStyle() => const TextStyle(
    fontSize: 10.5,
    color: AppColors.textFaint,
    letterSpacing: .6,
    fontWeight: FontWeight.w500);

String titleCase(String value) {
  if (value.isEmpty) return value;
  return value.substring(0, 1).toUpperCase() + value.substring(1).toLowerCase();
}

T? firstWhereOrNull<T>(Iterable<T> items, bool Function(T) test) {
  for (final item in items) {
    if (test(item)) return item;
  }
  return null;
}

String formatDateTime(DateTime? value) {
  if (value == null) return '-';

  final local = value.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');

  return '${two(local.day)}/${two(local.month)} ${two(local.hour)}:${two(local.minute)}';
}

String formatRelative(DateTime? value) {
  if (value == null) return '-';

  final diff = DateTime.now().difference(value.toLocal());

  if (diff.inMinutes < 1) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
  if (diff.inHours < 24) return '${diff.inHours} h ago';

  return '${diff.inDays} d ago';
}
