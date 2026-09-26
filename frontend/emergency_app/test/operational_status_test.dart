import 'package:dispatch_console_flutter/Services/socket_service.dart';
import 'package:dispatch_console_flutter/models/eras_models.dart';
import 'package:dispatch_console_flutter/widgets/common_widgets.dart';
import 'package:dispatch_console_flutter/widgets/operational_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

EmergencyRequest _request({
  String requestStatus = 'IN_PROGRESS',
  String allocationStatus = 'DISPATCHED',
}) {
  return EmergencyRequest.fromJson(<String, dynamic>{
    'id': 71,
    'emergencyType': 'Medical',
    'description': 'Operational status test',
    'location': 'Thrissur, Kerala',
    'priority': 'HIGH',
    'status': requestStatus,
    'createdAt': '2026-09-26T09:00:00.000Z',
    'acceptedAt': '2026-09-26T09:02:00.000Z',
    'requester': <String, dynamic>{'id': 3, 'name': 'Requester'},
    'acceptedBy': <String, dynamic>{'id': 9, 'name': 'Responder'},
    'requiredResources': <dynamic>[
      <String, dynamic>{
        'resourceId': 4,
        'quantity': 2,
        'resource': <String, dynamic>{'id': 4, 'name': 'Oxygen'},
      },
    ],
    'allocations': <dynamic>[
      <String, dynamic>{
        'id': 81,
        'requestId': 71,
        'resourceId': 4,
        'responderId': 9,
        'responderResourceId': 14,
        'quantity': 2,
        'status': allocationStatus,
        'resource': <String, dynamic>{'id': 4, 'name': 'Oxygen'},
        'responder': <String, dynamic>{'id': 9, 'name': 'Responder'},
      },
    ],
  });
}

Widget _app(Widget child) => MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: Padding(padding: const EdgeInsets.all(16), child: child),
        ),
      ),
    );

void main() {
  testWidgets('request timeline shows the complete operational sequence',
      (tester) async {
    await tester.pumpWidget(_app(OperationalTimeline(request: _request())));

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

  testWidgets('allocation row shows resource quantity responder and status',
      (tester) async {
    final allocation = _request(allocationStatus: 'DELIVERED').allocations.single;
    await tester.pumpWidget(
      _app(AllocationOperationalRow(allocation: allocation)),
    );

    expect(find.text('Oxygen'), findsOneWidget);
    expect(find.text('Quantity 2'), findsOneWidget);
    expect(find.text('Responder: Responder'), findsOneWidget);
    expect(find.text('Delivered'), findsOneWidget);
  });

  testWidgets('connection indicator exposes all operational states',
      (tester) async {
    for (final entry in <(RealtimeConnectionStatus, String)>[
      (RealtimeConnectionStatus.connected, 'CONNECTED'),
      (RealtimeConnectionStatus.reconnecting, 'RECONNECTING'),
      (RealtimeConnectionStatus.offline, 'OFFLINE'),
    ]) {
      await tester.pumpWidget(
        _app(ConnectionStatusIndicator(status: entry.$1)),
      );
      expect(find.text(entry.$2), findsOneWidget);
    }
  });

  testWidgets('responder availability uses backend status and unfinished count',
      (tester) async {
    const responder = BackendResponder(
      id: 9,
      name: 'Responder',
      email: 'responder@test.com',
      status: 'BUSY',
    );
    await tester.pumpWidget(
      _app(const ResponderAvailabilityBanner(
        responder: responder,
        unfinishedAllocations: 2,
      )),
    );

    expect(find.text('BUSY'), findsOneWidget);
    expect(find.text('2 unfinished allocations'), findsOneWidget);
  });
}
