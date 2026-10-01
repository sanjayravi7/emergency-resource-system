/// Motion contract for the ERAS authentication experience.
///
/// The auth screens are visually frozen (see auth_visual_layout_test.dart);
/// these tests pin the MOTION layer on top of that frozen design:
///
///   - entrance reveals fade/settle without ever changing final geometry,
///   - reduced motion collapses everything to short fades and disables
///     ambient + parallax motion,
///   - ambient (infinitely repeating) animation runs only when explicitly
///     enabled, so every other widget test keeps a settling page,
///   - the Login/Register tabs glide their selection across screens,
///   - the sign-in button swaps content while loading without any change
///     to its dimensions,
///   - focusing an input raises its soft glow,
///   - the theme switch slides its thumb and cross-fades the sun/moon,
///   - pointer hover lifts the auth card and status cards (desktop only).
library;

import 'package:dispatch_console_flutter/screens/login_screen.dart';
import 'package:dispatch_console_flutter/screens/register_screen.dart';
import 'package:dispatch_console_flutter/theme/app_theme.dart';
import 'package:dispatch_console_flutter/widgets/auth_motion.dart';
import 'package:dispatch_console_flutter/widgets/auth_shell.dart';
import 'package:dispatch_console_flutter/widgets/auth_visuals.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Size _desktop = Size(1648, 926);

void _setSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _app(Widget home, {bool reducedMotion = false}) => MaterialApp(
      theme: erasTheme(Brightness.light),
      builder: reducedMotion
          ? (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(disableAnimations: true),
                child: child!,
              )
          : null,
      home: home,
    );

double _loginCardOpacity(WidgetTester tester) {
  final opacity = tester.widget<Opacity>(
    find
        .ancestor(
          of: find.byKey(const ValueKey('auth-login-card')),
          matching: find.byType(Opacity),
        )
        .first,
  );
  return opacity.opacity;
}

