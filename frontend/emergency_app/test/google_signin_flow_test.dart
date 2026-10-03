/// Google registration/login through the EXISTING Firebase project.
///
/// The Flutter layer only obtains a Firebase ID token and posts it to
/// `POST /api/auth/google`; the backend verifies it against Google's published
/// certificates and returns the normal ERAS JWT. These tests lock down that
/// contract:
///
///   * a returned ID token is posted verbatim (never a password, never a role
///     for sign-in),
///   * the role used for routing always comes from the server payload,
///   * a dismissed Google sheet changes nothing,
///   * an existing account is linked server-side, so the client never creates a
///     second session state,
///   * registration may REQUEST a public role but can never ask for ADMIN.
library;

import 'dart:convert';

import 'package:dispatch_console_flutter/screens/dispatch_console_page.dart';
import 'package:dispatch_console_flutter/screens/email_verification_screen.dart';
import 'package:dispatch_console_flutter/screens/login_screen.dart';
import 'package:dispatch_console_flutter/screens/register_screen.dart';
import 'package:dispatch_console_flutter/screens/responder_readiness_page.dart';
import 'package:dispatch_console_flutter/services/api_service.dart';
import 'package:dispatch_console_flutter/services/google_auth_service.dart';
import 'package:dispatch_console_flutter/services/socket_service.dart';
import 'package:dispatch_console_flutter/widgets/auth_visuals.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

/// Records every request so the token/role contract can be asserted.
class _Recorder {
  final List<http.Request> requests = <http.Request>[];
}

