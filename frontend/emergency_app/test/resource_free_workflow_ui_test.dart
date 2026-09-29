import 'package:dispatch_console_flutter/models/eras_models.dart';
import 'package:dispatch_console_flutter/widgets/allocation_dialog.dart';
import 'package:dispatch_console_flutter/widgets/board_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  EmergencyRequest resourceFreeRequest({
    required int id,
    String status = 'ACCEPTED',
    int responderId = 11,
  }) {
    return EmergencyRequest.fromJson(<String, dynamic>{
      'id': id,
      'emergencyType': 'Fire',
      'description': 'Resource-free fire emergency',
      'location': 'Thrissur, Kerala',
      'priority': 'HIGH',
      'status': status,
      'createdAt': '2026-09-29T10:00:00.000Z',
      'acceptedAt': '2026-09-29T10:05:00.000Z',
      'acceptedById': responderId,
      'requiredResources': <dynamic>[],
      'allocations': <dynamic>[],
      'acceptedBy': <String, dynamic>{
        'id': responderId,
        'name': 'Rahul Pillai',
        'responderStatus': 'BUSY',
      },
      'assignments': <dynamic>[
        <String, dynamic>{
          'id': 1,
          'requestId': id,
          'responderId': responderId,
          'status': 'ACTIVE',
          'acceptedAt': '2026-09-29T10:05:00.000Z',
          'responder': <String, dynamic>{
            'id': responderId,
            'name': 'Rahul Pillai',
            'responderStatus': 'BUSY',
          },
        },
      ],
    });
  }

  EmergencyRequest resourceBearingRequest({
    required int id,
    String status = 'ACCEPTED',
    int responderId = 11,
  }) {
    return EmergencyRequest.fromJson(<String, dynamic>{
      'id': id,
      'emergencyType': 'Medical',
      'description': 'Resource-bearing medical emergency',
      'location': 'Thrissur, Kerala',
      'priority': 'HIGH',
      'status': status,
      'createdAt': '2026-09-29T10:00:00.000Z',
      'acceptedAt': '2026-09-29T10:05:00.000Z',
      'acceptedById': responderId,
      'requiredResources': <dynamic>[
        <String, dynamic>{
          'resourceId': 4,
          'resourceName': 'Ambulance',
          'resourceType': 'Vehicle',
          'quantity': 1,
        },
      ],
      'allocations': <dynamic>[],
      'acceptedBy': <String, dynamic>{
        'id': responderId,
        'name': 'Rahul Pillai',
        'responderStatus': 'BUSY',
      },
      'assignments': <dynamic>[
        <String, dynamic>{
          'id': 1,
          'requestId': id,
          'responderId': responderId,
          'status': 'ACTIVE',
          'acceptedAt': '2026-09-29T10:05:00.000Z',
          'responder': <String, dynamic>{
            'id': responderId,
            'name': 'Rahul Pillai',
            'responderStatus': 'BUSY',
          },
        },
      ],
    });
  }

  Widget host(Widget child) => MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: SingleChildScrollView(child: child),
        ),
      );

  testWidgets(
      '15. Resource-free request shows START RESPONSE after acceptance and hides Allocate',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    var startClicked = false;
    var endAssignmentClicked = false;
    final request = resourceFreeRequest(id: 101, status: 'ACCEPTED');

    await tester.pumpWidget(host(
      BoardPanel(
        title: 'MY ACTIVE EMERGENCY',
        hint: 'Accepted by you',
        requests: <EmergencyRequest>[request],
        role: 'RESPONDER',
        currentUserId: 11,
        emptyMessage: 'None',
        onStartResponse: (_) => startClicked = true,
        onCompleteResponse: (_) {},
        onAllocate: (_) {},
        onEndAssignment: (_) => endAssignmentClicked = true,
      ),
    ));
    await tester.pump();

    expect(find.text('START RESPONSE'), findsOneWidget);
    expect(find.text('End Assignment'), findsOneWidget);
    expect(find.text('Allocate'), findsNothing);
    expect(find.text('COMPLETE RESPONSE'), findsNothing);

    await tester.tap(find.text('START RESPONSE'));
    await tester.pump();
    expect(startClicked, isTrue);

    await tester.tap(find.text('End Assignment'));
    await tester.pump();
    expect(endAssignmentClicked, isTrue);
  });

  testWidgets(
      '16. Resource-free IN_PROGRESS request shows COMPLETE RESPONSE',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    var completeClicked = false;
    final request = resourceFreeRequest(id: 102, status: 'IN_PROGRESS');

    await tester.pumpWidget(host(
      BoardPanel(
        title: 'MY ACTIVE EMERGENCY',
        hint: 'Accepted by you',
        requests: <EmergencyRequest>[request],
        role: 'RESPONDER',
        currentUserId: 11,
        emptyMessage: 'None',
        onStartResponse: (_) {},
        onCompleteResponse: (_) => completeClicked = true,
        onAllocate: (_) {},
        onEndAssignment: (_) {},
      ),
    ));
    await tester.pump();

    expect(find.text('COMPLETE RESPONSE'), findsOneWidget);
    expect(find.text('End Assignment'), findsOneWidget);
    expect(find.text('START RESPONSE'), findsNothing);
    expect(find.text('Allocate'), findsNothing);

    await tester.tap(find.text('COMPLETE RESPONSE'));
    await tester.pump();
    expect(completeClicked, isTrue);
  });

  testWidgets('17. Resource-bearing request still shows Allocate',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    var allocateClicked = false;
    final request = resourceBearingRequest(id: 103, status: 'ACCEPTED');

    await tester.pumpWidget(host(
      BoardPanel(
        title: 'MY ACTIVE EMERGENCY',
        hint: 'Accepted by you',
        requests: <EmergencyRequest>[request],
        role: 'RESPONDER',
        currentUserId: 11,
        emptyMessage: 'None',
        onStartResponse: (_) {},
        onCompleteResponse: (_) {},
        onAllocate: (_) => allocateClicked = true,
        onEndAssignment: (_) {},
      ),
    ));
    await tester.pump();

    expect(find.text('Allocate'), findsOneWidget);
    expect(find.text('End Assignment'), findsOneWidget);
    expect(find.text('START RESPONSE'), findsNothing);
    expect(find.text('COMPLETE RESPONSE'), findsNothing);

    await tester.tap(find.text('Allocate'));
    await tester.pump();
    expect(allocateClicked, isTrue);
  });

  testWidgets(
      '18. Empty AllocationDialog gracefully explains no physical resources for zero-resource request',
      (tester) async {
    final request = resourceFreeRequest(id: 104, status: 'ACCEPTED');

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AllocationDialog(
          requestId: 104,
          requestProvider: (_) => request,
          inventoryProvider: () => <BackendResponderResource>[],
          onAllocate: ({
            required int quantity,
            required int requestId,
            required int resourceId,
            required int responderResourceId,
          }) async {
            return true;
          },
          onCancelAllocation: (_) async => true,
          onDispatchAllocation: (_) async {},
          onMarkDelivered: (_) async {},
        ),
      ),
    ));
    await tester.pump();

    expect(find.textContaining('does not require physical resources'),
        findsOneWidget);
    expect(find.text('Close'), findsOneWidget);
  });
}
