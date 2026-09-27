import 'package:dispatch_console_flutter/models/eras_models.dart';
import 'package:dispatch_console_flutter/services/direct_connection_service.dart';
import 'package:dispatch_console_flutter/services/live_location_store.dart';
import 'package:dispatch_console_flutter/services/location_service.dart'
    show GeoPoint;
import 'package:dispatch_console_flutter/widgets/board_panel.dart';
import 'package:dispatch_console_flutter/widgets/operational_google_map.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _assignment(
  int id,
  int responderId,
  String name, {
  String status = 'ACTIVE',
}) =>
    <String, dynamic>{
      'id': id,
      'requestId': 700,
      'responderId': responderId,
      'status': status,
      'acceptedAt': '2026-09-27T09:00:00.000Z',
      if (status == 'ENDED') 'endedAt': '2026-09-27T10:00:00.000Z',
      'responder': <String, dynamic>{
        'id': responderId,
        'name': name,
        'phone': '555-$responderId',
        'responderStatus': status == 'ACTIVE' ? 'BUSY' : 'AVAILABLE',
      },
    };

Map<String, dynamic> _allocation(
  int id,
  int responderId,
  int resourceId,
  String resourceName, {
  String status = 'RESERVED',
}) =>
    <String, dynamic>{
      'id': id,
      'requestId': 700,
      'responderId': responderId,
      'responderResourceId': id + 100,
      'resourceId': resourceId,
      'quantity': 1,
      'status': status,
      'resource': <String, dynamic>{
        'id': resourceId,
        'name': resourceName,
      },
      'responder': <String, dynamic>{
        'id': responderId,
        'name': 'Responder $responderId',
      },
    };

EmergencyRequest _workflowRequest({
  String status = 'IN_PROGRESS',
  List<Map<String, dynamic>>? assignments,
  List<Map<String, dynamic>>? allocations,
}) =>
    EmergencyRequest.fromJson(<String, dynamic>{
      'id': 700,
      'emergencyType': 'Medical and Fire',
      'description': null,
      'location': 'Thrissur, Kerala',
      'latitude': 10.5276,
      'longitude': 76.2144,
      'priority': 'CRITICAL',
      'status': status,
      'createdAt': '2026-09-27T08:55:00.000Z',
      'acceptedAt': '2026-09-27T09:00:00.000Z',
      'acceptedById': 9,
      'acceptedBy': <String, dynamic>{
        'id': 9,
        'name': 'Blood Responder A',
        'phone': '555-9',
        'responderStatus': 'BUSY',
      },
      'requiredResources': <dynamic>[
        <String, dynamic>{
          'resourceId': 4,
          'resourceName': 'Blood',
          'quantity': 2,
        },
        <String, dynamic>{
          'resourceId': 5,
          'resourceName': 'Fire Service',
          'quantity': 1,
        },
      ],
      'assignments': assignments ??
          <Map<String, dynamic>>[
            _assignment(1, 9, 'Blood Responder A'),
            _assignment(2, 11, 'Fire Responder B'),
          ],
      'allocations': allocations ??
          <Map<String, dynamic>>[
            _allocation(101, 9, 4, 'Blood'),
            _allocation(102, 11, 5, 'Fire Service'),
          ],
    });

LiveResponderLocation _location(
  int responderId, {
  double latitude = 10.53,
  double longitude = 76.22,
}) =>
    LiveResponderLocation(
      requestId: 700,
      responderId: responderId,
      latitude: latitude,
      longitude: longitude,
      updatedAt: DateTime.utc(2026, 9, 27, 10),
    );

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: SingleChildScrollView(child: child),
      ),
    );