void main() {
  testWidgets('entrance reveal fades the auth card in and fully settles',
      (tester) async {
    _setSize(tester, _desktop);
    await tester.pumpWidget(_app(const LoginScreen()));

    // The card entrance is staggered, so the very first frame is
    // transparent...
    expect(_loginCardOpacity(tester), lessThan(.05));

    // ...and every entrance is finite: the page settles completely (no
    // ambient animation runs under flutter test) at full opacity and at
    // the reference geometry.
    await tester.pumpAndSettle();
    expect(_loginCardOpacity(tester), 1);
    expect(tester.binding.hasScheduledFrame, isFalse);
    final card = tester.getRect(find.byKey(const ValueKey('auth-login-card')));
    expect(card.width, closeTo(400, 4));
  });

  testWidgets(
      'reduced motion: short fade only, no stagger, no ambient animation',
      (tester) async {
    // Force ambient motion on; reduced motion must still win over it.
    AuthMotion.debugAmbientOverride = true;
    addTearDown(() => AuthMotion.debugAmbientOverride = null);

    _setSize(tester, _desktop);
    await tester.pumpWidget(_app(const LoginScreen(), reducedMotion: true));

    // A 160ms fade is the only entrance; 250ms later NOTHING is animating:
    // no staggered reveals, no floating network, no background drift and
    // no parallax.
    await tester.pump(const Duration(milliseconds: 250));
    expect(_loginCardOpacity(tester), 1);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('ambient network motion runs only when explicitly enabled',
      (tester) async {
    AuthMotion.debugAmbientOverride = true;
    addTearDown(() => AuthMotion.debugAmbientOverride = null);

    _setSize(tester, _desktop);
    await tester.pumpWidget(_app(const LoginScreen()));

    // Long after every entrance has finished, the ambient loop still
    // schedules frames (the floating emblem/nodes and line pulse).
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 3));
    expect(tester.binding.hasScheduledFrame, isTrue);

    // Dispose the repeating controllers before the test ends.
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('tab selection glides between the auth screens', (tester) async {
    _setSize(tester, _desktop);

    AnimatedAlign underline() => tester.widget<AnimatedAlign>(
          find.byKey(const ValueKey('auth-tabs-underline')),
        );
    AnimatedAlign highlight() => tester.widget<AnimatedAlign>(
          find.byKey(const ValueKey('auth-tabs-highlight')),
        );

    await tester.pumpWidget(_app(const RegisterScreen()));
    await tester.pumpAndSettle();
    expect(underline().alignment, Alignment.bottomRight);
    expect(highlight().alignment, Alignment.centerRight);

    // A freshly built login screen starts from the register selection and
    // glides the underline/highlight over to the Login tab.
    await tester.pumpWidget(_app(const LoginScreen()));
    expect(underline().alignment, Alignment.bottomRight);
    await tester.pump();
    expect(underline().alignment, Alignment.bottomLeft);
    expect(highlight().alignment, Alignment.centerLeft);
    await tester.pumpAndSettle();
  });

  testWidgets('sign-in button keeps its exact size while loading',
      (tester) async {
    var loading = false;
    late StateSetter setButtonState;
    await tester.pumpWidget(
      MaterialApp(
        theme: erasTheme(Brightness.light),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              child: StatefulBuilder(
                builder: (context, setState) {
                  setButtonState = setState;
                  return AuthPrimaryButton(
                    label: 'Sign in',
                    onPressed: loading ? null : () {},
                    loading: loading,
                    arrow: true,
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    final idleSize = tester.getSize(find.byType(AuthPrimaryButton));
    expect(find.text('Sign in'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    setButtonState(() => loading = true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // Mid cross-fade the spinner is in and the footprint is unchanged.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(tester.getSize(find.byType(AuthPrimaryButton)), idleSize);

    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Sign in'), findsNothing);
    expect(tester.getSize(find.byType(AuthPrimaryButton)), idleSize);

    // Dispose the indeterminate spinner before the test ends.
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('focusing the email field raises its soft glow', (tester) async {
    _setSize(tester, _desktop);
    await tester.pumpWidget(_app(const LoginScreen()));
    await tester.pumpAndSettle();

    double glowAlpha() {
      final container = tester.widget<AnimatedContainer>(
        find
            .descendant(
              of: find.byKey(const ValueKey('login-email-glow')),
              matching: find.byType(AnimatedContainer),
            )
            .first,
      );
      final decoration = container.decoration! as BoxDecoration;
      return decoration.boxShadow!.first.color.a;
    }

    expect(glowAlpha(), 0);

    await tester.tap(find.byKey(const ValueKey('login-email')));
    await tester.pumpAndSettle();
    expect(glowAlpha(), greaterThan(.1));
  });

  testWidgets('theme switch slides the thumb and cross-fades sun/moon',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    ThemeController.mode.value = ThemeMode.light;
    addTearDown(() => ThemeController.mode.value = ThemeMode.light);

    _setSize(tester, _desktop);
    await tester.pumpWidget(
      ValueListenableBuilder<ThemeMode>(
        valueListenable: ThemeController.mode,
        builder: (_, mode, __) => MaterialApp(
          theme: erasTheme(Brightness.light),
          darkTheme: erasTheme(Brightness.dark),
          themeMode: mode,
          home: const LoginScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    AnimatedAlign thumb() => tester.widget<AnimatedAlign>(
          find.byKey(const ValueKey('theme-switch-thumb')),
        );
    double sun() => tester
        .widget<AnimatedOpacity>(
          find.byKey(const ValueKey('theme-switch-sun')),
        )
        .opacity;
    double moon() => tester
        .widget<AnimatedOpacity>(
          find.byKey(const ValueKey('theme-switch-moon')),
        )
        .opacity;

    expect(thumb().alignment, Alignment.centerLeft);
    expect(sun(), 1);
    expect(moon(), lessThan(1));

    await tester.tap(find.byType(ThemeSwitch));
    await tester.pumpAndSettle();

    expect(thumb().alignment, Alignment.centerRight);
    expect(sun(), lessThan(1));
    expect(moon(), 1);
  });

  testWidgets('pointer hover lifts the auth card and the status cards',
      (tester) async {
    _setSize(tester, _desktop);
    await tester.pumpWidget(_app(const LoginScreen()));
    await tester.pumpAndSettle();

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await tester.pump();

    AnimatedContainer liftContainer() => tester.widget<AnimatedContainer>(
          find
              .descendant(
                of: find.byKey(const ValueKey('auth-login-card')),
                matching: find.byType(AnimatedContainer),
              )
              .first,
        );
    expect(liftContainer().transform!.getTranslation().y, 0);

    final cardCenter =
        tester.getCenter(find.byKey(const ValueKey('auth-login-card')));
    await gesture.moveTo(cardCenter);
    await tester.pumpAndSettle();
    expect(liftContainer().transform!.getTranslation().y, -2);

    // Status card: the nearest AnimatedContainer around the title carries
    // the hover shadow treatment.
    BoxDecoration statusDecoration() {
      final container = tester.widget<AnimatedContainer>(
        find
            .ancestor(
              of: find.text('Resource Availability'),
              matching: find.byType(AnimatedContainer),
            )
            .first,
      );
      return container.decoration! as BoxDecoration;
    }

    expect(statusDecoration().boxShadow!.first.blurRadius, 14);
    await gesture.moveTo(tester.getCenter(find.text('Resource Availability')));
    await tester.pumpAndSettle();
    expect(statusDecoration().boxShadow!.first.blurRadius, 18);

    // Park the pointer away so nothing stays hovered at teardown.
    await gesture.moveTo(Offset.zero);
    await tester.pumpAndSettle();
  });

  testWidgets('password visibility icon cross-fades on toggle', (tester) async {
    _setSize(tester, _desktop);
    await tester.pumpWidget(_app(const LoginScreen()));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.visibility_outlined), findsOneWidget);
    expect(find.byIcon(Icons.visibility_off_outlined), findsNothing);

    await tester.tap(find.byTooltip('Show or hide password'));
    await tester.pump(const Duration(milliseconds: 90));

    // Mid-swap both icons are present (cross-fade), then the old one
    // leaves.
    expect(find.byIcon(Icons.visibility_off_outlined), findsOneWidget);
    expect(find.byIcon(Icons.visibility_outlined), findsOneWidget);

    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.visibility_outlined), findsNothing);
    expect(find.byIcon(Icons.visibility_off_outlined), findsOneWidget);
  });
}
