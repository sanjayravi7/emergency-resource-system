/// Dev-only preview renderer for the authentication screens.
///
/// Renders the login/register experience at reference and responsive sizes
/// with REAL fonts (Roboto mapped to Arial + MaterialIcons) and writes PNG
/// goldens so the rendered output can be compared against the reference
/// design pixel by pixel.
///
/// This file is a no-op during normal `flutter test` runs (CI included):
/// it only executes when ERAS_AUTH_PREVIEW is set:
///
///   ERAS_AUTH_PREVIEW=1 flutter test test/tools/auth_preview_test.dart \
///       --update-goldens
///
/// The generated PNGs land in test/tools/goldens/ and are not committed.
library;

import 'dart:io';

import 'package:dispatch_console_flutter/screens/login_screen.dart';
import 'package:dispatch_console_flutter/screens/register_screen.dart';
import 'package:dispatch_console_flutter/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _loadRealFonts() async {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) return;
  const fontDir = 'bin/cache/artifacts/material_fonts';
  Future<void> load(String family, List<String> files) async {
    final loader = FontLoader(family);
    for (final file in files) {
      final f = File('$root/$fontDir/$file');
      if (f.existsSync()) {
        loader.addFont(Future.value(f.readAsBytesSync().buffer.asByteData()));
      }
    }
    await loader.load();
  }

  await load('Arial', [
    'Roboto-Regular.ttf',
    'Roboto-Medium.ttf',
    'Roboto-Bold.ttf',
  ]);
  await load('MaterialIcons', ['MaterialIcons-Regular.otf']);
}

Future<void> _preview(
  WidgetTester tester,
  Size size,
  String name,
  WidgetBuilder builder,
) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: erasTheme(Brightness.light),
      home: Builder(builder: builder),
    ),
  );
  await tester.pumpAndSettle();
  await expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('goldens/$name.png'),
  );
}

void main() {
  // Normal test runs (CI `flutter test`) skip this file entirely.
  if (!Platform.environment.containsKey('ERAS_AUTH_PREVIEW')) {
    return;
  }

  setUpAll(_loadRealFonts);

  testWidgets('preview: login at the 1648x926 reference size', (tester) async {
    await _preview(
      tester,
      const Size(1648, 926),
      'login_light_1648x926',
      (_) => const LoginScreen(),
    );
  });

  testWidgets('preview: login at a common laptop size', (tester) async {
    await _preview(
      tester,
      const Size(1366, 850),
      'login_light_1366x850',
      (_) => const LoginScreen(),
    );
  });

  testWidgets('preview: login dark theme', (tester) async {
    tester.view.physicalSize = const Size(1648, 926);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(theme: erasTheme(Brightness.dark), home: const LoginScreen()),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/login_dark_1648x926.png'),
    );
  });

  testWidgets('preview: login on a phone', (tester) async {
    await _preview(
      tester,
      const Size(390, 844),
      'login_light_390x844',
      (_) => const LoginScreen(),
    );
  });

  testWidgets('preview: login on a tablet', (tester) async {
    await _preview(
      tester,
      const Size(834, 1112),
      'login_light_834x1112',
      (_) => const LoginScreen(),
    );
  });

  testWidgets('preview: register at the reference size', (tester) async {
    await _preview(
      tester,
      const Size(1648, 1100),
      'register_light_1648x1100',
      (_) => const RegisterScreen(),
    );
  });
}