void main() {
  group('Phase H production contracts', () {
    test('backend snapshot parses Blood x2 + Fire SERVICE x1 and participants',
        () {
      final request = _workflowRequest();

      expect(request.requiredResources.map((row) => row.resourceName),
          <String?>['Blood', 'Fire Service']);
      expect(request.allocations.map((row) => row.responderId), <int>[9, 11]);
      expect(request.assignments.map((row) => row.responderId), <int>[9, 11]);
      expect(request.acceptedById, 9);
      expect(request.acceptedBy?.id, 9);
      expect(request.activeParticipantResponderIds, <int>{9, 11});
      expect(request.description, isNull);
    });

    test('REST and repeated socket snapshots merge idempotently', () {
      final duplicateSnapshot = EmergencyRequest.fromJson(<String, dynamic>{
        'id': 700,
        'emergencyType': 'Medical and Fire',
        'location': 'Thrissur, Kerala',
        'status': 'IN_PROGRESS',
        'priority': 'CRITICAL',
        'createdAt': '2026-09-27T08:55:00.000Z',
        'acceptedById': 9,
        'assignments': <dynamic>[
          _assignment(1, 9, 'Old A'),
          _assignment(1, 9, 'Blood Responder A'),
          _assignment(2, 11, 'Fire Responder B'),
        ],
        'allocations': <dynamic>[
          _allocation(101, 9, 4, 'Blood'),
          _allocation(101, 9, 4, 'Blood'),
          _allocation(102, 11, 5, 'Fire Service'),
        ],
        'requiredResources': <dynamic>[],
      });

      expect(duplicateSnapshot.assignments, hasLength(2));
      expect(duplicateSnapshot.assignments.first.responder?.name,
          'Blood Responder A');
      expect(duplicateSnapshot.allocations, hasLength(2));

      final repeatedAssignment = duplicateSnapshot.withAssignment(
        ResponderAssignmentLine.fromJson(_assignment(2, 11, 'Fire B updated')),
      );
      final repeatedAllocation = repeatedAssignment.withAllocation(
        AllocationLine.fromJson(_allocation(102, 11, 5, 'Fire Service')),
      );
      expect(repeatedAllocation.assignments, hasLength(2));
      expect(repeatedAllocation.allocations, hasLength(2));
    });

    test('malformed location payloads never become a zero-zero marker', () {
      expect(
        LiveResponderLocation.tryFromJson(<String, dynamic>{
          'requestId': 700,
          'responderId': 9,
          'latitude': null,
          'longitude': 76.2,
        }),
        isNull,
      );
      expect(
        LiveResponderLocation.tryFromJson(<String, dynamic>{
          'requestId': 700,
          'responderId': 9,
          'latitude': 95,
          'longitude': 76.2,
        }),
        isNull,
      );
      expect(
        LiveResponderLocation.tryFromJson(<String, dynamic>{
          'requestId': 700,
          'responderId': 9,
          'latitude': 10.5,
          'longitude': 76.2,
        }),
        isNotNull,
      );

      final store = LiveLocationStore();
      addTearDown(store.dispose);
      store.applyUpdate(_location(9, latitude: double.nan));
      expect(store.locationsForRequest(700), isEmpty);
    });

    test('assignment end removes only A; B and allocation participation remain',
        () {
      final store = LiveLocationStore()
        ..applyUpdate(_location(9))
        ..applyUpdate(_location(11, latitude: 10.54));
      addTearDown(store.dispose);

      final endedA = _workflowRequest(
        assignments: <Map<String, dynamic>>[
          _assignment(1, 9, 'Blood Responder A', status: 'ENDED'),
          _assignment(2, 11, 'Fire Responder B'),
        ],
        allocations: <Map<String, dynamic>>[
          _allocation(102, 11, 5, 'Fire Service'),
        ],
      );
      store.reconcile(<EmergencyRequest>[endedA]);

      expect(endedA.isAssignedTo(9), isFalse);
      expect(endedA.isAssignedTo(11), isTrue);
      expect(endedA.acceptedById, 9,
          reason: 'the historical first responder is never overwritten');
      expect(store.locationsForRequest(700).containsKey(9), isFalse);
      expect(store.locationsForRequest(700).containsKey(11), isTrue);
    });

    test('terminal REST reconciliation clears all responder locations', () {
      final store = LiveLocationStore()
        ..applyUpdate(_location(9))
        ..applyUpdate(_location(11));
      addTearDown(store.dispose);

      store.reconcile(<EmergencyRequest>[
        _workflowRequest(status: 'COMPLETED'),
      ]);
      expect(store.locationsForRequest(700), isEmpty);
    });

    test('0, 1, 2, and 3 responder geometry stays pair-scoped', () {
      const markerBuilder = OperationalMapMarkerBuilder();
      for (final count in <int>[0, 1, 2, 3]) {
        final assignmentRows = <Map<String, dynamic>>[
          for (var index = 0; index < count; index++)
            _assignment(index + 1, 9 + index, 'Responder ${9 + index}'),
        ];
        final request = _workflowRequest(
          status: count == 0 ? 'PENDING' : 'ACCEPTED',
          assignments: assignmentRows,
          allocations: const <Map<String, dynamic>>[],
        );
        final locations = <int, Map<int, LiveResponderLocation>>{
          700: <int, LiveResponderLocation>{
            for (var index = 0; index < count; index++)
              9 + index: _location(9 + index, latitude: 10.53 + index / 100),
          },
        };
        final markers = markerBuilder.buildSnapshots(
          requests: <EmergencyRequest>[request],
          liveLocations: locations,
        );
        final connections = selectDirectConnections(
          requests: <EmergencyRequest>[request],
          liveLocations: locations,
        );
        expect(markers, hasLength(count + 1));
        expect(connections, hasLength(count));
        expect(markers.map((marker) => marker.id).toSet(),
            hasLength(markers.length));
      }
    });

    test('directions assertions decode URI query parameters', () {
      final uri = buildGoogleMapsDirectionsUri(
        origin: const GeoPoint(10.53, 76.22),
        destination: const GeoPoint(10.5276, 76.2144),
      );
      expect(uri.queryParameters['origin'], '10.53,76.22');
      expect(uri.queryParameters['destination'], '10.5276,76.2144');
      expect(uri.queryParameters['travelmode'], 'driving');
    });
  });

  group('Phase H responsive participant UX', () {
    testWidgets('join action is offered for every open joinable lifecycle',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      for (final status in <String>[
        'PENDING',
        'ACCEPTED',
        'PARTIALLY_ALLOCATED',
        'IN_PROGRESS',
      ]) {
        await tester.pumpWidget(_host(BoardPanel(
          title: 'Compatible requests',
          hint: 'Open work',
          requests: <EmergencyRequest>[
            _workflowRequest(
              status: status,
              allocations: const <Map<String, dynamic>>[],
            ),
          ],
          role: 'RESPONDER',
          currentUserId: 99,
          emptyMessage: 'No work',
          onAccept: (_) {},
        )));
        await tester.pump();
        expect(find.text('Accept'), findsOneWidget, reason: status);
        expect(tester.takeException(), isNull, reason: status);
      }
    });

    testWidgets('ended lead, active assignment, and allocation-only owner render once',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final request = _workflowRequest(
        assignments: <Map<String, dynamic>>[
          _assignment(1, 9, 'Blood Responder A', status: 'ENDED'),
          _assignment(2, 11, 'Fire Responder B'),
        ],
        allocations: <Map<String, dynamic>>[
          _allocation(103, 13, 4, 'Blood'),
        ],
      );

      await tester.pumpWidget(_host(BoardPanel(
        title: 'Active emergencies',
        hint: 'Participants',
        requests: <EmergencyRequest>[request],
        role: 'REQUESTER',
        currentUserId: 1,
        emptyMessage: 'None',
      )));
      await tester.pump();

      expect(find.text('HISTORICAL LEAD · ENDED'), findsOneWidget);
      expect(find.text('Fire Responder B'), findsOneWidget);
      expect(find.text('Responder 13'), findsOneWidget);
      expect(find.text('ALLOCATION · ACTIVE'), findsOneWidget);
      expect(find.text('2 active responders'), findsOneWidget);
      expect(find.textContaining('LEAD · ACTIVE'), findsNothing);
    });

    testWidgets('location and end controls are isolated to the signed-in responder',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_host(BoardPanel(
        title: 'My work',
        hint: 'Responder isolation',
        requests: <EmergencyRequest>[_workflowRequest()],
        role: 'RESPONDER',
        currentUserId: 11,
        emptyMessage: 'None',
        sharingRequestId: null,
        activelySharingRequestIds: const <int>{700},
        onStartLocationSharing: (_) async {},
        onStopLocationSharing: (_) async {},
        onEndAssignment: (_) {},
      )));
      await tester.pump();

      expect(find.text('Start Live Location'), findsOneWidget,
          reason: 'another responder sharing must not show local Stop');
      expect(find.text('Stop Live Location'), findsNothing);
      expect(find.text('End Assignment'), findsOneWidget);
    });

    testWidgets('requester/responder cards fit 320/360/390 and desktop widths',
        (tester) async {
      addTearDown(tester.view.reset);
      for (final width in <double>[320, 360, 390, 1280]) {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        await tester.pumpWidget(_host(SizedBox(
          width: width,
          child: BoardPanel(
            title: 'Active emergency workflow',
            hint: 'Blood and Fire Service',
            requests: <EmergencyRequest>[_workflowRequest()],
            role: width == 1280 ? 'REQUESTER' : 'RESPONDER',
            currentUserId: width == 1280 ? 1 : 11,
            emptyMessage: 'None',
            isMobile: width < 600,
            onAllocate: (_) {},
            onEndAssignment: (_) {},
            onStartLocationSharing: (_) async {},
            onStopLocationSharing: (_) async {},
            liveLocations: <int, Map<int, LiveResponderLocation>>{
              700: <int, LiveResponderLocation>{
                9: _location(9),
                11: _location(11, latitude: 10.54),
              },
            },
          ),
        )));
        await tester.pump();
        expect(tester.takeException(), isNull,
            reason: 'layout must not overflow at $width px');
        expect(find.text('Blood Responder A'), findsWidgets);
        expect(find.text('Fire Responder B'), findsOneWidget);
      }
    });
  });
}
