import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dispatch_console_flutter/Services/socket_service.dart';
import 'package:dispatch_console_flutter/models/eras_models.dart';
import 'package:dispatch_console_flutter/widgets/request_timeline.dart';
import 'package:dispatch_console_flutter/widgets/responder_status_panel.dart';

Map<String, dynamic> allocationJson({
  int id = 1,
  String status = 'RESERVED',
  int responderId = 42,
}) {
  return <String, dynamic>{
    'id': id,
    'requestId': 1,
    'resourceId': 3,
    'responderId': responderId,
    'responderResourceId': 5,
    'quantity': 2,
    'status': status,
    'resource': <String, dynamic>{'id': 3, 'name': 'Ambulance', 'type': 'Medical'},
    'responder': <String, dynamic>{'id': responderId, 'name': 'Responder One'},
  };
}

EmergencyRequest buildRequest({
  String status = 'IN_PROGRESS',
  List<Map<String, dynamic>> allocations = const <Map<String, dynamic>>[],
  bool accepted = true,
}) {
  return EmergencyRequest.fromJson(<String, dynamic>{
    'id': 1,
    'emergencyType': 'Medical',
    'description': 'Test emergency',
    'location': 'Old Town',
    'priority': 'HIGH',
    'status': status,
    'createdAt': '2026-09-26T10:00:00.000Z',
    'requester': <String, dynamic>{'id': 900, 'name': 'Requester'},
    'acceptedBy': accepted
        ? <String, dynamic>{
            'id': 42,
            'name': 'Responder One',
            'latitude': 10.5,
            'longitude': 76.2,
          }
        : null,
    'requiredResources': const <Map<String, dynamic>>[],
    'allocations': allocations,
  });
}

