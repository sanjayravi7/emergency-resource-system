import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

@immutable
class ErasPalette extends ThemeExtension<ErasPalette> {
  const ErasPalette({
    required this.dark,
    required this.bg,
    required this.sidebar,
    required this.header,
    required this.surface,
    required this.surface2,
    required this.inputFill,
    required this.border,
    required this.cardBorder,
    required this.text,
    required this.textDim,
    required this.textFaint,
    required this.teal,
    required this.tealDim,
    required this.amber,
    required this.amberDim,
    required this.red,
    required this.redDim,
    required this.blue,
    required this.blueDim,
    required this.bloodBg,
    required this.bloodText,
    required this.cardShadow,
  });

  final bool dark;
  final Color bg;
  final Color sidebar;
  final Color header;
  final Color surface;
  final Color surface2;
  final Color inputFill;
  final Color border;
  final Color cardBorder;
  final Color text;
  final Color textDim;
  final Color textFaint;
  final Color teal;
  final Color tealDim;
  final Color amber;
  final Color amberDim;
  final Color red;
  final Color redDim;
  final Color blue;
  final Color blueDim;
  final Color bloodBg;
  final Color bloodText;
  final Color cardShadow;

  static const light = ErasPalette(
    dark: false,
    bg: AppColors.bg,
    sidebar: AppColors.surface,
    header: AppColors.surface,
    surface: AppColors.surface,
    surface2: AppColors.surface2,
    inputFill: Color(0xFFF9FBFD),
    border: AppColors.border,
    cardBorder: AppColors.border,
    text: AppColors.text,
    textDim: AppColors.textDim,
    textFaint: AppColors.textFaint,
    teal: AppColors.teal,
    tealDim: AppColors.tealDim,
    amber: AppColors.amber,
    amberDim: AppColors.amberDim,
    red: AppColors.red,
    redDim: AppColors.redDim,
    blue: AppColors.blue,
    blueDim: AppColors.blueDim,
    bloodBg: Color(0xFFFCE4F3),
    bloodText: Color(0xFFC23E96),
    cardShadow: Color(0x0A10213B),
  );

  static const darkPalette = ErasPalette(
    dark: true,
    bg: Color(0xFF071321),
    sidebar: Color(0xFF0B192C),
    header: Color(0xFF0D1D31),
    surface: Color(0xFF102035),
    surface2: Color(0xFF152A44),
    inputFill: Color(0xFF0B1A2E),
    border: Color(0xFF29425F),
    cardBorder: Color(0xFF2A4C68),
    text: Color(0xFFF2F6FC),
    textDim: Color(0xFFA9B8CC),
    textFaint: Color(0xFF7E93AB),
    teal: Color(0xFF22C9B6),
    tealDim: Color(0xFF11323B),
    amber: Color(0xFFF0B45C),
    amberDim: Color(0xFF332714),
    red: Color(0xFFFF6B7E),
    redDim: Color(0xFF3A1824),
    blue: Color(0xFF4E9AF5),
    blueDim: Color(0xFF14344F),
    bloodBg: Color(0xFF381932),
    bloodText: Color(0xFFF065C0),
    cardShadow: Color(0x47000000),
  );

  static ErasPalette forBrightness(Brightness brightness) =>
      brightness == Brightness.dark ? darkPalette : light;

