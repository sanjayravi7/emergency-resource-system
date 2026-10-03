/// Keyboard-stability contract for the ERAS auth composition.
///
/// The bug these tests pin: on Android, opening the soft keyboard changes the
/// height the body is laid out into. The auth shell used to take its responsive
/// breakpoints from that reduced height, so simply tapping an input could
/// remove the hero, re-centre the card and look like a full page refresh.
///
/// The rule under test is the one the shell now implements:
///
///   * the STABLE viewport (`MediaQuery.size` minus the physical safe area,
///     `MediaQuery.viewPadding`) decides desktop/narrow, the hero, the
///     illustration, the scale and the card identity,
///   * the KEYBOARD (`MediaQuery.viewInsets.bottom`) only ever moves a single
///     scroll viewport so the focused field stays reachable.
///
/// Both platform behaviours are covered: the one that reports the keyboard
/// purely as a view inset, and the one (Android `adjustResize`) that also
/// shrinks the reported window.
library;

import 'dart:convert';

import 'package:dispatch_console_flutter/screens/email_verification_screen.dart';
import 'package:dispatch_console_flutter/screens/forgot_password_screen.dart';
import 'package:dispatch_console_flutter/screens/login_screen.dart';
import 'package:dispatch_console_flutter/screens/register_screen.dart';
import 'package:dispatch_console_flutter/services/api_service.dart';
import 'package:dispatch_console_flutter/services/google_auth_service.dart';
import 'package:dispatch_console_flutter/theme/app_theme.dart';
import 'package:dispatch_console_flutter/widgets/auth_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Phone: compact composition, no marketing hero.
const Size _phone = Size(360, 800);

/// Tablet: the hero AND the illustration are part of the composition, so a
/// keyboard-driven height change would be visible as a breakpoint flip.
const Size _tablet = Size(834, 1112);

/// Reference desktop canvas: the three-column composition.
const Size _desktop = Size(1648, 926);

/// The auth card keys, one per screen. They also drive the per-screen
/// [PageStorageKey] of the narrow scroll region.
const Key _loginCard = ValueKey<String>('auth-login-card');
const Key _registerCard = ValueKey<String>('auth-register-card');
const Key _resetCard = ValueKey<String>('auth-forgot-password-card');
const Key _verificationCard = ValueKey<String>('auth-verification-card');

const Key _scrollRegionKey = ValueKey<String>('auth-narrow-scroll-region');
const Key _cardEntranceKey = ValueKey<String>('auth-card-entrance');

void _useViewport(WidgetTester tester, Size size, {bool safeArea = true}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.view.viewPadding = safeArea
      ? FakeViewPadding(top: 24, bottom: 24)
      : FakeViewPadding();
  tester.view.viewInsets = FakeViewPadding();
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(() {
    tester.view.viewPadding = FakeViewPadding();
    tester.view.viewInsets = FakeViewPadding();
  });
}

