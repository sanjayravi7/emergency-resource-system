/// "Remember me" login persistence tests.
///
/// The option must keep an authenticated user signed in across an app or
/// browser restart, must store nothing except the ERAS session token (never a
/// password), and must leave the normal in-memory session behaviour untouched
/// when it is not selected. The stored token is always re-validated by the
/// server before it is used.
library;

import 'dart:convert';

import 'package:dispatch_console_flutter/screens/dispatch_console_page.dart';
import 'package:dispatch_console_flutter/screens/login_screen.dart';
import 'package:dispatch_console_flutter/services/api_service.dart';
import 'package:dispatch_console_flutter/services/session_persistence.dart';
import 'package:dispatch_console_flutter/services/socket_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

Map<String, dynamic> _user() => <String, dynamic>{
      'id': 7,
      'name': 'Test User',
      'email': 'user@example.com',
      'phone': null,
      'role': 'REQUESTER',
      'isActive': true,
      'emailVerified': true,
    };

/// Mirrors the real backend contract for the two endpoints a remembered
/// session touches: POST /api/auth/login issues the ERAS JWT, and GET
/// /api/auth/me re-validates a stored token before it is restored.
MockClient _backend({bool acceptStoredSession = true}) {
  return MockClient((request) async {
    if (request.url.path == '/api/auth/login') {
      return _json({
        'success': true,
        'message': 'Login successful',
        'data': {
          'token': 'stored-session-token',
          'user': _user(),
        },
      });
    }
    if (request.url.path == '/api/auth/google') {
      return _json({
        'success': true,
        'message': 'Google login successful',
        'data': {
          'token': 'google-session-token',
          'user': _user(),
        },
      });
    }
    if (request.url.path == '/api/auth/me') {
      if (!acceptStoredSession) {
        return _json({
          'success': false,
          'message': 'Invalid or expired token',
        }, 401);
      }
      return _json({
        'success': true,
        'data': {'user': _user()},
      });
    }
    return _json({'success': true});
  });
}

void _resetApiState() {
  ApiService.token = null;
  ApiService.currentRole = null;
  ApiService.currentUserId = null;
  ApiService.currentUserName = null;
  ApiService.currentUserEmail = null;
  ApiService.emailVerified = null;
}

/// Pumps the real login screen and lets its start-up session restore run.
Future<void> _pumpLoginScreen(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(home: LoginScreen()));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 250));
}

