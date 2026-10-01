import 'package:dispatch_console_flutter/models/eras_models.dart';
import 'package:dispatch_console_flutter/widgets/board_panel.dart';
import 'package:dispatch_console_flutter/widgets/operational_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Resource-bearing emergencies follow the SAME normal responder workflow as
/// resource-free ones:
///
///   Accept -> START RESPONSE -> COMPLETE RESPONSE
///
/// The legacy Allocate / Dispatch / Delivered controls are never part of that
/// workflow. These tests build the board exactly as the responder console
/// does (no legacy allocation callbacks wired).
void main() {
  const responderId = 11;

  Map<String, dynamic> responderJson() => <String, dynamic>{
        'id': responderId,
        'name': 'Rahul Pillai',
        'responderStatus': 'BUSY',
      };

  EmergencyRequest resourceBearingRequest({
    required int id,
    String status = 'ACCEPTED',
    List<Map<String, dynamic>> allocations = const <Map<String, dynamic>>[],
  }) {
    return EmergencyRequest.fromJson(<String, dynamic>{
      'id': id,
      'emergencyType': 'Medical Emergency',
      'description': 'Road accident with multiple injuries',
      'location': 'Thrissur, Kerala',
      'priority': 'HIGH',
      'status': status,
      'createdAt': '2026-09-29T10:00:00.000Z',
      'acceptedAt': '2026-09-29T10:05:00.000Z',
      'acceptedById': responderId,
      'requiredResources': <dynamic>[
        <String, dynamic>{
          'resourceId': 4,
          'resourceName': 'Blood',
          'resourceType': 'Blood',
          'quantity': 2,
        },
        <String, dynamic>{
          'resourceId': 7,
          'resourceName': 'First Aid Kit',
          'resourceType': 'First Aid Kit',
          'quantity': 1,
        },
      ],
      'allocations': allocations,
      'acceptedBy': responderJson(),
      'assignments': <dynamic>[
        <String, dynamic>{
          'id': 1,
          'requestId': id,
          'responderId': responderId,
          'status': 'ACTIVE',
          'acceptedAt': '2026-09-29T10:05:00.000Z',
          'responder': responderJson(),
        },
      ],
    });
  }

  /// The responder "MY ACTIVE EMERGENCY" board as the console wires it: the
  /// normal workflow callbacks only, never the legacy allocation hooks.
  Widget responderBoard(
    EmergencyRequest request, {
    void Function(EmergencyRequest request)? onStartResponse,
    void Function(EmergencyRequest request)? onCompleteResponse,
    int? sharingRequestId,
    bool isMobile = false,
  }) {
    return MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: SingleChildScrollView(
          child: BoardPanel(
            title: 'MY ACTIVE EMERGENCY',
            hint: 'Accepted by you',
            requests: <EmergencyRequest>[request],
            role: 'RESPONDER',
            currentUserId: responderId,
            emptyMessage: 'None',
            onStartResponse: onStartResponse ?? (_) {},
            onCompleteResponse: onCompleteResponse ?? (_) {},
            onEndAssignment: (_) {},
            onStartLocationSharing: (_) async {},
            onStopLocationSharing: (_) async {},
            sharingRequestId: sharingRequestId,
            isMobile: isMobile,
          ),
        ),
      ),
    );
  }

  void expectNoLegacyAllocationControls() {
    expect(find.text('Allocate'), findsNothing);
    expect(find.textContaining('Confirm & Dispatch'), findsNothing);
    expect(find.textContaining('Mark Delivered'), findsNothing);
    expect(find.textContaining('Confirm received'), findsNothing);
  }

  testWidgets(
      'Start Response is visible on an ACCEPTED resource-bearing request',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    var startedId = 0;
    final request = resourceBearingRequest(id: 201, status: 'ACCEPTED');

    await tester.pumpWidget(responderBoard(
      request,
      onStartResponse: (r) => startedId = r.id,
    ));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('START RESPONSE'), findsOneWidget);
    expect(find.text('COMPLETE RESPONSE'), findsNothing);
    expect(find.text('End Assignment'), findsOneWidget);
    expectNoLegacyAllocationControls();

    final startButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'START RESPONSE'),
    );
    startButton.onPressed!();
    await tester.pump();
    expect(startedId, 201);
  });

  testWidgets(
      'Request card lists the requested resources clearly (Blood × 2, First Aid Kit × 1)',
      (tester) async {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final request = resourceBearingRequest(id: 202, status: 'ACCEPTED');

    await tester.pumpWidget(responderBoard(request, isMobile: true));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Medical Emergency'), findsWidgets);
    expect(find.text('HIGH'), findsOneWidget);
    expect(find.text('REQUIRED RESOURCES'), findsOneWidget);
    expect(find.text('Blood × 2'), findsOneWidget);
    expect(find.text('First Aid Kit × 1'), findsOneWidget);
    expect(find.text('START RESPONSE'), findsOneWidget);
    expectNoLegacyAllocationControls();
  });

  testWidgets(
      'Complete Response is visible on an IN_PROGRESS resource-bearing request with location sharing state',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    var completedId = 0;
    final request = resourceBearingRequest(id: 203, status: 'IN_PROGRESS');

    // Not sharing from this device -> OFF.
    await tester.pumpWidget(responderBoard(
      request,
      onCompleteResponse: (r) => completedId = r.id,
    ));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('IN PROGRESS'), findsWidgets);
    expect(find.text('COMPLETE RESPONSE'), findsOneWidget);
    expect(find.text('START RESPONSE'), findsNothing);
    expect(find.text('Location sharing: OFF'), findsOneWidget);
    expect(find.text('Start Live Location'), findsOneWidget);
    expectNoLegacyAllocationControls();

    final completeButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'COMPLETE RESPONSE'),
    );
    completeButton.onPressed!();
    await tester.pump();
    expect(completedId, 203);

    // Sharing from this device -> ON.
    await tester.pumpWidget(responderBoard(
      request,
      onCompleteResponse: (r) => completedId = r.id,
      sharingRequestId: 203,
    ));
    await tester.pump();

    expect(find.text('Location sharing: ON'), findsOneWidget);
    expect(find.text('Stop Live Location'), findsOneWidget);
    expect(find.text('COMPLETE RESPONSE'), findsOneWidget);
  });

  testWidgets(
      'Allocate / Dispatch / Delivered are absent from the normal responder workflow even with legacy allocation rows',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final request = resourceBearingRequest(
      id: 204,
      status: 'IN_PROGRESS',
      allocations: <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 901,
          'requestId': 204,
          'resourceId': 4,
          'responderId': responderId,
          'responderResourceId': 70,
          'quantity': 1,
          'status': 'RESERVED',
          'resource': <String, dynamic>{'id': 4, 'name': 'Blood'},
          'responder': responderJson(),
        },
        <String, dynamic>{
          'id': 902,
          'requestId': 204,
          'resourceId': 7,
          'responderId': responderId,
          'responderResourceId': 71,
          'quantity': 1,
          'status': 'DISPATCHED',
          'resource': <String, dynamic>{'id': 7, 'name': 'First Aid Kit'},
          'responder': responderJson(),
        },
      ],
    );

    await tester.pumpWidget(responderBoard(request));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('COMPLETE RESPONSE'), findsOneWidget);
    expectNoLegacyAllocationControls();
  });

  testWidgets(
      'After completion the request is closed: no responder workflow controls remain',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final completed = EmergencyRequest.fromJson(<String, dynamic>{
      'id': 205,
      'emergencyType': 'Medical Emergency',
      'location': 'Thrissur, Kerala',
      'priority': 'HIGH',
      'status': 'COMPLETED',
      'createdAt': '2026-09-29T10:00:00.000Z',
      'acceptedAt': '2026-09-29T10:05:00.000Z',
      'acceptedById': responderId,
      'requiredResources': <dynamic>[
        <String, dynamic>{
          'resourceId': 4,
          'resourceName': 'Blood',
          'resourceType': 'Blood',
          'quantity': 2,
        },
      ],
      'allocations': <dynamic>[],
      'acceptedBy': <String, dynamic>{
        'id': responderId,
        'name': 'Rahul Pillai',
        'responderStatus': 'AVAILABLE',
      },
      'assignments': <dynamic>[
        <String, dynamic>{
          'id': 1,
          'requestId': 205,
          'responderId': responderId,
          'status': 'ENDED',
          'acceptedAt': '2026-09-29T10:05:00.000Z',
          'endedAt': '2026-09-29T10:45:00.000Z',
          'responder': <String, dynamic>{
            'id': responderId,
            'name': 'Rahul Pillai',
            'responderStatus': 'AVAILABLE',
          },
        },
      ],
    });

    await tester.pumpWidget(responderBoard(completed));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('COMPLETED'), findsWidgets);
    expect(find.text('START RESPONSE'), findsNothing);
    expect(find.text('COMPLETE RESPONSE'), findsNothing);
    expect(find.text('Start Live Location'), findsNothing);
    expect(find.text('Location sharing: ON'), findsNothing);
    expect(find.text('Location sharing: OFF'), findsNothing);
    // Requested resources remain visible in history.
    expect(find.text('Blood × 2'), findsOneWidget);
    expectNoLegacyAllocationControls();
  });

  testWidgets(
      'Lifecycle timeline is PENDING -> ACCEPTED -> IN PROGRESS -> COMPLETED for a resource-bearing request',
      (tester) async {
    final request = resourceBearingRequest(id: 206, status: 'IN_PROGRESS');

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: OperationalTimeline(request: request)),
    ));
    await tester.pump();

    for (final label in <String>[
      'PENDING',
      'ACCEPTED',
      'IN PROGRESS',
      'COMPLETED',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    for (final label in <String>['ALLOCATED', 'DISPATCHED', 'DELIVERED']) {
      expect(find.text(label), findsNothing);
    }
  });
}
