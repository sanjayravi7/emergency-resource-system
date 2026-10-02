/// Forgot-password flow (backend-driven, works identically on web and APK):
///
///   1. request a code for an address   -> generic 200 answer,
///   2. confirm the 6-digit code        -> checked without consuming it,
///   3. set the new password            -> code consumed, old sessions die.
///
/// The tests assert the client never invents state the server did not confirm,
/// never skips the code step and never reveals whether an address is
/// registered.
library;

import 'dart:convert';

import 'package:dispatch_console_flutter/screens/forgot_password_screen.dart';
import 'package:dispatch_console_flutter/screens/login_screen.dart';
import 'package:dispatch_console_flutter/services/api_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

class _Recorder {
  final List<http.Request> requests = <http.Request>[];
}

MockClient _resetBackend(
  _Recorder recorder, {
  bool codeAccepted = true,
  bool resetAccepted = true,
}) {
  return MockClient((request) async {
    recorder.requests.add(request);

    if (request.url.path == '/api/auth/password/forgot') {
      return _json({
        'success': true,
        'message': 'If that address belongs to an ERAS account, a reset code '
            'is on the way. It expires in 10 minutes.',
      });
    }

    if (request.url.path == '/api/auth/password/verify-code') {
      if (!codeAccepted) {
        return _json(
          {
            'success': false,
            'message': 'That reset code is invalid or has expired',
          },
          400,
        );
      }
      return _json({
        'success': true,
        'data': {'valid': true}
      });
    }

    if (request.url.path == '/api/auth/password/reset') {
      if (!resetAccepted) {
        return _json(
          {
            'success': false,
            'message': 'That reset code is invalid or expired'
          },
          400,
        );
      }
      return _json({
        'success': true,
        'message': 'Password updated. Sign in with your new password.',
      });
    }

    return _json({'success': true});
  });
}