Future<void> _signInThroughUi(WidgetTester tester) async {
  await tester.enterText(
    find.widgetWithText(TextField, 'Email'),
    'user@example.com',
  );
  await tester.enterText(
    find.widgetWithText(TextField, 'Password'),
    'Test123456',
  );
  await tester.pump();
  final signIn = find.text('Sign in');
  await tester.ensureVisible(signIn);
  await tester.pump();
  await tester.tap(signIn);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

/// Unmounts the tree so console timers and animations never outlive a test.
///
/// The root widget type changes on purpose: pumping another `MaterialApp`
/// would keep the existing `Navigator` - and with it every pushed route - so a
/// replaced `home` alone never disposes the console.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  setUpAll(SocketService.instance.dispose);
  setUp(() {
    // In-memory secure storage: the real plugin uses the platform keystore.
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    _resetApiState();
  });
  tearDown(_resetApiState);

  testWidgets('an unchecked "Remember me" stores nothing', (tester) async {
    await http.runWithClient(
      () async {
        await _pumpLoginScreen(tester);

        expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isFalse);

        await _signInThroughUi(tester);

        // The session exists for this app run only.
        expect(ApiService.token, 'stored-session-token');
        expect(find.byType(DispatchConsolePage), findsOneWidget);

        expect(await SessionPersistence.readToken(), isNull);
        expect(await SessionPersistence.readRememberPreference(), isFalse);

        await _unmount(tester);
      },
      () => _backend(),
    );
  });

  testWidgets('an unchecked "Remember me" asks for credentials again',
      (tester) async {
    await http.runWithClient(
      () async {
        await _pumpLoginScreen(tester);
        await _signInThroughUi(tester);
        await _unmount(tester);

        // A fresh app start keeps nothing: no session is restored.
        _resetApiState();
        await _pumpLoginScreen(tester);

        expect(find.byType(DispatchConsolePage), findsNothing);
        expect(find.text('Sign in'), findsOneWidget);
        expect(ApiService.currentRole, isNull);

        await _unmount(tester);
      },
      () => _backend(),
    );
  });

  testWidgets('a checked "Remember me" survives an app restart',
      (tester) async {
    await http.runWithClient(
      () async {
        await _pumpLoginScreen(tester);
        await tester.tap(find.byType(Checkbox));
        await tester.pump();
        expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);

        await _signInThroughUi(tester);

        expect(await SessionPersistence.readToken(), 'stored-session-token');
        expect(await SessionPersistence.readRememberPreference(), isTrue);

        await _unmount(tester);

        // A fresh app start: only the persisted session survives, and the
        // server re-validates it before the console opens.
        _resetApiState();
        await _pumpLoginScreen(tester);

        expect(find.byType(DispatchConsolePage), findsOneWidget);
        expect(find.byType(LoginScreen), findsNothing);
        expect(ApiService.currentRole, 'REQUESTER');
        expect(ApiService.currentUserEmail, 'user@example.com');

        await _unmount(tester);
      },
      () => _backend(),
    );
  });

  testWidgets('a stored session the server rejects is discarded',
      (tester) async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      'eras.session.token': 'stale-session-token',
      'eras.session.remember_me': 'true',
    });

    await http.runWithClient(
      () async {
        await _pumpLoginScreen(tester);

        // Expired/revoked: the login form stays, and the dead token is gone.
        expect(find.byType(DispatchConsolePage), findsNothing);
        expect(find.text('Sign in'), findsOneWidget);
        expect(ApiService.token, isNull);
        expect(await SessionPersistence.readToken(), isNull);

        // The user's remembered choice itself is still shown, so the checkbox
        // never disagrees with what is stored.
        expect(await SessionPersistence.readRememberPreference(), isTrue);
        expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);

        await _unmount(tester);
      },
      () => _backend(acceptStoredSession: false),
    );
  });

  testWidgets('the checkbox reflects a remembered choice', (tester) async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      'eras.session.remember_me': 'true',
    });

    await _pumpLoginScreen(tester);

    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);

    await _unmount(tester);
  });

  test('logout removes the remembered session', () async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await SessionPersistence.rememberSession('stored-session-token');
    expect(await SessionPersistence.readToken(), 'stored-session-token');

    ApiService.token = 'stored-session-token';
    ApiService.currentRole = 'REQUESTER';
    await ApiService.logout();

    expect(ApiService.token, isNull);
    expect(await SessionPersistence.readToken(), isNull);
    expect(await SessionPersistence.readRememberPreference(), isFalse);
  });

  test('only the session token and the preference are stored', () async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});

    await SessionPersistence.rememberSession('stored-session-token');

    final stored = await const FlutterSecureStorage().readAll();
    expect(stored['eras.session.token'], 'stored-session-token');
    expect(stored['eras.session.remember_me'], 'true');
    // No password, email or any other credential material is persisted.
    expect(stored.keys, hasLength(2));
  });

  test('password login finishes persistence before returning', () async {
    await http.runWithClient(
      () async {
        await ApiService.login(
          'user@example.com',
          'Test123456',
          rememberMe: true,
        );

        // Read the platform storage directly, bypassing the SessionPersistence
        // ordering queue: the write must have completed when login returned.
        final stored =
            await const FlutterSecureStorage().read(key: 'eras.session.token');
        expect(stored, 'stored-session-token');
      },
      () => _backend(),
    );
  });

  test('Google sign-in persists "Remember me" before returning', () async {
    await http.runWithClient(
      () async {
        await ApiService.googleSignIn(
          idToken: 'firebase-id-token',
          rememberMe: true,
        );

        expect(ApiService.token, 'google-session-token');
        expect(await SessionPersistence.readRememberPreference(), isTrue);
        final stored =
            await const FlutterSecureStorage().read(key: 'eras.session.token');
        expect(stored, 'google-session-token');
      },
      () => _backend(),
    );
  });

  test('Google sign-in without "Remember me" clears storage', () async {
    await SessionPersistence.rememberSession('older-session-token');
    expect(await SessionPersistence.readToken(), 'older-session-token');

    await http.runWithClient(
      () async {
        await ApiService.googleSignIn(idToken: 'firebase-id-token');
      },
      () => _backend(),
    );

    expect(await SessionPersistence.readToken(), isNull);
    expect(await SessionPersistence.readRememberPreference(), isFalse);
  });
}
