/// Focused tests for the auth page's micro-animations.
///
/// These complement (never replace) `auth_visual_layout_test.dart` (static
/// geometry) and `login_role_routing_test.dart` /
/// `registration_role_test.dart` (auth behaviour). Each test below exercises
/// one specific animation contract called out in the design spec:
///   - Login/Register tab switching defers navigation until its short
///     transition has read as intentional, but flips its visual selection
///     immediately.
///   - Desktop mouse hover lifts a hoverable auth card.
///   - The theme toggle cross-fades its icons and slides its thumb based on
///     the active brightness.
///   - `AuthStagger` honours `MediaQuery.disableAnimations` by skipping the
///     slide/scale entrance entirely, even mid-timeline.
///   - The sign-in button swaps its label for a fixed-size loading
///     indicator without changing the button's footprint.
///   - A wrapped input field grows a focus glow the moment it gains focus.
library;

import 'package:dispatch_console_flutter/theme/app_theme.dart';
import 'package:dispatch_console_flutter/widgets/auth_motion.dart';
import 'package:dispatch_console_flutter/widgets/auth_shell.dart';
import 'package:dispatch_console_flutter/widgets/auth_visuals.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Color? _tabTextColor(WidgetTester tester, String label) =>
    tester
        .widget<AnimatedDefaultTextStyle>(
          find.ancestor(
            of: find.text(label),
            matching: find.byType(AnimatedDefaultTextStyle),
          ),
        )
        .style
        .color;

void main() {
  testWidgets(
    'AuthTabs flips its visual selection immediately but defers navigation',
    (tester) async {
      var registerTapped = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AuthTabs(
              registerSelected: false,
              onLoginTap: () {},
              onRegisterTap: () => registerTapped = true,
            ),
          ),
        ),
      );
      await tester.pump();

      final beforeColor = _tabTextColor(tester, 'Register');
      await tester.tap(find.text('Register'));
      // A single, zero-time frame: the transition has started but the
      // navigation delay has not elapsed yet.
      await tester.pump();

      expect(_tabTextColor(tester, 'Register'), isNot(equals(beforeColor)));
      expect(
        registerTapped,
        isFalse,
        reason: 'navigation should wait for the short tab transition',
      );

      await tester.pump(const Duration(milliseconds: 170));
      expect(registerTapped, isTrue);
    },
  );

  testWidgets('AuthPanel lifts on desktop mouse hover when hoverable',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: AuthPanel(
              hoverable: true,
              child: const SizedBox(width: 200, height: 120),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    double liftOf() => tester
        .widget<AnimatedContainer>(find.byType(AnimatedContainer))
        .transform!
        .getTranslation()
        .y;

    expect(liftOf(), 0);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(gesture.removePointer);
    await gesture.addPointer(location: Offset.zero);
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.byType(AuthPanel)));
    await tester.pump();

    expect(liftOf(), lessThan(0));
  });

  testWidgets(
    'ThemeSwitch cross-fades its icons and slides the thumb with brightness',
    (tester) async {
      Alignment thumbAlignment() =>
          tester.widget<AnimatedAlign>(find.byType(AnimatedAlign)).alignment
              as Alignment;
      double iconOpacity(IconData icon) => tester
          .widget<AnimatedOpacity>(
            find.ancestor(
              of: find.byIcon(icon),
              matching: find.byType(AnimatedOpacity),
            ),
          )
          .opacity;

      await tester.pumpWidget(
        MaterialApp(
          theme: erasTheme(Brightness.light),
          home: const Scaffold(body: Center(child: ThemeSwitch())),
        ),
      );
      await tester.pump();

      expect(thumbAlignment(), Alignment.centerLeft);
      expect(iconOpacity(Icons.light_mode_rounded), 1.0);
      expect(iconOpacity(Icons.dark_mode_rounded), closeTo(.35, .001));

      await tester.pumpWidget(
        MaterialApp(
          theme: erasTheme(Brightness.dark),
          home: const Scaffold(body: Center(child: ThemeSwitch())),
        ),
      );
      await tester.pump();

      expect(thumbAlignment(), Alignment.centerRight);
      expect(iconOpacity(Icons.light_mode_rounded), closeTo(.35, .001));
      expect(iconOpacity(Icons.dark_mode_rounded), 1.0);
    },
  );

  testWidgets(
    'AuthStagger skips its slide/scale entrance under reduced motion',
    (tester) async {
      final controller = AnimationController(
        vsync: const TestVSync(),
        duration: const Duration(seconds: 1),
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: AuthEntranceScope(
              animation: controller,
              child: const Scaffold(
                body: AuthStagger(
                  beginScale: .9,
                  offset: 40,
                  child: SizedBox(
                    key: ValueKey('reduced-motion-probe'),
                    width: 10,
                    height: 10,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // Jump to the middle of the entrance timeline: a non-reduced-motion
      // render would still be mid-slide/scale here.
      controller.value = .3;
      await tester.pump();

      expect(find.byType(Transform), findsNothing);
      expect(
        tester.getSize(find.byKey(const ValueKey('reduced-motion-probe'))),
        const Size(10, 10),
      );
    },
  );

  testWidgets(
    'Sign-in button keeps its footprint and shows a fixed indicator '
    'while loading',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: AuthPrimaryButton(
                label: 'Sign in',
                onPressed: () {},
                arrow: true,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final idleSize = tester.getSize(find.byType(AuthPrimaryButton));
      expect(find.text('Sign in'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: AuthPrimaryButton(
                label: 'Sign in',
                onPressed: null,
                loading: true,
                arrow: true,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final loadingSize = tester.getSize(find.byType(AuthPrimaryButton));

      expect(loadingSize, idleSize);
      expect(find.text('Sign in'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    },
  );

  testWidgets('AuthAnimatedField grows a focus glow once its field focuses',
      (tester) async {
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AuthAnimatedField(
            focusNode: focusNode,
            child: TextField(focusNode: focusNode),
          ),
        ),
      ),
    );
    await tester.pump();

    List<BoxShadow> glow() =>
        (tester.widget<AnimatedContainer>(find.byType(AnimatedContainer)).decoration
                as BoxDecoration)
            .boxShadow ??
        const [];

    expect(glow(), isEmpty);

    focusNode.requestFocus();
    await tester.pump();

    expect(glow(), isNotEmpty);
  });
}