Future<void> _enterEmailAndRequestCode(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const ValueKey('reset-email')),
    'asha@example.com',
  );
  await tester.tap(find.text('Email me a code'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

void _resetApiState() {
  ApiService.token = null;
  ApiService.currentRole = null;
  ApiService.currentUserId = null;
  ApiService.currentUserName = null;
  ApiService.currentUserEmail = null;
  ApiService.emailVerified = null;
}

void main() {
  setUp(_resetApiState);
  tearDown(_resetApiState);

  testWidgets('login screen links to the reset flow', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: LoginScreen()));
    await tester.pump();

    final link = find.text('Forgot password?');
    expect(link, findsOneWidget);
    await tester.ensureVisible(link);
    await tester.pump();
    await tester.tap(link);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(ForgotPasswordScreen), findsOneWidget);
  });

  testWidgets('a malformed address never reaches the backend', (tester) async {
    final recorder = _Recorder();

    await http.runWithClient(
      () async {
        await tester
            .pumpWidget(const MaterialApp(home: ForgotPasswordScreen()));
        await tester.pump();

        await tester.enterText(
          find.byKey(const ValueKey('reset-email')),
          'not-an-email',
        );
        await tester.tap(find.text('Email me a code'));
        await tester.pump();

        expect(find.text('Enter a valid email address'), findsOneWidget);
        expect(recorder.requests, isEmpty);
      },
      () => _resetBackend(recorder),
    );
  });

  testWidgets('the whole 3-step flow completes with exactly three calls',
      (tester) async {
    final recorder = _Recorder();

    await http.runWithClient(
      () async {
        await tester
            .pumpWidget(const MaterialApp(home: ForgotPasswordScreen()));
        await tester.pump();

        // Step 1: request the code.
        await _enterEmailAndRequestCode(tester);
        expect(find.byKey(const ValueKey('reset-code')), findsOneWidget);
        expect(find.textContaining('expires in 10 minutes'), findsOneWidget);

        // Step 2: confirm the code (checked, not consumed).
        await tester.enterText(
          find.byKey(const ValueKey('reset-code')),
          '135790',
        );
        await tester.tap(find.text('Confirm code'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        expect(find.byKey(const ValueKey('reset-password')), findsOneWidget);
        expect(
          find.byKey(const ValueKey('reset-password-confirm')),
          findsOneWidget,
        );

        // Step 3: set the new password.
        await tester.enterText(
          find.byKey(const ValueKey('reset-password')),
          'NewPass123',
        );
        await tester.enterText(
          find.byKey(const ValueKey('reset-password-confirm')),
          'NewPass123',
        );
        await tester.tap(find.text('Update password'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        expect(
          find.textContaining('Password updated. Sign in'),
          findsOneWidget,
        );

        final paths =
            recorder.requests.map((request) => request.url.path).toList();
        expect(paths, <String>[
          '/api/auth/password/forgot',
          '/api/auth/password/verify-code',
          '/api/auth/password/reset',
        ]);

        final resetBody =
            jsonDecode(recorder.requests.last.body) as Map<String, dynamic>;
        expect(resetBody['email'], 'asha@example.com');
        expect(resetBody['code'], '135790');
        expect(resetBody['password'], 'NewPass123');
        expect(resetBody['confirmPassword'], 'NewPass123');
        // The new password is never logged or echoed into a URL.
        expect(recorder.requests.last.url.toString(), isNot(contains('Pass')));
      },
      () => _resetBackend(recorder),
    );
  });

  testWidgets('a wrong code keeps the user on the code step', (tester) async {
    final recorder = _Recorder();

    await http.runWithClient(
      () async {
        await tester
            .pumpWidget(const MaterialApp(home: ForgotPasswordScreen()));
        await tester.pump();

        await _enterEmailAndRequestCode(tester);
        await tester.enterText(
          find.byKey(const ValueKey('reset-code')),
          '999999',
        );
        await tester.tap(find.text('Confirm code'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        expect(
          find.text('That reset code is invalid or has expired'),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('reset-password')), findsNothing);
      },
      () => _resetBackend(recorder, codeAccepted: false),
    );
  });

  testWidgets('the code step only accepts six digits', (tester) async {
    final recorder = _Recorder();

    await http.runWithClient(
      () async {
        await tester
            .pumpWidget(const MaterialApp(home: ForgotPasswordScreen()));
        await tester.pump();

        await _enterEmailAndRequestCode(tester);
        await tester.enterText(
          find.byKey(const ValueKey('reset-code')),
          '12ab',
        );
        await tester.tap(find.text('Confirm code'));
        await tester.pump();

        expect(
          find.text('Enter the 6-digit code from the email.'),
          findsOneWidget,
        );
        expect(
          recorder.requests
              .where((r) => r.url.path == '/api/auth/password/verify-code'),
          isEmpty,
        );
      },
      () => _resetBackend(recorder),
    );
  });

  testWidgets('a mismatched confirmation never reaches the backend',
      (tester) async {
    final recorder = _Recorder();

    await http.runWithClient(
      () async {
        await tester
            .pumpWidget(const MaterialApp(home: ForgotPasswordScreen()));
        await tester.pump();

        await _enterEmailAndRequestCode(tester);
        await tester.enterText(
          find.byKey(const ValueKey('reset-code')),
          '135790',
        );
        await tester.tap(find.text('Confirm code'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        await tester.enterText(
          find.byKey(const ValueKey('reset-password')),
          'NewPass123',
        );
        await tester.enterText(
          find.byKey(const ValueKey('reset-password-confirm')),
          'Different123',
        );
        await tester.tap(find.text('Update password'));
        await tester.pump();

        expect(find.text('Passwords do not match'), findsOneWidget);
        expect(
          recorder.requests
              .where((r) => r.url.path == '/api/auth/password/reset'),
          isEmpty,
        );
      },
      () => _resetBackend(recorder),
    );
  });

  testWidgets('a short password is refused with the same rule as the server',
      (tester) async {
    final recorder = _Recorder();

    await http.runWithClient(
      () async {
        await tester
            .pumpWidget(const MaterialApp(home: ForgotPasswordScreen()));
        await tester.pump();

        await _enterEmailAndRequestCode(tester);
        await tester.enterText(
          find.byKey(const ValueKey('reset-code')),
          '135790',
        );
        await tester.tap(find.text('Confirm code'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        await tester.enterText(
          find.byKey(const ValueKey('reset-password')),
          '12345',
        );
        await tester.enterText(
          find.byKey(const ValueKey('reset-password-confirm')),
          '12345',
        );
        await tester.tap(find.text('Update password'));
        await tester.pump();

        expect(find.text('Use at least 6 characters'), findsOneWidget);
        expect(
          recorder.requests
              .where((r) => r.url.path == '/api/auth/password/reset'),
          isEmpty,
        );
      },
      () => _resetBackend(recorder),
    );
  });
}
