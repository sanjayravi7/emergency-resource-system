/// Regression coverage for responsive auth positioning, keyboard insets,
/// focus/controller identity, and the one-shot auth entrance animation.
library;

import 'package:dispatch_console_flutter/screens/email_verification_screen.dart';
import 'package:dispatch_console_flutter/screens/login_screen.dart';
import 'package:dispatch_console_flutter/screens/register_screen.dart';
import 'package:dispatch_console_flutter/services/api_service.dart';
import 'package:dispatch_console_flutter/services/google_auth_service.dart';
import 'package:dispatch_console_flutter/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void _setMobileViewport(
  WidgetTester tester, {
  Size size = const Size(360, 800),
}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.view.viewPadding = FakeViewPadding(top: 24, bottom: 24);
  tester.view.viewInsets = FakeViewPadding();
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(() {
    tester.view.viewPadding = FakeViewPadding();
    tester.view.viewInsets = FakeViewPadding();
  });
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

Future<void> _pumpScreen(
  WidgetTester tester,
  Widget screen, {
  bool reducedMotion = false,
}) async {
  await tester.pumpWidget(_app(screen, reducedMotion: reducedMotion));
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

Future<void> _setKeyboardInset(WidgetTester tester, double bottom) async {
  tester.view.viewInsets = FakeViewPadding(bottom: bottom);
  await tester.pump();
  await tester.pumpAndSettle();
}

void _resetSession() {
  ApiService.token = null;
  ApiService.currentRole = null;
  ApiService.currentUserId = null;
  ApiService.currentUserName = null;
  ApiService.currentUserEmail = null;
  ApiService.emailVerified = null;
}

Object _authCardEntranceState(WidgetTester tester) =>
    tester.state(find.byKey(const ValueKey('auth-card-entrance')));

double _authCardEntranceOpacity(WidgetTester tester) => tester
    .widget<Opacity>(
      find
          .descendant(
            of: find.byKey(const ValueKey('auth-card-entrance')),
            matching: find.byType(Opacity),
          )
          .first,
    )
    .opacity;

void main() {
  setUp(_resetSession);
  tearDown(() {
    GoogleAuthService.debugTokenProvider = null;
    _resetSession();
  });

  testWidgets('narrow scroll storage is scoped to its auth card',
      (tester) async {
    _setMobileViewport(tester);
    await _pumpScreen(tester, const LoginScreen());
    final loginScrollKey = tester
        .widget<SingleChildScrollView>(find.byType(SingleChildScrollView).first)
        .key;
    expect(
      loginScrollKey,
      const PageStorageKey<Key>(ValueKey<String>('auth-login-card')),
    );

    await _pumpScreen(tester, const RegisterScreen());
    final registerScrollKey = tester
        .widget<SingleChildScrollView>(find.byType(SingleChildScrollView).first)
        .key;
    expect(
      registerScrollKey,
      const PageStorageKey<Key>(ValueKey<String>('auth-register-card')),
    );
    expect(loginScrollKey, isNot(registerScrollKey));
    expect(tester.takeException(), isNull);
  });

  testWidgets('small Android viewport keeps the login card in the safe area',
      (tester) async {
    _setMobileViewport(tester, size: const Size(320, 568));
    await _pumpScreen(tester, const LoginScreen());

    final card = tester.getRect(find.byKey(const ValueKey('auth-login-card')));
    expect(card.top, greaterThanOrEqualTo(24));
    expect(card.top, lessThan(130));
    expect(card.left, greaterThanOrEqualTo(16));
    expect(card.right, lessThanOrEqualTo(304));
    expect(find.text('Right Resource.'), findsNothing);

    // The below-card content and primary/Google actions remain reachable by
    // scrolling, with the bottom navigation safe area left clear.
    final google = find.text('Continue with Google');
    await tester.ensureVisible(google);
    await tester.pumpAndSettle();
    final button = tester.getRect(google);
    expect(button.top, greaterThanOrEqualTo(24));
    expect(button.bottom, lessThanOrEqualTo(544));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'login focus, text, tab and entrance survive keyboard inset changes',
      (tester) async {
    _setMobileViewport(tester);
    var googleTokenRequests = 0;
    GoogleAuthService.debugTokenProvider = () async {
      googleTokenRequests++;
      return 'unused-test-token';
    };

    await _pumpScreen(tester, const LoginScreen());
    final pageState = tester.state(find.byType(LoginScreen));
    final entranceState = _authCardEntranceState(tester);
    final emailFinder = find.byKey(const ValueKey('login-email'));
    final passwordFinder = find.byKey(const ValueKey('login-password'));
    final emailBefore = tester.widget<TextField>(emailFinder);
    final passwordBefore = tester.widget<TextField>(passwordFinder);
    final emailController = emailBefore.controller!;
    final passwordController = passwordBefore.controller!;
    final emailFocusNode = emailBefore.focusNode!;
    final passwordFocusNode = passwordBefore.focusNode!;
    final brandTop = tester
        .getRect(find.byKey(const ValueKey('eras-brand-shield')))
        .top;

    await tester.tap(emailFinder);
    await tester.pumpAndSettle();
    expect(emailFocusNode.hasFocus, isTrue);
    await tester.enterText(emailFinder, 'asha@example.com');
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pump();
    expect(passwordFocusNode.hasFocus, isTrue);
    await tester.enterText(passwordFinder, 'private-pass');
    await tester.pump();

    await _setKeyboardInset(tester, 320);

    expect(
      identical(tester.state(find.byType(LoginScreen)), pageState),
      isTrue,
    );
    expect(
      identical(_authCardEntranceState(tester), entranceState),
      isTrue,
    );
    expect(identical(tester.widget<TextField>(emailFinder).controller,
        emailController), isTrue);
    expect(identical(tester.widget<TextField>(emailFinder).focusNode,
        emailFocusNode), isTrue);
    expect(identical(tester.widget<TextField>(passwordFinder).controller,
        passwordController), isTrue);
    expect(identical(tester.widget<TextField>(passwordFinder).focusNode,
        passwordFocusNode), isTrue);
    expect(emailController.text, 'asha@example.com');
    expect(passwordController.text, 'private-pass');
    expect(passwordFocusNode.hasFocus, isTrue);
    expect(_authCardEntranceOpacity(tester), 1);
    expect(
      tester
          .widget<AnimatedAlign>(
            find.byKey(const ValueKey('auth-tabs-highlight')),
          )
          .alignment,
      Alignment.centerLeft,
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('eras-brand-shield'))).top,
      closeTo(brandTop, 1),
    );
    expect(googleTokenRequests, 0);
    expect(ApiService.token, isNull);
    expect(tester.takeException(), isNull);

    await _setKeyboardInset(tester, 0);
    expect(emailController.text, 'asha@example.com');
    expect(passwordController.text, 'private-pass');
    expect(passwordFocusNode.hasFocus, isTrue);
    expect(
      tester.getRect(find.byKey(const ValueKey('eras-brand-shield'))).top,
      closeTo(brandTop, 1),
    );
    expect(_authCardEntranceOpacity(tester), 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keyboard dismissal restores the pre-keyboard scroll offset',
      (tester) async {
    _setMobileViewport(tester, size: const Size(320, 568));
    await _pumpScreen(tester, const LoginScreen());

    final scrollFinder = find.byType(SingleChildScrollView).first;
    final controller =
        tester.widget<SingleChildScrollView>(scrollFinder).controller!;
    final emailFinder = find.byKey(const ValueKey('login-email'));
    await tester.ensureVisible(emailFinder);
    await tester.pumpAndSettle();
    expect(controller.position.maxScrollExtent, greaterThan(100));

    controller.jumpTo(80);
    await tester.pump();
    final offsetBeforeKeyboard = controller.offset;
    await tester.tap(emailFinder);
    await tester.pump();
    await tester.enterText(emailFinder, 'asha@example.com');

    await _setKeyboardInset(tester, 300);
    // Model the automatic show-on-screen adjustment Flutter makes for a
    // focused field as the keyboard reduces the available viewport.
    controller.jumpTo(offsetBeforeKeyboard + 40);
    await tester.pump();
    expect(controller.offset, greaterThan(offsetBeforeKeyboard));
    await _setKeyboardInset(tester, 0);

    expect(controller.offset, closeTo(offsetBeforeKeyboard, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('register fields keep focus order and values with the keyboard',
      (tester) async {
    _setMobileViewport(tester, size: const Size(360, 760));
    await _pumpScreen(tester, const RegisterScreen());

    final pageState = tester.state(find.byType(RegisterScreen));
    final nameFinder = find.byKey(const ValueKey('register-name'));
    final emailFinder = find.byKey(const ValueKey('register-email'));
    final phoneFinder = find.byKey(const ValueKey('register-phone'));
    final passwordFinder = find.byKey(const ValueKey('register-password'));
    final confirmFinder = find.byKey(const ValueKey('register-confirm'));

    final nameBefore = tester.widget<TextFormField>(nameFinder);
    final emailBefore = tester.widget<TextFormField>(emailFinder);
    final phoneBefore = tester.widget<TextFormField>(phoneFinder);
    final passwordBefore = tester.widget<TextFormField>(passwordFinder);
    final confirmBefore = tester.widget<TextFormField>(confirmFinder);
    final nodes = <FocusNode>[
      nameBefore.focusNode!,
      emailBefore.focusNode!,
      phoneBefore.focusNode!,
      passwordBefore.focusNode!,
      confirmBefore.focusNode!,
    ];
    final controllers = <TextEditingController>[
      nameBefore.controller!,
      emailBefore.controller!,
      phoneBefore.controller!,
      passwordBefore.controller!,
      confirmBefore.controller!,
    ];

    await tester.ensureVisible(nameFinder);
    await tester.enterText(nameFinder, 'Asha');
    expect(nodes[0].hasFocus, isTrue);
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pump();
    expect(nodes[1].hasFocus, isTrue);
    await tester.enterText(emailFinder, 'asha@example.com');
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pump();
    expect(nodes[2].hasFocus, isTrue);
    await tester.enterText(phoneFinder, '5551234567');
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pump();
    expect(nodes[3].hasFocus, isTrue);
    await tester.enterText(passwordFinder, 'private-pass');
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pump();
    expect(nodes[4].hasFocus, isTrue);
    await tester.enterText(confirmFinder, 'private-pass');
    await tester.pump();

    await _setKeyboardInset(tester, 300);

    expect(identical(tester.state(find.byType(RegisterScreen)), pageState),
        isTrue);
    expect(
      tester
          .widget<AnimatedAlign>(
            find.byKey(const ValueKey('auth-tabs-highlight')),
          )
          .alignment,
      Alignment.centerRight,
    );
    for (var i = 0; i < nodes.length; i++) {
      final widget = tester.widget<TextFormField>(<Finder>[
        nameFinder,
        emailFinder,
        phoneFinder,
        passwordFinder,
        confirmFinder,
      ][i]);
      expect(identical(widget.focusNode, nodes[i]), isTrue);
      expect(identical(widget.controller, controllers[i]), isTrue);
    }
    expect(nodes[4].hasFocus, isTrue);
    expect(
      <String>[
        for (final controller in controllers) controller.text,
      ],
      <String>[
        'Asha',
        'asha@example.com',
        '5551234567',
        'private-pass',
        'private-pass',
      ],
    );
    expect(find.byType(RegisterScreen), findsOneWidget);
    expect(tester.takeException(), isNull);

    await _setKeyboardInset(tester, 0);
    expect(nodes[4].hasFocus, isTrue);
    expect(controllers[4].text, 'private-pass');
    expect(tester.takeException(), isNull);
  });

  testWidgets('verification code and page state survive keyboard changes',
      (tester) async {
    _setMobileViewport(tester);
    await _pumpScreen(
      tester,
      const EmailVerificationScreen(email: 'asha@example.com'),
    );

    final pageState = tester.state(find.byType(EmailVerificationScreen));
    final entranceState = _authCardEntranceState(tester);
    final codeFinder = find.byKey(const ValueKey('verification-code'));
    final codeBefore = tester.widget<TextFormField>(codeFinder);
    final controller = codeBefore.controller!;
    final focusNode = codeBefore.focusNode!;

    await tester.tap(codeFinder);
    await tester.pumpAndSettle();
    await tester.enterText(codeFinder, '482915');
    await _setKeyboardInset(tester, 320);

    expect(
      identical(tester.state(find.byType(EmailVerificationScreen)), pageState),
      isTrue,
    );
    expect(identical(_authCardEntranceState(tester), entranceState), isTrue);
    expect(identical(tester.widget<TextFormField>(codeFinder).controller,
        controller), isTrue);
    expect(identical(tester.widget<TextFormField>(codeFinder).focusNode,
        focusNode), isTrue);
    expect(controller.text, '482915');
    expect(focusNode.hasFocus, isTrue);
    expect(find.byKey(const ValueKey('auth-why-eras')), findsOneWidget);
    expect(_authCardEntranceOpacity(tester), 1);
    expect(tester.takeException(), isNull);

    await _setKeyboardInset(tester, 0);
    expect(controller.text, '482915');
    expect(focusNode.hasFocus, isTrue);
    expect(_authCardEntranceOpacity(tester), 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('login error region expands on a short phone without overflow',
      (tester) async {
    _setMobileViewport(tester, size: const Size(320, 568));
    await _pumpScreen(tester, const LoginScreen());

    final submit = find.text('Sign in');
    await tester.ensureVisible(submit);
    await tester.pumpAndSettle();
    await tester.tap(submit);
    await tester.pumpAndSettle();

    expect(find.text('Please enter email and password'), findsOneWidget);
    expect(find.byKey(const ValueKey('login-error-region')), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Even with the expanded banner, the Google action can be scrolled into
    // the safe viewport instead of overflowing behind the system navigation.
    final google = find.text('Continue with Google');
    await tester.ensureVisible(google);
    await tester.pumpAndSettle();
    expect(tester.getRect(google).bottom, lessThanOrEqualTo(544));
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion remains settled while the keyboard opens',
      (tester) async {
    _setMobileViewport(tester);
    await _pumpScreen(tester, const LoginScreen(), reducedMotion: true);

    final entranceState = _authCardEntranceState(tester);
    expect(_authCardEntranceOpacity(tester), 1);
    await _setKeyboardInset(tester, 310);

    expect(identical(_authCardEntranceState(tester), entranceState), isTrue);
    expect(_authCardEntranceOpacity(tester), 1);
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.takeException(), isNull);
  });
}
