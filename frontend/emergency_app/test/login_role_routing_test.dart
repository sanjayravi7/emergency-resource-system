/// Login + role routing tests.
///
/// Login is email + password only - there is no role selector. After a
/// successful sign-in the app opens the experience that matches the role the
/// SERVER returned for the authenticated user (data.user.role, read from
/// PostgreSQL):
///   - REQUESTER -> the requester operations console,
///   - RESPONDER -> the responder readiness experience,
///   - ADMIN     -> the admin operations console.
/// The role never comes from a selector, URL parameter, or local storage.
library;

import 'dart:convert';

import 'package:dispatch_console_flutter/screens/dispatch_console_page.dart';
import 'package:dispatch_console_flutter/screens/login_screen.dart';
import 'package:dispatch_console_flutter/screens/responder_readiness_page.dart';
import 'package:dispatch_console_flutter/services/api_service.dart';
import 'package:dispatch_console_flutter/services/socket_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

/// Mirrors the real backend contract: POST /api/auth/login answers with
/// { success, message, data: { user, token } } where user.role is the value
/// stored in PostgreSQL. Every other endpoint gets an empty-collection
/// response, exactly like an empty database.
http.MockClient _backendWithRole(String role) => MockClient(
      (request) async {
        if (request.url.path == '/api/auth/login') {
          return _json({
            'success': true,
            'message': 'Login successful',
            'data': {
              'token': 'test-token-$role',
              'user': {
                'id': 7,
                'name': 'Test User',
                'email': 'user@example.com',
                'phone': null,
                'role': role,
                'isActive': true,
                'responderStatus': role == 'RESPONDER' ? 'OFFLINE' : null,
              },
            },
          });
        }
        return _json({'success': true});
      },
    );

void _resetApiState() {
  ApiService.token = null;
  ApiService.currentRole = null;
  ApiService.currentUserId = null;
  ApiService.currentUserName = null;
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
  await tester.tap(find.text('Sign in'));
  await tester.pump();
  // Mocked login resolves, navigation transition completes, and the
  // destination page finishes its initial data load.
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 250));
}

void main() {
  // The routing tests exercise navigation only; realtime (Socket.IO) is a
  // separate concern. Dispose the singleton so no network socket or reconnect
  // timer is ever created inside these widget tests.
  setUpAll(SocketService.instance.dispose);
  setUp(_resetApiState);
  tearDown(_resetApiState);

  testWidgets('login page has email, password and sign-in - no role selection', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: LoginScreen()));
    await tester.pump();

    expect(find.text('ERAS'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Email'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Password'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);

    // Absolutely no role choosing on the login page: the role was selected
    // once during registration and always comes from the server afterwards.
    expect(find.text('I NEED HELP'), findsNothing);
    expect(find.text("I'M WILLING TO HELP"), findsNothing);
    expect(find.text('Request emergency assistance'), findsNothing);
    expect(find.text('Provide emergency assistance'), findsNothing);
    expect(find.text('How would you like to use ERAS?'), findsNothing);
    expect(find.textContaining('Requester'), findsNothing);
    expect(find.textContaining('Responder'), findsNothing);
    expect(find.textContaining('ADMIN'), findsNothing);
    expect(find.text('Choose Requester'), findsNothing);
    expect(find.text('Choose Responder'), findsNothing);

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
  });

  test('login stores the role returned by the server for every role', () async {
    const roles = ['REQUESTER', 'RESPONDER', 'ADMIN'];

    for (final role in roles) {
      _resetApiState();
      await http.runWithClient<Future<void>>(
        () async {
          await ApiService.login('user@example.com', 'Test123456');

          expect(ApiService.token, 'test-token-$role');
          expect(ApiService.currentRole, role);
          expect(ApiService.isRequester, role == 'REQUESTER');
          expect(ApiService.isResponder, role == 'RESPONDER');
          expect(ApiService.isAdmin, role == 'ADMIN');
        },
        () => _backendWithRole(role),
      );
    }
  });

  testWidgets('REQUESTER login opens the requester experience', (tester) async {
    await http.runWithClient<Future<void>>(
      () async {
        await tester.pumpWidget(const MaterialApp(home: LoginScreen()));
        await tester.pump();

        await _signInThroughUi(tester);

        expect(ApiService.currentRole, 'REQUESTER');
        expect(ApiService.isRequester, isTrue);
        expect(find.byType(DispatchConsolePage), findsOneWidget);
        expect(find.byType(ResponderReadinessPage), findsNothing);
        expect(find.byType(LoginScreen), findsNothing);

        // Unmount the console (it owns periodic timers) before the test ends.
        await tester.pumpWidget(const MaterialApp(home: SizedBox()));
        await tester.pump(const Duration(milliseconds: 100));
      },
      () => _backendWithRole('REQUESTER'),
    );
  });

  testWidgets('RESPONDER login opens the responder experience', (tester) async {
    await http.runWithClient<Future<void>>(
      () async {
        await tester.pumpWidget(const MaterialApp(home: LoginScreen()));
        await tester.pump();

        await _signInThroughUi(tester);

        expect(ApiService.currentRole, 'RESPONDER');
        expect(ApiService.isResponder, isTrue);
        expect(find.byType(ResponderReadinessPage), findsOneWidget);
        expect(find.byType(DispatchConsolePage), findsNothing);
        expect(find.byType(LoginScreen), findsNothing);

        await tester.pumpWidget(const MaterialApp(home: SizedBox()));
        await tester.pump(const Duration(milliseconds: 100));
      },
      () => _backendWithRole('RESPONDER'),
    );
  });

  testWidgets('ADMIN login opens the admin experience', (tester) async {
    await http.runWithClient<Future<void>>(
      () async {
        await tester.pumpWidget(const MaterialApp(home: LoginScreen()));
        await tester.pump();

        await _signInThroughUi(tester);

        expect(ApiService.currentRole, 'ADMIN');
        expect(ApiService.isAdmin, isTrue);
        // ADMIN shares the operations console, which enables the
        // administrative controls for the authenticated admin role.
        expect(find.byType(DispatchConsolePage), findsOneWidget);
        expect(find.byType(ResponderReadinessPage), findsNothing);
        expect(find.byType(LoginScreen), findsNothing);

        await tester.pumpWidget(const MaterialApp(home: SizedBox()));
        await tester.pump(const Duration(milliseconds: 100));
      },
      () => _backendWithRole('ADMIN'),
    );
  });
}