  static ErasPalette of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<ErasPalette>() ?? forBrightness(theme.brightness);
  }

  @override
  ErasPalette copyWith({
    bool? dark,
    Color? bg,
    Color? sidebar,
    Color? header,
    Color? surface,
    Color? surface2,
    Color? inputFill,
    Color? border,
    Color? cardBorder,
    Color? text,
    Color? textDim,
    Color? textFaint,
    Color? teal,
    Color? tealDim,
    Color? amber,
    Color? amberDim,
    Color? red,
    Color? redDim,
    Color? blue,
    Color? blueDim,
    Color? bloodBg,
    Color? bloodText,
    Color? cardShadow,
  }) {
    return ErasPalette(
      dark: dark ?? this.dark,
      bg: bg ?? this.bg,
      sidebar: sidebar ?? this.sidebar,
      header: header ?? this.header,
      surface: surface ?? this.surface,
      surface2: surface2 ?? this.surface2,
      inputFill: inputFill ?? this.inputFill,
      border: border ?? this.border,
      cardBorder: cardBorder ?? this.cardBorder,
      text: text ?? this.text,
      textDim: textDim ?? this.textDim,
      textFaint: textFaint ?? this.textFaint,
      teal: teal ?? this.teal,
      tealDim: tealDim ?? this.tealDim,
      amber: amber ?? this.amber,
      amberDim: amberDim ?? this.amberDim,
      red: red ?? this.red,
      redDim: redDim ?? this.redDim,
      blue: blue ?? this.blue,
      blueDim: blueDim ?? this.blueDim,
      bloodBg: bloodBg ?? this.bloodBg,
      bloodText: bloodText ?? this.bloodText,
      cardShadow: cardShadow ?? this.cardShadow,
    );
  }

  @override
  ErasPalette lerp(ThemeExtension<ErasPalette>? other, double t) {
    if (other is! ErasPalette) return this;
    return ErasPalette(
      dark: t < 0.5 ? dark : other.dark,
      bg: Color.lerp(bg, other.bg, t)!,
      sidebar: Color.lerp(sidebar, other.sidebar, t)!,
      header: Color.lerp(header, other.header, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surface2: Color.lerp(surface2, other.surface2, t)!,
      inputFill: Color.lerp(inputFill, other.inputFill, t)!,
      border: Color.lerp(border, other.border, t)!,
      cardBorder: Color.lerp(cardBorder, other.cardBorder, t)!,
      text: Color.lerp(text, other.text, t)!,
      textDim: Color.lerp(textDim, other.textDim, t)!,
      textFaint: Color.lerp(textFaint, other.textFaint, t)!,
      teal: Color.lerp(teal, other.teal, t)!,
      tealDim: Color.lerp(tealDim, other.tealDim, t)!,
      amber: Color.lerp(amber, other.amber, t)!,
      amberDim: Color.lerp(amberDim, other.amberDim, t)!,
      red: Color.lerp(red, other.red, t)!,
      redDim: Color.lerp(redDim, other.redDim, t)!,
      blue: Color.lerp(blue, other.blue, t)!,
      blueDim: Color.lerp(blueDim, other.blueDim, t)!,
      bloodBg: Color.lerp(bloodBg, other.bloodBg, t)!,
      bloodText: Color.lerp(bloodText, other.bloodText, t)!,
      cardShadow: Color.lerp(cardShadow, other.cardShadow, t)!,
    );
  }
}

class ThemeController {
  ThemeController._();
  static final mode = ValueNotifier<ThemeMode>(ThemeMode.light);
  static const _key = 'eras_dark_mode';

