/// TEMPORARY diagnostic test (will be removed with the fix).
///
/// Reproduces the "REQUESTER registration ... navigates to login" flow from
/// registration_role_test.dart and logs, after every pump: the fake clock,
/// frame scheduling state, active ticker count, widget presence, and the
/// ModalRoute animation status of every screen involved. The test then fails
/// deliberately with the collected log so the CI diagnostic workflow surfaces
/// it in an annotation.
library;

import 'dart:convert';

import 'package:dispatch_console_flutter/screens/login_screen.dart';
import 'package:dispatch_console_flutter/screens/register_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/client.dart' as http;
import 'package:http/testing.dart';

const ValueKey<String> requesterCardKey = ValueKey<String>(
  'role-card-REQUESTER',
);

http.Response _jsonResponse(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

http.MockClient _okRegisterApi() => http.MockClient((request) async {
      if (request.url.path == '/api/auth/register') {
        return _jsonResponse({
          'success': true,
          'message': 'Registration successful',
          'data': {
            'user': {'id': 41, 'role': 'REQUESTER'},
            'token': 'diag-token',
          },
        }, 201);
      }
      return _jsonResponse({'success': false, 'message': 'Not found'}, 404);
    });

class _LoggingObserver extends NavigatorObserver {
  _LoggingObserver(this.log);

  final void Function(String) log;

  void _l(String event, Route<dynamic> route, [Route<dynamic>? other]) {
    log(
      'OBS $event route=${route.runtimeType}'
      '${route is TransitionRoute ? ' anim=${route.animation?.status}' : ''}'
      '${other != null ? ' other=${other.runtimeType}' : ''}',
    );
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _l('didPush', route, previousRoute);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _l('didPop', route, previousRoute);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (newRoute != null) {
      _l('didReplace', newRoute, oldRoute);
    }
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _l('didRemove', route, previousRoute);
}

Future<void> _fillForm(WidgetTester tester) async {
  await tester.enterText(
    find.widgetWithText(TextFormField, 'Full name'),
    'Diag User',
  );
  await tester.enterText(
    find.widgetWithText(TextFormField, 'Email'),
    'diag@example.com',
  );
  await tester.enterText(
    find.widgetWithText(TextFormField, 'Phone number (optional)'),
    '9876543210',
  );
  await tester.enterText(
    find.widgetWithText(TextFormField, 'Password'),
    'Test123456',
  );
  await tester.enterText(
    find.widgetWithText(TextFormField, 'Confirm password'),
    'Test123456',
  );
  await tester.pump();
}

Future<void> _tapAfterScroll(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
}

typedef Snapshot = void Function(String label);

Snapshot _makeSnapshot(WidgetTester tester, void Function(String) log) {
  return (String label) {
    final login = find.byType(LoginScreen).evaluate();
    final register = find.byType(RegisterScreen).evaluate();
    String routeInfo(Element element) {
      final route = ModalRoute.of(element);
      if (route == null) return 'no-modal-route';
      final anim = route.animation;
      return 'route=${route.runtimeType} '
          'status=${anim?.status} value=${anim?.value.toStringAsFixed(3)} '
          'isActive=${route.isActive} isCurrent=${route.isCurrent}';
    }

    log(
      '[$label] t=${tester.binding.clock.now().toString().substring(0, 23)} '
      'scheduledFrame=${SchedulerBinding.instance.hasScheduledFrame} '
      'transientCallbacks=${SchedulerBinding.instance.transientCallbackCount} '
      'dialog=${find.byType(AlertDialog).evaluate().length} '
      'login=${login.length} register=${register.length}'
      '${login.isNotEmpty ? ' | LOGIN: ${routeInfo(login.first)}' : ''}'
      '${register.isNotEmpty ? ' | REG: ${routeInfo(register.first)}' : ''}',
    );
  };
}

Future<void> _runFlow(
  WidgetTester tester,
  void Function(String) log,
  Snapshot snapshot,
) {
  return http.runWithClient<Future<void>>(
    () async {
      final observer = _LoggingObserver(log);
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [observer],
          home: const RegisterScreen(),
        ),
      );
      await tester.pump();
      snapshot('initial');

      await tester.tap(find.byKey(requesterCardKey));
      await tester.pump();
      snapshot('role selected');

      await _fillForm(tester);
      snapshot('form filled');

      await _tapAfterScroll(tester, find.text('Create account'));
      snapshot('submit tapped');

      await tester.pump(const Duration(milliseconds: 300));
      snapshot('after +300ms');

      await tester.tap(find.text('Continue'));
      snapshot('continue tapped, no pump');
    },
    _okRegisterApi,
  );
}

void main() {
  testWidgets('diag A: registration navigation with fixed 400ms pumps',
      (tester) async {
    final log = <String>['--- DIAG A: fixed 400ms pumps ---'];
    var step = 0;
    void note(String line) {
      log.add('${(step++).toString().padLeft(3)} $line');
    }

    final snapshot = _makeSnapshot(tester, note);
    await _runFlow(tester, note, snapshot);

    for (var i = 1; i <= 5; i++) {
      await tester.pump(const Duration(milliseconds: 400));
      snapshot('after 400ms pump #$i');
    }

    log.add('--- END DIAG A ---');
    // Deliberate failure so the diagnostic workflow prints the whole log.
    fail(log.join(' ~ '));
  });

  testWidgets('diag B: registration navigation with pumpAndSettle',
      (tester) async {
    final log = <String>['--- DIAG B: pumpAndSettle ---'];
    var step = 0;
    void note(String line) {
      log.add('${(step++).toString().padLeft(3)} $line');
    }

    final snapshot = _makeSnapshot(tester, note);
    await _runFlow(tester, note, snapshot);

    await tester.pumpAndSettle();
    snapshot('after pumpAndSettle');

    for (var i = 1; i <= 2; i++) {
      await tester.pump(const Duration(milliseconds: 400));
      snapshot('after extra 400ms pump #$i');
    }

    log.add('--- END DIAG B ---');
    fail(log.join(' ~ '));
  });
}
