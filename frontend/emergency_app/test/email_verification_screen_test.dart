/// First-login email verification for email/password accounts.
///
/// Behaviour locked down here:
///   * only a 6-digit code is accepted (no free text, no longer codes),
///   * verification refreshes the authoritative account state (never a local
///     flag flip only),
///   * resending is an explicit, rate-limited server call with a generic
///     answer (no account enumeration),
///   * "Refresh status" re-reads the server instead of trusting local state,
///   * the user can always sign out - verification never traps the account.
library;

import 'dart:convert';

import 'package:dispatch_console_flutter/screens/email_verification_screen.dart';
import 'package:dispatch_console_flutter/screens/login_screen.dart';
import 'package:dispatch_console_flutter/services/api_service.dart';
import 'package:dispatch_console_flutter/services/socket_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

class _Recorder {
  final List<http.Request> requests = <http.Request>[];
}

MockClient _verificationBackend(
  _Recorder recorder, {
  bool verifyOk = true,
  bool verifiedAfterRefresh = false,
}) {
  return MockClient((request) async {
    recorder.requests.add(request);

    if (request.url.path == '/api/auth/verify-email') {
      if (!verifyOk) {
        return _json(
          {
            'success': false,
            'message': 'That verification code is invalid or has expired',
          },
          400,
        );
      }
      return _json({
        'success': true,
        'data': {
          'user': {
            'id': 5,
            'name': 'Asha',
            'email': 'asha@example.com',
            'role': 'REQUESTER',
            'emailVerified': true,
          },
        },
      });
    }

    if (request.url.path == '/api/auth/resend-verification') {
      return _json({
        'success': true,
        'message': 'If that address belongs to an ERAS account, a new code '
            'is on the way.',
      });
    }

    if (request.url.path == '/api/auth/me') {
      return _json({
        'success': true,
        'data': {
          'id': 5,
          'name': 'Asha',
          'email': 'asha@example.com',
          'role': 'REQUESTER',
          'emailVerified': verifiedAfterRefresh,
        },
      });
    }

    return _json({'success': true});
  });
}

void _resetApiState() {
  ApiService.token = 'session-token';
  ApiService.currentRole = 'REQUESTER';
  ApiService.currentUserId = 5;
  ApiService.currentUserName = 'Asha';
  ApiService.currentUserEmail = 'asha@example.com';
  ApiService.emailVerified = false;
}

/// Backend contract for a password login whose mailbox is not verified yet.
MockClient _unverifiedLoginBackend() => MockClient((request) async {
      if (request.url.path == '/api/auth/login') {
        return _json({
          'success': true,
          'message': 'Login successful',
          'data': {
            'token': 'session-token',
            'user': {
              'id': 5,
              'name': 'Asha',
              'email': 'asha@example.com',
              'phone': null,
              'role': 'REQUESTER',
              'isActive': true,
              'emailVerified': false,
            },
            'verificationRequired': true,
          },
        });
      }
      return _json({'success': true});
    });