  static Future<void> load() async {
    final preferences = await SharedPreferences.getInstance();
    mode.value =
        (preferences.getBool(_key) ?? false) ? ThemeMode.dark : ThemeMode.light;
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
  final palette = ErasPalette.forBrightness(brightness);
  final scheme = ColorScheme.fromSeed(
    seedColor: dark ? const Color(0xFF19D3C5) : AppColors.teal,
    brightness: brightness,
    primary: palette.teal,
    onPrimary: Colors.white,
    secondary: palette.blue,
    onSecondary: Colors.white,
    error: palette.red,
    onError: Colors.white,
    surface: dark ? const Color(0xFF101F35) : Colors.white,
    onSurface: palette.text,
  );
  final border = palette.border;
  final baseTheme = dark ? ThemeData.dark() : ThemeData.light();
  final baseText = baseTheme.textTheme.apply(
    fontFamily: 'Arial',
    bodyColor: palette.text,
    displayColor: palette.text,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    fontFamily: 'Arial',
    textTheme: baseText,
    iconTheme: IconThemeData(color: palette.textDim),
    scaffoldBackgroundColor:
        dark ? const Color(0xFF071321) : const Color(0xFFF7F9FC),
    canvasColor: palette.surface2,
    dividerColor: border,
    dividerTheme: DividerThemeData(
      color: border,
      thickness: 1,
      space: 1,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: palette.header,
      foregroundColor: palette.text,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      systemOverlayStyle: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
        statusBarBrightness: dark ? Brightness.dark : Brightness.light,
        systemNavigationBarColor: palette.sidebar,
        systemNavigationBarDividerColor: palette.border,
        systemNavigationBarIconBrightness:
            dark ? Brightness.light : Brightness.dark,
        systemNavigationBarContrastEnforced: true,
      ),
    ),
    extensions: <ThemeExtension<dynamic>>[palette],
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? const Color(0xB30B1A2E) : const Color(0xFFF9FBFD),
      labelStyle:
          TextStyle(color: dark ? const Color(0xFFA9B8CC) : AppColors.textDim),
      hintStyle: TextStyle(color: palette.textFaint),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 17),
      border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: border)),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: border)),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
              color: dark ? const Color(0xFF20D4C3) : AppColors.blue,
              width: 1.7)),
      errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: palette.red)),
      focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: palette.red, width: 1.7)),
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
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: border)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: palette.surface,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: TextStyle(
        fontFamily: 'Arial',
        fontSize: 16,
        fontWeight: FontWeight.w700,
        color: palette.text,
      ),
      contentTextStyle: TextStyle(
        fontFamily: 'Arial',
        fontSize: 13,
        color: palette.textDim,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: palette.cardBorder),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: palette.surface2,
      surfaceTintColor: Colors.transparent,
      textStyle: TextStyle(color: palette.text, fontSize: 13),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: border),
      ),
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      textStyle: TextStyle(color: palette.text, fontSize: 13),
      menuStyle: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(palette.surface2),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        side: WidgetStatePropertyAll(BorderSide(color: border)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: palette.surface2,
      contentTextStyle: TextStyle(color: palette.text, fontSize: 13),
      behavior: SnackBarBehavior.floating,
    ),
    checkboxTheme: CheckboxThemeData(
      side: BorderSide(color: border, width: 1.4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: palette.sidebar,
      surfaceTintColor: Colors.transparent,
      indicatorColor: palette.tealDim,
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          color: selected ? palette.teal : palette.textDim,
          size: 20,
        );
      }),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return TextStyle(
          fontSize: 11.5,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          color: selected ? palette.teal : palette.textDim,
        );
      }),
    ),
  );
}

class PillColors {
  const PillColors(this.background, this.text);
  final Color background, text;
}

InputDecoration fieldDecoration({String? hintText, BuildContext? context}) {
  if (context == null) {
    return InputDecoration(isDense: true, filled: true, hintText: hintText);
  }
  final p = ErasPalette.of(context);
  return InputDecoration(
    isDense: true,
    filled: true,
    fillColor: p.inputFill,
    hintText: hintText,
    hintStyle: TextStyle(color: p.textFaint, fontSize: 13),
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: p.border),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: p.border),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: p.teal, width: 1.5),
    ),
    errorBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: p.red),
    ),
    focusedErrorBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: p.red, width: 1.5),
    ),
  );
}

TextStyle monoStyle(
        {required double size, required Color color, FontWeight? weight}) =>
    TextStyle(
        fontFamily: 'IBM Plex Mono',
        fontSize: size,
        color: color,
        fontWeight: weight);

TextStyle tableHeadStyle([BuildContext? context]) {
  final color =
      context != null ? ErasPalette.of(context).textFaint : AppColors.textFaint;
  return TextStyle(
    fontSize: 10.5,
    color: color,
    letterSpacing: .6,
    fontWeight: FontWeight.w500,
  );
}

String titleCase(String value) => value.isEmpty
    ? value
    : value.substring(0, 1).toUpperCase() + value.substring(1).toLowerCase();
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
