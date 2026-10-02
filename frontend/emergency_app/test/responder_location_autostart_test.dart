/// Automatic live-location sharing after a successful ACCEPT.
///
/// Requirements locked down here:
///   * accepting starts sharing for the accepting responder and device,
///   * a denied location permission must NEVER roll the acceptance back (no
///     cancel/unassign call is issued and the request stays accepted),
///   * a reconnecting / offline realtime connection is equally harmless,
///   * the same request is never shared twice (no second watcher),
///   * the automatic path is silent: it does not nag with the guidance toast
///     that the manual button shows,
///   * a source guard proves the wiring lives in the accept path (the console
///     itself cannot be driven end-to-end for this without a live socket).
library;

import 'dart:convert';
import 'dart:io';

import 'package:dispatch_console_flutter/models/eras_models.dart';
import 'package:dispatch_console_flutter/screens/dispatch_console_page.dart';
import 'package:dispatch_console_flutter/services/api_service.dart';
import 'package:dispatch_console_flutter/services/location_service.dart';
import 'package:dispatch_console_flutter/services/socket_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const grantedPermission = LocationPermissionResult(
  status: LocationPermissionStatus.granted,
  message: 'Location permission granted.',
);

const deniedPermission = LocationPermissionResult(
  status: LocationPermissionStatus.denied,
  message: 'Location permission was not granted.',
);

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

EmergencyRequest _request({String status = 'PENDING', int responderId = 9}) {
  return EmergencyRequest.fromJson(<String, dynamic>{
    'id': 77,
    'emergencyType': 'Medical',
    'description': 'Auto location test',
    'location': 'Thrissur, Kerala',
    'priority': 'HIGH',
    'status': status,
    'createdAt': '2026-10-02T09:00:00.000Z',
    'updatedAt': '2026-10-02T09:05:00.000Z',
    if (status != 'PENDING') 'acceptedAt': '2026-10-02T09:02:00.000Z',
    if (status != 'PENDING')
      'acceptedBy': <String, dynamic>{
        'id': responderId,
        'name': 'Responder $responderId',
        'responderStatus': 'BUSY',
      },
    if (status != 'PENDING')
      'assignments': <dynamic>[
        <String, dynamic>{
          'id': 3,
          'requestId': 77,
          'responderId': responderId,
          'status': 'ACTIVE',
          'acceptedAt': '2026-10-02T09:02:00.000Z',
          'responder': <String, dynamic>{
            'id': responderId,
            'name': 'Responder $responderId',
          },
        },
      ],
    'requiredResources': <dynamic>[],
    'allocations': <dynamic>[],
  });
}

class _Recorder {
  final List<http.Request> requests = <http.Request>[];

  List<String> get mutationPaths => requests
      .where((request) => request.method != 'GET')
      .map((request) => '${request.method} ${request.url.path}')
      .toList();
}

MockClient _acceptBackend(_Recorder recorder, {String status = 'ACCEPTED'}) {
  return MockClient((request) async {
    recorder.requests.add(request);

    if (request.url.path == '/api/responders/accept' ||
        request.url.path.endsWith('/accept')) {
      return _json({
        'success': true,
        'request': <String, dynamic>{
          'id': 77,
          'emergencyType': 'Medical',
          'location': 'Thrissur, Kerala',
          'priority': 'HIGH',
          'status': status,
          'createdAt': '2026-10-02T09:00:00.000Z',
          'acceptedAt': '2026-10-02T09:02:00.000Z',
          'acceptedById': 9,
          'acceptedBy': <String, dynamic>{
            'id': 9,
            'name': 'Responder 9',
            'responderStatus': 'BUSY',
          },
          'requiredResources': <dynamic>[],
          'allocations': <dynamic>[],
          'assignments': <dynamic>[],
        },
      });
    }

    // Any other endpoint answers as an empty database would.
    return _json({'success': true});
  });
}

void _resetApiState() {
  ApiService.token = 'session-token';
  ApiService.currentRole = 'RESPONDER';
  ApiService.currentUserId = 9;
  ApiService.currentUserName = 'Responder 9';
}