void main() {
  setUpAll(SocketService.instance.dispose);
  setUp(_resetApiState);
  tearDown(() {
    ApiService.token = null;
    ApiService.currentRole = null;
    ApiService.currentUserId = null;
    ApiService.currentUserName = null;
    ApiService.currentUserEmail = null;
    ApiService.emailVerified = null;
  });

  testWidgets('renders the ERAS verification step for the signed-in address',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: EmailVerificationScreen(email: 'asha@example.com'),
      ),
    );
    await tester.pump();

    expect(find.text('VERIFY YOUR EMAIL'), findsOneWidget);
    expect(
      find.textContaining('asha@example.com'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('verification-code')), findsOneWidget);
    expect(find.byKey(const ValueKey('resend-verification')), findsOneWidget);
    expect(find.byKey(const ValueKey('refresh-verification')), findsOneWidget);
  });

  testWidgets('rejects anything that is not a 6-digit code', (tester) async {
    final recorder = _Recorder();

    await http.runWithClient(
      () async {
        await tester.pumpWidget(
          const MaterialApp(home: EmailVerificationScreen()),
        );
        await tester.pump();

        await tester.enterText(
          find.byKey(const ValueKey('verification-code')),
          '123',
        );
        await tester.tap(find.text('Verify email'));
        await tester.pump();

        expect(
          find.text('Enter the 6-digit code from the email.'),
          findsOneWidget,
        );
        expect(
          recorder.requests
              .where((r) => r.url.path == '/api/auth/verify-email'),
          isEmpty,
        );
      },
      () => _verificationBackend(recorder),
    );
  });

  testWidgets('a valid code verifies the account through the server',
      (tester) async {
    final recorder = _Recorder();

    await http.runWithClient(
      () async {
        await tester.pumpWidget(
          const MaterialApp(home: EmailVerificationScreen()),
        );
        await tester.pump();

        await tester.enterText(
          find.byKey(const ValueKey('verification-code')),
          '482915',
        );
        await tester.tap(find.text('Verify email'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        final call = recorder.requests
            .singleWhere((r) => r.url.path == '/api/auth/verify-email');
        expect(
          jsonDecode(call.body),
          <String, dynamic>{'code': '482915'},
        );
        expect(ApiService.emailVerified, isTrue);
        expect(find.textContaining('Email verified'), findsWidgets);
      },
      () => _verificationBackend(recorder),
    );
  });

  testWidgets('an invalid code keeps the account unverified and explains why',
      (tester) async {
    final recorder = _Recorder();

    await http.runWithClient(
      () async {
        await tester.pumpWidget(
          const MaterialApp(home: EmailVerificationScreen()),
        );
        await tester.pump();

        await tester.enterText(
          find.byKey(const ValueKey('verification-code')),
          '000000',
        );
        await tester.tap(find.text('Verify email'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        expect(
          find.text('That verification code is invalid or has expired'),
          findsOneWidget,
        );
        // The state stays unverified: nothing is flipped locally on failure.
        expect(ApiService.emailVerified, isFalse);
      },
      () => _verificationBackend(recorder, verifyOk: false),
    );
  });

  testWidgets('resending asks the server for a new code and stays generic',
      (tester) async {
    final recorder = _Recorder();

    await http.runWithClient(
      () async {
        await tester.pumpWidget(
          const MaterialApp(
            home: EmailVerificationScreen(email: 'asha@example.com'),
          ),
        );
        await tester.pump();

        await tester.tap(find.byKey(const ValueKey('resend-verification')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        final call = recorder.requests
            .singleWhere((r) => r.url.path == '/api/auth/resend-verification');
        expect(jsonDecode(call.body)['email'], 'asha@example.com');
        expect(find.textContaining('If that address belongs'), findsOneWidget);
        // The generic answer never discloses whether the account exists.
        expect(find.textContaining('No account'), findsNothing);
      },
      () => _verificationBackend(recorder),
    );
  });

  testWidgets('refresh status re-reads the server, then reports the result',
      (tester) async {
    final recorder = _Recorder();

    await http.runWithClient(
      () async {
        await tester.pumpWidget(
          const MaterialApp(home: EmailVerificationScreen()),
        );
        await tester.pump();

        await tester.tap(find.byKey(const ValueKey('refresh-verification')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        expect(
          recorder.requests.where((r) => r.url.path == '/api/auth/me'),
          hasLength(1),
        );
        // The server still reports unverified, so nothing pretends otherwise.
        expect(ApiService.emailVerified, isFalse);
        expect(find.textContaining('not verified yet'), findsOneWidget);
      },
      () => _verificationBackend(recorder, verifiedAfterRefresh: false),
    );
  });

  testWidgets('refresh status confirms a server-side verification',
      (tester) async {
    final recorder = _Recorder();

    await http.runWithClient(
      () async {
        await tester.pumpWidget(
          const MaterialApp(home: EmailVerificationScreen()),
        );
        await tester.pump();

        await tester.tap(find.byKey(const ValueKey('refresh-verification')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        expect(ApiService.emailVerified, isTrue);
        expect(find.textContaining('Your email is verified.'), findsOneWidget);
      },
      () => _verificationBackend(recorder, verifiedAfterRefresh: true),
    );
  });

  testWidgets(
      'a password login for an unverified account opens verification '
      'instead of the console', (tester) async {
    ApiService.token = null;
    ApiService.emailVerified = null;

    await http.runWithClient(
      () async {
        await tester.pumpWidget(const MaterialApp(home: LoginScreen()));
        await tester.pump();

        await tester.enterText(
          find.widgetWithText(TextField, 'Email'),
          'asha@example.com',
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

        expect(find.byType(EmailVerificationScreen), findsOneWidget);
        // The ERAS session exists (the account is authenticated) but the
        // console is not reachable until the mailbox is confirmed.
        expect(ApiService.token, 'session-token');
        expect(ApiService.emailVerified, isFalse);
        expect(find.textContaining('asha@example.com'), findsOneWidget);

        await tester.pumpWidget(const MaterialApp(home: SizedBox()));
        await tester.pump(const Duration(milliseconds: 100));
      },
      _unverifiedLoginBackend,
    );
  });

  testWidgets('a verified password login goes straight to the console',
      (tester) async {
    await http.runWithClient(
      () async {
        await tester.pumpWidget(const MaterialApp(home: LoginScreen()));
        await tester.pump();

        await tester.enterText(
          find.widgetWithText(TextField, 'Email'),
          'asha@example.com',
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

        expect(find.byType(EmailVerificationScreen), findsNothing);

        await tester.pumpWidget(const MaterialApp(home: SizedBox()));
        await tester.pump(const Duration(milliseconds: 100));
      },
      () => MockClient((request) async {
        if (request.url.path == '/api/auth/login') {
          return _json({
            'success': true,
            'data': {
              'token': 'session-token',
              'user': {
                'id': 5,
                'name': 'Asha',
                'email': 'asha@example.com',
                'role': 'REQUESTER',
                'isActive': true,
                'emailVerified': true,
              },
            },
          });
        }
        return _json({'success': true});
      }),
    );
  });

  testWidgets('signing out from verification returns to the login screen',
      (tester) async {
    final recorder = _Recorder();

    await http.runWithClient(
      () async {
        await tester.pumpWidget(
          const MaterialApp(home: EmailVerificationScreen()),
        );
        await tester.pump();

        await tester.ensureVisible(
          find.byKey(const ValueKey('verification-sign-out')),
        );
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('verification-sign-out')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(find.byType(LoginScreen), findsOneWidget);
        expect(ApiService.token, isNull);
      },
      () => _verificationBackend(recorder),
    );
  });
}