MockClient _googleBackend(
  _Recorder recorder, {
  required String role,
  bool emailVerified = true,
  int status = 200,
}) {
  return MockClient((request) async {
    recorder.requests.add(request);

    if (request.url.path == '/api/auth/google' && status == 200) {
      return _json({
        'success': true,
        'message': 'Google login successful',
        'data': {
          'token': 'eras-jwt-from-server',
          'user': {
            'id': 21,
            'name': 'Google User',
            'email': 'google.user@example.com',
            'phone': null,
            'role': role,
            'isActive': true,
            'emailVerified': emailVerified,
            'responderStatus': role == 'RESPONDER' ? 'OFFLINE' : null,
          },
        },
      });
    }

    if (request.url.path == '/api/auth/google') {
      return _json(
        {
          'success': false,
          'code': 'GOOGLE_AUTH_NOT_CONFIGURED',
          'message': 'Google sign-in is not configured on this server',
        },
        status,
      );
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

Future<void> _tapGoogle(WidgetTester tester) async {
  final button = find.text('Continue with Google');
  expect(button, findsOneWidget);
  await tester.ensureVisible(button);
  await tester.pump();
  await tester.tap(button);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  setUpAll(SocketService.instance.dispose);
  setUp(_resetApiState);
  tearDown(() {
    GoogleAuthService.debugTokenProvider = null;
    _resetApiState();
  });

  testWidgets('login page offers Google sign-in next to the password form',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: LoginScreen()));
    await tester.pump();

    expect(find.text('Continue with Google'), findsOneWidget);
    // The password path is untouched.
    expect(find.widgetWithText(TextField, 'Email'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Password'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
  });

  testWidgets('a dismissed Google sheet leaves the user on the login page',
      (tester) async {
    GoogleAuthService.debugTokenProvider = () async => null;

    await tester.pumpWidget(const MaterialApp(home: LoginScreen()));
    await tester.pump();
    await _tapGoogle(tester);

    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.byType(DispatchConsolePage), findsNothing);
    expect(ApiService.token, isNull);
    expect(ApiService.currentRole, isNull);

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
  });

  testWidgets(
      'a Google ID token is exchanged for an ERAS session and the '
      'REQUESTER console opens', (tester) async {
    final recorder = _Recorder();
    GoogleAuthService.debugTokenProvider = () async => 'firebase-id-token-123';

    await http.runWithClient(
      () async {
        await tester.pumpWidget(const MaterialApp(home: LoginScreen()));
        await tester.pump();
        await _tapGoogle(tester);

        final googleCalls = recorder.requests
            .where((request) => request.url.path == '/api/auth/google')
            .toList();
        expect(googleCalls, hasLength(1));

        final body =
            jsonDecode(googleCalls.single.body) as Map<String, dynamic>;
        // The Firebase ID token is sent as-is; no password is ever involved and
        // sign-in never asks the server for a role.
        expect(body['idToken'], 'firebase-id-token-123');
        expect(body.containsKey('password'), isFalse);
        expect(body.containsKey('role'), isFalse);

        // The ERAS session comes from the server payload.
        expect(ApiService.token, 'eras-jwt-from-server');
        expect(ApiService.currentRole, 'REQUESTER');
        expect(ApiService.currentUserId, 21);
        expect(ApiService.currentUserEmail, 'google.user@example.com');
        expect(find.byType(DispatchConsolePage), findsOneWidget);
        // Google verified the mailbox, so the verification screen is skipped.
        expect(find.byType(EmailVerificationScreen), findsNothing);

        await tester.pumpWidget(const MaterialApp(home: SizedBox()));
        await tester.pump(const Duration(milliseconds: 100));
      },
      () => _googleBackend(recorder, role: 'REQUESTER'),
    );
  });

  testWidgets('a responder Google account still lands on readiness first',
      (tester) async {
    final recorder = _Recorder();
    GoogleAuthService.debugTokenProvider = () async => 'firebase-id-token-456';

    await http.runWithClient(
      () async {
        await tester.pumpWidget(const MaterialApp(home: LoginScreen()));
        await tester.pump();
        await _tapGoogle(tester);

        expect(ApiService.currentRole, 'RESPONDER');
        expect(find.byType(ResponderReadinessPage), findsOneWidget);
        expect(find.byType(DispatchConsolePage), findsNothing);

        await tester.pumpWidget(const MaterialApp(home: SizedBox()));
        await tester.pump(const Duration(milliseconds: 100));
      },
      () => _googleBackend(recorder, role: 'RESPONDER'),
    );
  });

  testWidgets('a server-side Google failure is surfaced without a session',
      (tester) async {
    final recorder = _Recorder();
    GoogleAuthService.debugTokenProvider = () async => 'firebase-id-token-789';

    await http.runWithClient(
      () async {
        await tester.pumpWidget(const MaterialApp(home: LoginScreen()));
        await tester.pump();
        await _tapGoogle(tester);
        final loginPageState = tester.state(find.byType(LoginScreen));

        expect(ApiService.token, isNull);
        expect(find.byType(LoginScreen), findsOneWidget);
        expect(find.byType(DispatchConsolePage), findsNothing);
        expect(
          find.textContaining(
              'Google sign-in is not configured on this server'),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey<String>('login-error-region')),
          findsOneWidget,
        );
        expect(
          tester
              .widget<AuthGoogleButton>(find.byType(AuthGoogleButton))
              .onPressed,
          isNotNull,
        );

        // A backend 503 is honest and non-terminal: the user remains on the
        // login page, can read the message, and can retry the Google action.
        await _tapGoogle(tester);
        expect(
          recorder.requests
              .where((request) => request.url.path == '/api/auth/google'),
          hasLength(2),
        );
        expect(ApiService.token, isNull);
        expect(find.byType(LoginScreen), findsOneWidget);
        expect(
          find.textContaining(
              'Google sign-in is not configured on this server'),
          findsOneWidget,
        );

        // The persistent error region survives the viewport/keyboard change;
        // no route replacement or page-state reset is triggered by insets.
        tester.view.viewInsets = FakeViewPadding(bottom: 250);
        await tester.pump();
        await tester.pumpAndSettle();
        expect(
            identical(tester.state(find.byType(LoginScreen)), loginPageState),
            isTrue);
        expect(
          find.textContaining(
              'Google sign-in is not configured on this server'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);

        tester.view.viewInsets = FakeViewPadding();
        await tester.pump();
        await tester.pumpAndSettle();
        await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      },
      () => _googleBackend(recorder, role: 'REQUESTER', status: 503),
    );
  });

  testWidgets('registration still requires a role before Google runs',
      (tester) async {
    final recorder = _Recorder();
    GoogleAuthService.debugTokenProvider = () async => 'firebase-id-token-reg';

    await http.runWithClient(
      () async {
        await tester.pumpWidget(const MaterialApp(home: RegisterScreen()));
        await tester.pump();

        expect(find.text('Continue with Google'), findsOneWidget);

        // Choosing a role is still required: Google does not bypass it, and no
        // account is created without an explicit choice.
        final google = find.text('Continue with Google');
        await tester.ensureVisible(google);
        await tester.pump();
        await tester.tap(google);
        await tester.pump();
        expect(find.text('Choose how you want to use ERAS.'), findsOneWidget);
        expect(
          recorder.requests.where((r) => r.url.path == '/api/auth/google'),
          isEmpty,
        );

        await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      },
      () => _googleBackend(recorder, role: 'REQUESTER'),
    );
  });

  testWidgets('Google registration sends the selected PUBLIC role only',
      (tester) async {
    final recorder = _Recorder();
    GoogleAuthService.debugTokenProvider = () async => 'firebase-id-token-role';

    await http.runWithClient(
      () async {
        await tester.pumpWidget(const MaterialApp(home: RegisterScreen()));
        await tester.pump();

        await tester
            .tap(find.byKey(const ValueKey<String>('role-card-RESPONDER')));
        await tester.pump();

        final google = find.text('Continue with Google');
        await tester.ensureVisible(google);
        await tester.pump();
        await tester.tap(google);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump(const Duration(milliseconds: 400));

        final call = recorder.requests
            .singleWhere((request) => request.url.path == '/api/auth/google');
        final body = jsonDecode(call.body) as Map<String, dynamic>;

        expect(body['idToken'], 'firebase-id-token-role');
        // Only a public role can ever be requested; ADMIN is not selectable and
        // the server rejects it even if a client tried.
        expect(body['role'], 'RESPONDER');
        expect(body['role'], isNot('ADMIN'));

        expect(ApiService.currentRole, 'RESPONDER');
        expect(find.byType(ResponderReadinessPage), findsOneWidget);

        await tester.pumpWidget(const MaterialApp(home: SizedBox()));
        await tester.pump(const Duration(milliseconds: 100));
      },
      () => _googleBackend(recorder, role: 'RESPONDER'),
    );
  });
}