Future<void> _disposePage(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  setUpAll(SocketService.instance.dispose);
  setUp(_resetApiState);
  tearDown(() {
    ApiService.token = null;
    ApiService.currentRole = null;
    ApiService.currentUserId = null;
    ApiService.currentUserName = null;
  });

  testWidgets(
      'accepting without location permission never rolls back the '
      'acceptance', (tester) async {
    final recorder = _Recorder();

    await http.runWithClient(
      () async {
        await tester.pumpWidget(
          MaterialApp(
            home: DispatchConsolePage(
              checkLocationPermission: () async => deniedPermission,
              requestLocationPermission: () async => deniedPermission,
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        final state = tester.state(find.byType(DispatchConsolePage)) as dynamic;
        await state.acceptRequest(_request());
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        // The acceptance itself happened exactly once...
        expect(
          recorder.requests
              .where((request) => request.url.path.endsWith('/accept')),
          hasLength(1),
        );

        // ...and nothing rolled it back: no cancel, no unassign, no end
        // assignment, no delete was issued because of the denied permission.
        for (final path in recorder.mutationPaths) {
          expect(path, isNot(contains('/cancel')));
          expect(path, isNot(contains('end')));
          expect(path, isNot(contains('DELETE')));
        }

        expect(tester.takeException(), isNull);
        await _disposePage(tester);
      },
      () => _acceptBackend(recorder),
    );
  });

  testWidgets(
      'a granted permission with an offline realtime service is also '
      'harmless', (tester) async {
    final recorder = _Recorder();

    await http.runWithClient(
      () async {
        await tester.pumpWidget(
          MaterialApp(
            home: DispatchConsolePage(
              checkLocationPermission: () async => grantedPermission,
              requestLocationPermission: () async => grantedPermission,
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        final state = tester.state(find.byType(DispatchConsolePage)) as dynamic;
        await state.acceptRequest(_request());
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(
          recorder.requests
              .where((request) => request.url.path.endsWith('/accept')),
          hasLength(1),
        );
        expect(tester.takeException(), isNull);
        await _disposePage(tester);
      },
      () => _acceptBackend(recorder),
    );
  });

  testWidgets('the automatic path is silent, the manual one guides',
      (tester) async {
    // A quiet backend: the console's bootstrap loads all succeed, so the only
    // snack bar in play is the one this test is about (SnackBars queue, and a
    // startup failure toast would hide it).
    await http.runWithClient(
      () async {
        await tester.pumpWidget(
          MaterialApp(
            home: DispatchConsolePage(
              checkLocationPermission: () async => grantedPermission,
              requestLocationPermission: () async => grantedPermission,
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        final state =
            tester.state(find.byType(DispatchConsolePage)) as dynamic;

        // Manual: a PENDING request the responder does not participate in gets
        // an explanation.
        await state.startLocationSharing(_request());
        await tester.pump();
        expect(
          find.textContaining('Live location is available after'),
          findsOneWidget,
        );

        // Automatic (right after ACCEPT): same ineligible request, no nagging -
        // the acceptance already stands and must not be framed as an error.
        await state.startLocationSharing(_request(), automatic: true);
        await tester.pump();
        expect(
          find.textContaining('Live location is available after'),
          findsOneWidget,
        ); // still only the toast from the manual call above

        await _disposePage(tester);
      },
      () => MockClient((request) async => _json({'success': true})),
    );
  });

  testWidgets('an ACCEPTED participation passes the eligibility gate',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DispatchConsolePage(
          checkLocationPermission: () async => grantedPermission,
          requestLocationPermission: () async => grantedPermission,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final state = tester.state(find.byType(DispatchConsolePage)) as dynamic;
    final accepted = _request(status: 'ACCEPTED');

    // The bootstrap read only needs to prove the status guard accepts ACCEPTED
    // (the realtime service is offline in this test, so sharing itself stops at
    // the connection check - by design).
    await state.startLocationSharing(accepted);
    await tester.pump();

    expect(
      find.textContaining('available after an assigned responder starts'),
      findsNothing,
      reason: 'ACCEPTED is an eligible status for sharing',
    );

    // Trying again for the same request must not open a second watcher.
    await state.startLocationSharing(accepted, automatic: true);
    await tester.pump();
    expect(tester.takeException(), isNull);

    await _disposePage(tester);
  });

  group('wiring guard', () {
    test('acceptRequest starts sharing after a successful accept', () {
      final source =
          File('lib/screens/dispatch_console_page.dart').readAsStringSync();

      final acceptStart = source
          .indexOf('Future<void> acceptRequest(EmergencyRequest request)');
      expect(acceptStart, greaterThan(-1));

      final autoStart = source.indexOf(
          '_autoStartLiveLocationSharing(request.id)', acceptStart);
      expect(autoStart, greaterThan(acceptStart));

      final acceptEnd = source.indexOf('\n  Future<void>', autoStart);
      expect(acceptEnd, greaterThan(autoStart));
      // The call sits inside the guard that only runs after a SUCCESSFUL
      // accept, never on a failed one. The guard opens BEFORE the call, so the
      // check starts at the guard itself.
      final guard = source.lastIndexOf('if (accepted)', autoStart);
      expect(guard, greaterThan(acceptStart));
      final region = source.substring(guard, acceptEnd);
      expect(region, contains('_autoStartLiveLocationSharing(request.id)'));
    });

    test('the automatic start is de-duplicated per request', () {
      final source =
          File('lib/screens/dispatch_console_page.dart').readAsStringSync();
      final helper =
          source.indexOf('Future<void> _autoStartLiveLocationSharing(');
      expect(helper, greaterThan(-1));

      final region = source.substring(helper, helper + 700);
      expect(
        region,
        contains('locationStore.localSharingRequestId == requestId'),
      );
      expect(region, contains('_locationStartInProgress'));
      expect(region, contains('participatesAsResponder'));
    });
  });
}