Future<void> _pumpScreen(WidgetTester tester, Widget screen) async {
  await tester.pumpWidget(
    MaterialApp(theme: erasTheme(Brightness.light), home: screen),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

/// Reports a soft keyboard of [bottom] logical pixels the way the platform
/// channel does, and lets the shell's own inset animation run to the end.
Future<void> _setKeyboard(WidgetTester tester, double bottom) async {
  tester.view.viewInsets = FakeViewPadding(bottom: bottom);
  await tester.pump();
  await tester.pumpAndSettle();
}

Element _cardElement(WidgetTester tester, Key cardKey) =>
    tester.element(find.byKey(cardKey));

/// The stable metrics the composition is currently built from.
AuthLayoutMetrics _metricsOf(WidgetTester tester, Key cardKey) =>
    AuthLayoutMetrics.of(_cardElement(tester, cardKey));

double _entranceOpacity(WidgetTester tester, Key key) {
  final finder = find.descendant(
    of: find.byKey(key),
    matching: find.byType(Opacity),
  );
  return tester.widget<Opacity>(finder.first).opacity;
}

void _expectRectUnchanged(Rect actual, Rect before) {
  expect(actual.left, closeTo(before.left, .5));
  expect(actual.top, closeTo(before.top, .5));
  expect(actual.width, closeTo(before.width, .5));
  expect(actual.height, closeTo(before.height, .5));
}

void _resetSession() {
  ApiService.token = null;
  ApiService.currentRole = null;
  ApiService.currentUserId = null;
  ApiService.currentUserName = null;
  ApiService.currentUserEmail = null;
  ApiService.emailVerified = null;
}

MockClient _stubBackend(String message) => MockClient(
      (request) async => http.Response(
        jsonEncode(<String, Object?>{'success': true, 'message': message}),
        200,
      ),
    );

MockClient _googleUnavailableBackend() => MockClient(
      (request) async => http.Response(
        jsonEncode(<String, Object?>{
          'success': false,
          'code': 'GOOGLE_AUTH_NOT_CONFIGURED',
          'message': 'Google sign-in is not configured on this server',
        }),
        503,
      ),
    );

/// Runs a submit action without `pumpAndSettle`: the button shows an
/// indeterminate spinner while loading, which would never settle.
Future<void> _tapAndDrain(WidgetTester tester, Finder button) async {
  await tester.ensureVisible(button);
  await tester.pump();
  await tester.tap(button);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  setUp(_resetSession);
  tearDown(() {
    GoogleAuthService.debugTokenProvider = null;
    _resetSession();
  });

  // -------------------------------------------------------------------
  // A / B / C - same composition with the keyboard up or down.
  // -------------------------------------------------------------------
  testWidgets('A/B/C: keyboard insets never change the auth composition',
      (tester) async {
    _useViewport(tester, _tablet);
    await _pumpScreen(tester, const LoginScreen());

    final card = find.byKey(_loginCard);
    final hero = find.text('Right Resource.');
    final network = find.byKey(const ValueKey('auth-network'));
    final flow = find.byKey(const ValueKey('auth-flow'));

    // A. Initial login: hero, illustration, flow strip and card all present.
    final closed = _metricsOf(tester, _loginCard);
    expect(closed.desktop, isFalse);
    expect(closed.showHero, isTrue);
    expect(closed.showHeroVisuals, isTrue);
    expect(hero, findsOneWidget);
    expect(network, findsOneWidget);
    expect(flow, findsOneWidget);
    expect(card, findsOneWidget);

    final cardRect = tester.getRect(card);
    final heroRect = tester.getRect(hero);
    final region = tester.state(find.byKey(_scrollRegionKey));
    final entrance = tester.state(find.byKey(_cardEntranceKey));
    final route = ModalRoute.of(_cardElement(tester, _loginCard));
    final page = tester.state(find.byType(LoginScreen));

    // B. Same page with viewInsets.bottom == 0.
    await _setKeyboard(tester, 0);
    expect(_metricsOf(tester, _loginCard), closed);

    // C. Same page with viewInsets.bottom == 400.
    await _setKeyboard(tester, 400);
    final open = _metricsOf(tester, _loginCard);
    expect(open, closed);
    expect(open.viewport, closed.viewport);
    expect(open.desktop, isFalse);
    expect(open.scale, closed.scale);
    expect(open.showHero, isTrue);
    expect(open.showHeroVisuals, isTrue);

    // Structurally identical: the hero breakpoint did not flip, nothing was
    // removed, no route was replaced and no state was recreated.
    expect(hero, findsOneWidget);
    expect(network, findsOneWidget);
    expect(flow, findsOneWidget);
    expect(card, findsOneWidget);
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(ModalRoute.of(_cardElement(tester, _loginCard)), same(route));
    expect(tester.state(find.byType(LoginScreen)), same(page));
    expect(tester.state(find.byKey(_scrollRegionKey)), same(region));
    expect(tester.state(find.byKey(_cardEntranceKey)), same(entrance));

    // Only the scroll viewport moved, so nothing above it changed geometry.
    _expectRectUnchanged(tester.getRect(hero), heroRect);
    _expectRectUnchanged(tester.getRect(card), cardRect);
    expect(tester.takeException(), isNull);

    // Keyboard closes again: same composition, same geometry.
    await _setKeyboard(tester, 0);
    expect(_metricsOf(tester, _loginCard), closed);
    _expectRectUnchanged(tester.getRect(card), cardRect);
    _expectRectUnchanged(tester.getRect(hero), heroRect);
    expect(tester.takeException(), isNull);
  });

  testWidgets('C: a window resized for the IME cannot move a breakpoint',
      (tester) async {
    _useViewport(tester, _tablet);
    await _pumpScreen(tester, const LoginScreen());

    final closed = _metricsOf(tester, _loginCard);
    expect(closed.showHero, isTrue);
    expect(closed.showHeroVisuals, isTrue);

    // Android `adjustResize` can report a shorter window together with the
    // keyboard inset: 1112 - 400 = 712, and 712 - 48 = 664 < 700 would have
    // dropped the hero and the illustration.
    tester.view.physicalSize = Size(_tablet.width, _tablet.height - 400);
    tester.view.viewInsets = FakeViewPadding(bottom: 400);
    await tester.pump();
    await tester.pumpAndSettle();

    final open = _metricsOf(tester, _loginCard);
    expect(open, closed);
    expect(open.viewport.height, closed.viewport.height);
    expect(open.showHero, isTrue);
    expect(open.showHeroVisuals, isTrue);
    expect(find.text('Right Resource.'), findsOneWidget);
    expect(find.byKey(const ValueKey('auth-network')), findsOneWidget);
    expect(find.byKey(_loginCard), findsOneWidget);
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = _tablet;
    await _setKeyboard(tester, 0);
    expect(_metricsOf(tester, _loginCard), closed);
    expect(tester.takeException(), isNull);
  });

  // -------------------------------------------------------------------
  // D / E - focus changes plus keyboard metrics keep the form state.
  // -------------------------------------------------------------------
  testWidgets('D/E: login keeps email and password through focus + keyboard',
      (tester) async {
    _useViewport(tester, _phone);
    await _pumpScreen(tester, const LoginScreen());

    final email = find.byKey(const ValueKey('login-email'));
    final password = find.byKey(const ValueKey('login-password'));
    final emailField = tester.widget<TextField>(email);
    final passwordField = tester.widget<TextField>(password);
    final closed = _metricsOf(tester, _loginCard);
    final page = tester.state(find.byType(LoginScreen));

    // D. Focus email -> keyboard metrics change -> the email text remains.
    await tester.ensureVisible(email);
    await tester.pumpAndSettle();
    await tester.tap(email);
    await tester.pumpAndSettle();
    expect(emailField.focusNode!.hasFocus, isTrue);
    await tester.enterText(email, 'test@example.com');
    await _setKeyboard(tester, 400);

    expect(emailField.controller!.text, 'test@example.com');
    expect(emailField.focusNode!.hasFocus, isTrue);
    expect(
      tester.widget<TextField>(email).controller,
      same(emailField.controller),
    );
    expect(
      tester.widget<TextField>(email).focusNode,
      same(emailField.focusNode),
    );
    expect(_metricsOf(tester, _loginCard), closed);
    expect(tester.state(find.byType(LoginScreen)), same(page));
    await _setKeyboard(tester, 0);

    // E. Focus password -> keyboard metrics change -> both fields remain.
    await tester.ensureVisible(password);
    await tester.pumpAndSettle();
    await tester.tap(password);
    await tester.pumpAndSettle();
    expect(passwordField.focusNode!.hasFocus, isTrue);
    await tester.enterText(password, 'private-pass');
    await _setKeyboard(tester, 420);

    expect(emailField.controller!.text, 'test@example.com');
    expect(passwordField.controller!.text, 'private-pass');
    expect(passwordField.focusNode!.hasFocus, isTrue);
    expect(
      tester.widget<TextField>(password).controller,
      same(passwordField.controller),
    );
    expect(_metricsOf(tester, _loginCard), closed);
    expect(tester.state(find.byType(LoginScreen)), same(page));
    expect(tester.takeException(), isNull);

    await _setKeyboard(tester, 0);
    expect(emailField.controller!.text, 'test@example.com');
    expect(passwordField.controller!.text, 'private-pass');
    expect(_metricsOf(tester, _loginCard), closed);
    expect(tester.takeException(), isNull);
  });

  // -------------------------------------------------------------------
  // F - register.
  // -------------------------------------------------------------------
  testWidgets('F: register keeps its form and role while the keyboard opens',
      (tester) async {
    _useViewport(tester, _phone);
    await _pumpScreen(tester, const RegisterScreen());

    final name = find.byKey(const ValueKey('register-name'));
    final closed = _metricsOf(tester, _registerCard);
    final page = tester.state(find.byType(RegisterScreen));
    final nameField = tester.widget<TextFormField>(name);

    await tester.ensureVisible(name);
    await tester.pumpAndSettle();
    await tester.tap(name);
    await tester.pumpAndSettle();
    await tester.enterText(name, 'Asha');

    await _setKeyboard(tester, 400);
    expect(nameField.controller!.text, 'Asha');
    expect(
      tester.widget<TextFormField>(name).controller,
      same(nameField.controller),
    );
    expect(
      tester.widget<TextFormField>(name).focusNode,
      same(nameField.focusNode),
    );
    expect(_metricsOf(tester, _registerCard), closed);
    expect(tester.state(find.byType(RegisterScreen)), same(page));
    expect(find.byType(RegisterScreen), findsOneWidget);
    expect(
      tester
          .widget<AnimatedAlign>(
            find.byKey(const ValueKey('auth-tabs-highlight')),
          )
          .alignment,
      Alignment.centerRight,
    );
    expect(tester.takeException(), isNull);

    await _setKeyboard(tester, 0);
    expect(nameField.controller!.text, 'Asha');
    expect(_metricsOf(tester, _registerCard), closed);
    expect(tester.takeException(), isNull);
  });

  // -------------------------------------------------------------------
  // G - forgot password keeps the step it is on.
  // -------------------------------------------------------------------
  testWidgets('G: password reset keeps its step while the keyboard opens',
      (tester) async {
    _useViewport(tester, _phone);
    const resetMessage = 'A reset code is on the way.';

    await http.runWithClient(
      () async {
        await _pumpScreen(tester, const ForgotPasswordScreen());

        final email = find.byKey(const ValueKey('reset-email'));
        final closed = _metricsOf(tester, _resetCard);
        final page = tester.state(find.byType(ForgotPasswordScreen));
        final emailField = tester.widget<TextFormField>(email);

        await tester.ensureVisible(email);
        await tester.pumpAndSettle();
        await tester.tap(email);
        await tester.pumpAndSettle();
        await tester.enterText(email, 'asha@example.com');

        await _setKeyboard(tester, 380);
        expect(emailField.controller!.text, 'asha@example.com');
        expect(_metricsOf(tester, _resetCard), closed);
        expect(tester.state(find.byType(ForgotPasswordScreen)), same(page));
        await _setKeyboard(tester, 0);

        await _tapAndDrain(tester, find.text('Email me a code'));
        // The submit has finished, so the step transition can settle.
        await tester.pumpAndSettle();

        // Step 2 is on screen now; it must stay there across keyboard changes.
        final code = find.byKey(const ValueKey('reset-code'));
        expect(code, findsOneWidget);
        expect(email, findsNothing);
        expect(find.text(resetMessage), findsOneWidget);

        final codeField = tester.widget<TextFormField>(code);
        await tester.ensureVisible(code);
        await tester.pumpAndSettle();
        await tester.tap(code);
        await tester.pumpAndSettle();
        await tester.enterText(code, '482915');

        await _setKeyboard(tester, 380);
        expect(code, findsOneWidget);
        expect(email, findsNothing);
        expect(codeField.controller!.text, '482915');
        expect(_metricsOf(tester, _resetCard), closed);
        expect(tester.state(find.byType(ForgotPasswordScreen)), same(page));
        expect(tester.takeException(), isNull);

        await _setKeyboard(tester, 0);
        expect(code, findsOneWidget);
        expect(email, findsNothing);
        expect(codeField.controller!.text, '482915');
        expect(_metricsOf(tester, _resetCard), closed);
        expect(tester.takeException(), isNull);
      },
      () => _stubBackend(resetMessage),
    );
  });

  // -------------------------------------------------------------------
  // H - email verification keeps the code.
  // -------------------------------------------------------------------
  testWidgets('H: verification keeps its code while the keyboard opens',
      (tester) async {
    _useViewport(tester, _phone);
    await _pumpScreen(
      tester,
      const EmailVerificationScreen(email: 'asha@example.com'),
    );

    final code = find.byKey(const ValueKey('verification-code'));
    final closed = _metricsOf(tester, _verificationCard);
    final page = tester.state(find.byType(EmailVerificationScreen));
    final codeField = tester.widget<TextFormField>(code);

    await tester.ensureVisible(code);
    await tester.pumpAndSettle();
    await tester.tap(code);
    await tester.pumpAndSettle();
    expect(codeField.focusNode!.hasFocus, isTrue);
    await tester.enterText(code, '482915');

    await _setKeyboard(tester, 400);
    expect(codeField.controller!.text, '482915');
    expect(codeField.focusNode!.hasFocus, isTrue);
    expect(
      tester.widget<TextFormField>(code).controller,
      same(codeField.controller),
    );
    expect(_metricsOf(tester, _verificationCard), closed);
    expect(tester.state(find.byType(EmailVerificationScreen)), same(page));
    expect(find.byKey(const ValueKey('auth-why-eras')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await _setKeyboard(tester, 0);
    expect(codeField.controller!.text, '482915');
    expect(codeField.focusNode!.hasFocus, isTrue);
    expect(_metricsOf(tester, _verificationCard), closed);
    expect(tester.takeException(), isNull);
  });

  // -------------------------------------------------------------------
  // I - entrance animations must not restart.
  // -------------------------------------------------------------------
  testWidgets('I: entrance animations do not restart when viewInsets change',
      (tester) async {
    _useViewport(tester, _tablet);
    await _pumpScreen(tester, const LoginScreen());

    final keys = <Key>[
      const ValueKey('auth-narrow-brand-entrance'),
      const ValueKey('auth-hero-resource-entrance'),
      const ValueKey('auth-hero-place-entrance'),
      const ValueKey('auth-hero-time-entrance'),
      const ValueKey('auth-hero-subtext-entrance'),
      const ValueKey('auth-hero-network-entrance'),
      const ValueKey('auth-hero-flow-entrance'),
      const ValueKey('auth-card-entrance'),
      const ValueKey('auth-narrow-why-entrance'),
      const ValueKey('auth-narrow-trust-entrance'),
    ];
    for (final key in keys) {
      expect(find.byKey(key), findsOneWidget, reason: '$key');
      expect(_entranceOpacity(tester, key), 1, reason: '$key');
    }
    final states = <Object>[
      for (final key in keys) tester.state(find.byKey(key)),
    ];

    // One frame into the keyboard animation: a replayed entrance would have
    // dropped straight back to opacity 0.
    tester.view.viewInsets = FakeViewPadding(bottom: 400);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    for (var i = 0; i < keys.length; i++) {
      expect(
        tester.state(find.byKey(keys[i])),
        same(states[i]),
        reason: '${keys[i]}',
      );
      expect(_entranceOpacity(tester, keys[i]), 1, reason: '${keys[i]}');
    }

    await _setKeyboard(tester, 0);
    for (var i = 0; i < keys.length; i++) {
      expect(
        tester.state(find.byKey(keys[i])),
        same(states[i]),
        reason: '${keys[i]}',
      );
      expect(_entranceOpacity(tester, keys[i]), 1, reason: '${keys[i]}');
    }
    expect(tester.takeException(), isNull);
  });

  // -------------------------------------------------------------------
  // Requirement 6 - the card must not re-centre on the desktop composition.
  // -------------------------------------------------------------------
  testWidgets('desktop card and columns keep their geometry with the keyboard',
      (tester) async {
    // No safe-area padding here: this is the reference 1648x926 canvas the
    // desktop geometry is authored (and pinned) against.
    _useViewport(tester, _desktop, safeArea: false);
    await _pumpScreen(tester, const LoginScreen());

    final card = find.byKey(_loginCard);
    final network = find.byKey(const ValueKey('auth-network'));
    final trust = find.byKey(const ValueKey('auth-trust-card'));
    final status = find.byKey(const ValueKey('auth-status-cards'));
    final closed = _metricsOf(tester, _loginCard);
    expect(closed.desktop, isTrue);

    final cardRect = tester.getRect(card);
    final networkRect = tester.getRect(network);
    final trustRect = tester.getRect(trust);
    final statusRect = tester.getRect(status);

    await _setKeyboard(tester, 300);
    expect(_metricsOf(tester, _loginCard), closed);
    // The centring anchor is the keyboard-free height, so the card neither
    // re-centres nor jumps to the top of its column.
    _expectRectUnchanged(tester.getRect(card), cardRect);
    // The story and side columns are never inset, so nothing else moves.
    _expectRectUnchanged(tester.getRect(network), networkRect);
    _expectRectUnchanged(tester.getRect(trust), trustRect);
    _expectRectUnchanged(tester.getRect(status), statusRect);
    expect(tester.takeException(), isNull);

    await _setKeyboard(tester, 0);
    _expectRectUnchanged(tester.getRect(card), cardRect);
    expect(tester.takeException(), isNull);
  });

  // -------------------------------------------------------------------
  // Requirements 4 / 6 - no reflow and no scroll reset without focus.
  // -------------------------------------------------------------------
  testWidgets('a phone page neither reflows nor resets its scroll offset',
      (tester) async {
    _useViewport(tester, _phone);
    await _pumpScreen(tester, const LoginScreen());

    final card = find.byKey(_loginCard);
    final brand = find.byKey(const ValueKey('eras-brand-shield'));
    final scrollFinder = find.byType(SingleChildScrollView).first;
    final controller =
        tester.widget<SingleChildScrollView>(scrollFinder).controller!;
    final cardRect = tester.getRect(card);
    final brandRect = tester.getRect(brand);
    expect(controller.offset, 0);

    await _setKeyboard(tester, 320);
    expect(controller.offset, 0);
    _expectRectUnchanged(tester.getRect(brand), brandRect);
    _expectRectUnchanged(tester.getRect(card), cardRect);
    // Scrolling is still available: the viewport shrank, not the content.
    expect(controller.position.maxScrollExtent, greaterThan(0));

    await _setKeyboard(tester, 0);
    expect(controller.offset, 0);
    _expectRectUnchanged(tester.getRect(card), cardRect);
    _expectRectUnchanged(tester.getRect(brand), brandRect);
    expect(tester.takeException(), isNull);
  });

  // -------------------------------------------------------------------
  // Requirement 12 - inline messages expand without restarting the layout.
  // -------------------------------------------------------------------
  testWidgets('the Google error expands without restarting the composition',
      (tester) async {
    _useViewport(tester, _phone);
    GoogleAuthService.debugTokenProvider = () async => 'firebase-id-token';

    await http.runWithClient(
      () async {
        await _pumpScreen(tester, const LoginScreen());

        final closed = _metricsOf(tester, _loginCard);
        final region = tester.state(find.byKey(_scrollRegionKey));
        final entrance = tester.state(find.byKey(_cardEntranceKey));
        final page = tester.state(find.byType(LoginScreen));
        final route = ModalRoute.of(_cardElement(tester, _loginCard));

        await _tapAndDrain(tester, find.text('Continue with Google'));

        expect(
          find.textContaining(
            'Google sign-in is not configured on this server',
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey<String>('login-error-region')),
          findsOneWidget,
        );
        expect(find.byType(LoginScreen), findsOneWidget);
        expect(ApiService.token, isNull);
        expect(tester.state(find.byType(LoginScreen)), same(page));
        expect(tester.state(find.byKey(_scrollRegionKey)), same(region));
        expect(tester.state(find.byKey(_cardEntranceKey)), same(entrance));
        expect(ModalRoute.of(_cardElement(tester, _loginCard)), same(route));
        expect(_metricsOf(tester, _loginCard), closed);
        expect(_entranceOpacity(tester, _cardEntranceKey), 1);
        expect(tester.takeException(), isNull);

        // And the expanded message stays put across a keyboard change.
        await _setKeyboard(tester, 300);
        expect(
          find.textContaining(
            'Google sign-in is not configured on this server',
          ),
          findsOneWidget,
        );
        expect(_metricsOf(tester, _loginCard), closed);
        expect(_entranceOpacity(tester, _cardEntranceKey), 1);
        expect(tester.state(find.byKey(_cardEntranceKey)), same(entrance));
        expect(tester.takeException(), isNull);

        // Dispose the page while the stubbed HTTP client is still in scope.
        await _setKeyboard(tester, 0);
        await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      },
      _googleUnavailableBackend,
    );
  });

  // -------------------------------------------------------------------
  // Requirement 10 - the page storage keys stay distinct.
  // -------------------------------------------------------------------
  testWidgets('J: every auth screen keeps its own page storage key',
      (tester) async {
    _useViewport(tester, _phone);

    Future<Key?> storageKey(Widget screen) async {
      await _pumpScreen(tester, screen);
      final finder = find.byType(SingleChildScrollView).first;
      return tester.widget<SingleChildScrollView>(finder).key;
    }

    final login = await storageKey(const LoginScreen());
    final register = await storageKey(const RegisterScreen());
    final reset = await storageKey(const ForgotPasswordScreen());
    final verification = await storageKey(
      const EmailVerificationScreen(email: 'asha@example.com'),
    );

    expect(login, const PageStorageKey<Key>(_loginCard));
    expect(register, const PageStorageKey<Key>(_registerCard));
    expect(reset, const PageStorageKey<Key>(_resetCard));
    expect(verification, const PageStorageKey<Key>(_verificationCard));
    expect(<Key?>{login, register, reset, verification}, hasLength(4));
    expect(tester.takeException(), isNull);
  });

  // -------------------------------------------------------------------
  // Requirement 17 - the exact user-visible failure, repeated.
  // -------------------------------------------------------------------
  testWidgets('17: repeated email/password focus never looks like a refresh',
      (tester) async {
    _useViewport(tester, _phone);
    await _pumpScreen(tester, const LoginScreen());

    final email = find.byKey(const ValueKey('login-email'));
    final password = find.byKey(const ValueKey('login-password'));
    final closed = _metricsOf(tester, _loginCard);
    final region = tester.state(find.byKey(_scrollRegionKey));
    final entrance = tester.state(find.byKey(_cardEntranceKey));
    final page = tester.state(find.byType(LoginScreen));
    final route = ModalRoute.of(_cardElement(tester, _loginCard));

    await tester.ensureVisible(email);
    await tester.pumpAndSettle();
    await tester.enterText(email, 'test@example.com');
    await tester.ensureVisible(password);
    await tester.pumpAndSettle();
    await tester.enterText(password, 'private-pass');

    for (var cycle = 0; cycle < 3; cycle++) {
      // Tap email -> the keyboard opens.
      await tester.ensureVisible(email);
      await tester.pumpAndSettle();
      await tester.tap(email);
      await tester.pump();
      await _setKeyboard(tester, 300 + cycle * 25.0);

      expect(tester.state(find.byType(LoginScreen)), same(page));
      expect(tester.state(find.byKey(_scrollRegionKey)), same(region));
      expect(tester.state(find.byKey(_cardEntranceKey)), same(entrance));
      expect(ModalRoute.of(_cardElement(tester, _loginCard)), same(route));
      expect(_metricsOf(tester, _loginCard), closed);
      expect(_entranceOpacity(tester, _cardEntranceKey), 1);
      expect(find.byType(LoginScreen), findsOneWidget);
      expect(
        tester.widget<TextField>(email).controller!.text,
        'test@example.com',
      );
      expect(
        tester.widget<TextField>(password).controller!.text,
        'private-pass',
      );
      expect(tester.takeException(), isNull);

      // Tap password -> the keyboard metrics change again.
      await tester.ensureVisible(password);
      await tester.pumpAndSettle();
      await tester.tap(password);
      await tester.pump();
      await _setKeyboard(tester, 320 + cycle * 25.0);

      expect(tester.state(find.byType(LoginScreen)), same(page));
      expect(tester.state(find.byKey(_cardEntranceKey)), same(entrance));
      expect(_metricsOf(tester, _loginCard), closed);
      expect(_entranceOpacity(tester, _cardEntranceKey), 1);
      expect(
        tester.widget<TextField>(email).controller!.text,
        'test@example.com',
      );
      expect(tester.takeException(), isNull);

      // Keyboard closes -> smooth return, no replay.
      await _setKeyboard(tester, 0);
      expect(_metricsOf(tester, _loginCard), closed);
      expect(_entranceOpacity(tester, _cardEntranceKey), 1);
      expect(tester.state(find.byKey(_cardEntranceKey)), same(entrance));
      expect(tester.takeException(), isNull);
    }
  });

  // -------------------------------------------------------------------
  // Requirement 13 - safe area is physical, the keyboard is an inset.
  // -------------------------------------------------------------------
  testWidgets('13: the physical safe area and the keyboard inset stay apart',
      (tester) async {
    _useViewport(tester, _phone);
    await _pumpScreen(tester, const LoginScreen());

    final closed = _metricsOf(tester, _loginCard);
    // The stable viewport subtracts the physical safe area (24 top + 24
    // bottom) and nothing else.
    expect(closed.viewport, const Size(360, 752));

    await _setKeyboard(tester, 320);
    expect(_metricsOf(tester, _loginCard).viewport, const Size(360, 752));

    // Content stays inside the safe area with the keyboard open too.
    final brandFinder = find.byKey(const ValueKey('eras-brand-shield'));
    final brand = tester.getRect(brandFinder);
    expect(brand.top, greaterThanOrEqualTo(24));
    expect(brand.left, greaterThanOrEqualTo(16));
    expect(tester.takeException(), isNull);
  });
}