Widget wrap(Widget child) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  testWidgets('the requester timeline shows the full operational path',
      (tester) async {
    await tester.pumpWidget(
      wrap(
        RequestTimeline(
          request: buildRequest(
            allocations: <Map<String, dynamic>>[
              allocationJson(status: 'DISPATCHED'),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    for (final label in <String>[
      'PENDING',
      'ACCEPTED',
      'ALLOCATED',
      'DISPATCHED',
      'DELIVERED',
      'COMPLETED',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
  });

  testWidgets('DISPATCHED offers Confirm Received to the requester',
      (tester) async {
    AllocationLine? confirmed;

    await tester.pumpWidget(
      wrap(
        AllocationProgressList(
          request: buildRequest(
            allocations: <Map<String, dynamic>>[
              allocationJson(status: 'DISPATCHED'),
            ],
          ),
          onConfirmReceipt: (allocation) => confirmed = allocation,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Ambulance × 2'), findsOneWidget);
    expect(find.text('Responder: Responder One'), findsOneWidget);
    expect(find.text('DISPATCHED'), findsOneWidget);

    await tester.tap(find.text('Confirm Received'));
    await tester.pump();

    expect(confirmed, isNotNull);
    expect(confirmed!.id, 1);
  });

  testWidgets('DELIVERED shows the delivered marker and no requester action',
      (tester) async {
    await tester.pumpWidget(
      wrap(
        AllocationProgressList(
          request: buildRequest(
            allocations: <Map<String, dynamic>>[
              allocationJson(status: 'DELIVERED'),
            ],
          ),
          onConfirmReceipt: (_) {},
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Delivered'), findsOneWidget);
    expect(find.text('Confirm Received'), findsNothing);
  });

  testWidgets('the responder sees Confirm & Dispatch then Mark Delivered',
      (tester) async {
    await tester.pumpWidget(
      wrap(
        AllocationProgressList(
          request: buildRequest(
            allocations: <Map<String, dynamic>>[allocationJson()],
          ),
          currentUserId: 42,
          isResponderView: true,
          onDispatch: (_) {},
          onMarkDelivered: (_) {},
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Confirm & Dispatch'), findsOneWidget);
    expect(find.text('Mark Delivered'), findsNothing);

    await tester.pumpWidget(
      wrap(
        AllocationProgressList(
          request: buildRequest(
            allocations: <Map<String, dynamic>>[
              allocationJson(status: 'DISPATCHED'),
            ],
          ),
          currentUserId: 42,
          isResponderView: true,
          onDispatch: (_) {},
          onMarkDelivered: (_) {},
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Mark Delivered'), findsOneWidget);
    expect(find.text('Confirm & Dispatch'), findsNothing);
  });

  testWidgets('another responder allocation offers no action', (tester) async {
    await tester.pumpWidget(
      wrap(
        AllocationProgressList(
          request: buildRequest(
            allocations: <Map<String, dynamic>>[
              allocationJson(status: 'RESERVED', responderId: 77),
            ],
          ),
          currentUserId: 42,
          isResponderView: true,
          onDispatch: (_) {},
          onMarkDelivered: (_) {},
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Confirm & Dispatch'), findsNothing);
  });

  group('Location sharing controls', () {
    testWidgets('offers Start Live Location for an assigned open emergency',
        (tester) async {
      var started = 0;

      await tester.pumpWidget(
        wrap(
          LocationSharingPanel(
            requests: <EmergencyRequest>[buildRequest()],
            currentUserId: 42,
            sharingRequestId: null,
            liveLocations: const <int, LiveResponderLocation>{},
            connection:
                const SocketConnectionState(status: RealtimeStatus.connected),
            onStart: (_) async => started++,
            onStop: (_) async {},
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Start Live Location'), findsOneWidget);
      expect(find.text('Stop Live Location'), findsNothing);

      await tester.tap(find.text('Start Live Location'));
      await tester.pump();
      expect(started, 1);
    });

    testWidgets('while sharing it offers Stop and shows the last update',
        (tester) async {
      await tester.pumpWidget(
        wrap(
          LocationSharingPanel(
            requests: <EmergencyRequest>[buildRequest()],
            currentUserId: 42,
            sharingRequestId: 1,
            liveLocations: <int, LiveResponderLocation>{
              1: LiveResponderLocation(
                requestId: 1,
                responderId: 42,
                latitude: 10.5,
                longitude: 76.2,
                updatedAt: DateTime.now(),
              ),
            },
            connection:
                const SocketConnectionState(status: RealtimeStatus.connected),
            onStart: (_) async {},
            onStop: (_) async {},
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Stop Live Location'), findsOneWidget);
      expect(find.text('SHARING'), findsOneWidget);
      expect(find.textContaining('Live position'), findsOneWidget);
    });

    testWidgets('a degraded connection is surfaced while sharing',
        (tester) async {
      await tester.pumpWidget(
        wrap(
          LocationSharingPanel(
            requests: <EmergencyRequest>[buildRequest()],
            currentUserId: 42,
            sharingRequestId: 1,
            liveLocations: const <int, LiveResponderLocation>{},
            connection: SocketConnectionState.offline,
            onStart: (_) async {},
            onStop: (_) async {},
          ),
        ),
      );
      await tester.pump();

      expect(find.textContaining('paused'), findsOneWidget);
      expect(find.text('OFFLINE'), findsOneWidget);
    });

    testWidgets('a closed emergency offers no location controls',
        (tester) async {
      await tester.pumpWidget(
        wrap(
          LocationSharingPanel(
            requests: <EmergencyRequest>[buildRequest(status: 'COMPLETED')],
            currentUserId: 42,
            sharingRequestId: null,
            liveLocations: const <int, LiveResponderLocation>{},
            connection:
                const SocketConnectionState(status: RealtimeStatus.connected),
            onStart: (_) async {},
            onStop: (_) async {},
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Start Live Location'), findsNothing);
      expect(
        find.textContaining('Accept an emergency'),
        findsOneWidget,
      );
    });
  });
}
