/// ADMIN-only after-action log deletion.
///
/// Security requirements locked down here:
///   * the destructive control exists ONLY for an ADMIN session - it is absent,
///     not merely disabled, for REQUESTER and RESPONDER,
///   * it always asks for confirmation and states that the action is
///     irreversible,
///   * it never claims the security audit trail is destroyed - the opposite is
///     true (ADMIN_DELETED_LOG is kept),
///   * cancelling issues no request at all,
///   * the call is a DELETE to `/api/admin/logs/:id` carrying `confirm: true`
///     (the server refuses to act without it).
library;

import 'dart:async';
import 'dart:convert';

import 'package:dispatch_console_flutter/models/eras_models.dart';
import 'package:dispatch_console_flutter/screens/dispatch_console_page.dart';
import 'package:dispatch_console_flutter/services/api_service.dart';
import 'package:dispatch_console_flutter/services/socket_service.dart';
import 'package:dispatch_console_flutter/theme/app_theme.dart';
import 'package:dispatch_console_flutter/widgets/log_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

EmergencyRequest _closedRequest() =>
    EmergencyRequest.fromJson(<String, dynamic>{
      'id': 91,
      'emergencyType': 'Fire',
      'description': 'Closed incident',
      'location': 'Thrissur, Kerala',
      'priority': 'HIGH',
      'status': 'COMPLETED',
      'createdAt': '2026-10-01T10:00:00.000Z',
      'updatedAt': '2026-10-01T11:30:00.000Z',
      'requiredResources': <dynamic>[],
      'allocations': <dynamic>[],
    });

Widget _host(Widget child) => MaterialApp(
      theme: erasTheme(Brightness.light),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

class _Recorder {
  final List<http.Request> requests = <http.Request>[];
}

void main() {
  setUpAll(SocketService.instance.dispose);
  setUp(() {
    ApiService.token = 'admin-session';
    ApiService.currentRole = 'ADMIN';
    ApiService.currentUserId = 1;
    ApiService.currentUserName = 'Admin';
  });
  tearDown(() {
    ApiService.token = null;
    ApiService.currentRole = null;
    ApiService.currentUserId = null;
    ApiService.currentUserName = null;
  });

  group('log panel', () {
    testWidgets('an ADMIN row offers DELETE next to VIEW', (tester) async {
      tester.view.physicalSize = const Size(1500, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_host(LogPanel(
        logEntries: <EmergencyRequest>[_closedRequest()],
        onViewRequest: (_) {},
        onDeleteEntry: (_) {},
      )));
      await tester.pump();

      expect(
        find.byKey(const Key('view-log-request-91')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('delete-log-request-91')),
        findsOneWidget,
      );
      // The word "delete" is visible, and it is styled as destructive.
      expect(find.text('DELETE'), findsOneWidget);
    });

    testWidgets('without the admin callback there is no delete control',
        (tester) async {
      tester.view.physicalSize = const Size(1500, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_host(LogPanel(
        logEntries: <EmergencyRequest>[_closedRequest()],
        onViewRequest: (_) {},
        // No onDeleteEntry: this is exactly what a REQUESTER/RESPONDER sees.
      )));
      await tester.pump();

      expect(find.byKey(const Key('delete-log-request-91')), findsNothing);
      expect(find.text('DELETE'), findsNothing);
      expect(find.text('VIEW'), findsOneWidget);
    });

    testWidgets('the mobile card also hides delete for non-admins',
        (tester) async {
      await tester.pumpWidget(_host(LogPanel(
        logEntries: <EmergencyRequest>[_closedRequest()],
        onViewRequest: (_) {},
        isMobile: true,
      )));
      await tester.pump();

      expect(find.byKey(const Key('delete-log-request-91')), findsNothing);
    });

    testWidgets('the mobile card shows delete for an ADMIN', (tester) async {
      await tester.pumpWidget(_host(LogPanel(
        logEntries: <EmergencyRequest>[_closedRequest()],
        onViewRequest: (_) {},
        onDeleteEntry: (_) {},
        isMobile: true,
      )));
      await tester.pump();

      expect(find.byKey(const Key('delete-log-request-91')), findsOneWidget);
    });
  });

  group('confirmation dialog', () {
    testWidgets('cancelling deletes nothing', (tester) async {
      final recorder = _Recorder();

      await http.runWithClient(
        () async {
          await tester
              .pumpWidget(const MaterialApp(home: DispatchConsolePage()));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 200));

          final state =
              tester.state(find.byType(DispatchConsolePage)) as dynamic;
          unawaited(state.deleteLogEntry(_closedRequest()));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 200));

          expect(find.text('Delete this log entry?'), findsOneWidget);
          expect(find.textContaining('irreversible'), findsOneWidget);
          expect(
            find.textContaining('security audit trail'),
            findsOneWidget,
            reason: 'the dialog must state that the audit record is kept',
          );

          await tester.tap(find.byKey(const Key('cancel-delete-log-button')));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 200));

          expect(
            recorder.requests.where((r) => r.method == 'DELETE'),
            isEmpty,
          );

          await tester.pumpWidget(const MaterialApp(home: SizedBox()));
          await tester.pump(const Duration(milliseconds: 100));
        },
        () => MockClient((request) async {
          recorder.requests.add(request);
          return _json({'success': true});
        }),
      );
    });

    testWidgets('confirming issues the guarded DELETE exactly once',
        (tester) async {
      final recorder = _Recorder();

      await http.runWithClient(
        () async {
          await tester
              .pumpWidget(const MaterialApp(home: DispatchConsolePage()));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 200));

          final state =
              tester.state(find.byType(DispatchConsolePage)) as dynamic;
          unawaited(state.deleteLogEntry(_closedRequest()));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 200));

          await tester.tap(find.byKey(const Key('confirm-delete-log-button')));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));

          final deletes = recorder.requests
              .where((request) => request.method == 'DELETE')
              .toList();
          expect(deletes, hasLength(1));
          expect(deletes.single.url.path, '/api/admin/logs/91');
          expect(
            jsonDecode(deletes.single.body),
            <String, dynamic>{'confirm': true},
          );

          await tester.pumpWidget(const MaterialApp(home: SizedBox()));
          await tester.pump(const Duration(milliseconds: 100));
        },
        () => MockClient((request) async {
          recorder.requests.add(request);
          if (request.method == 'DELETE') {
            return _json({
              'success': true,
              'logId': 91,
              'archivedAt': '2026-10-02T05:00:00.000Z',
            });
          }
          return _json({'success': true});
        }),
      );
    });

    testWidgets('a non-admin session never opens the dialog', (tester) async {
      final recorder = _Recorder();

      await http.runWithClient(
        () async {
          ApiService.currentRole = 'REQUESTER';
          ApiService.currentUserId = 5;

          await tester
              .pumpWidget(const MaterialApp(home: DispatchConsolePage()));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 200));

          final state =
              tester.state(find.byType(DispatchConsolePage)) as dynamic;
          await state.deleteLogEntry(_closedRequest());
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 200));

          // The guard returns before any dialog or request.
          expect(find.text('Delete this log entry?'), findsNothing);
          expect(
            recorder.requests.where((r) => r.method == 'DELETE'),
            isEmpty,
          );

          await tester.pumpWidget(const MaterialApp(home: SizedBox()));
          await tester.pump(const Duration(milliseconds: 100));
        },
        () => MockClient((request) async {
          recorder.requests.add(request);
          return _json({'success': true});
        }),
      );
    });
  });
}
