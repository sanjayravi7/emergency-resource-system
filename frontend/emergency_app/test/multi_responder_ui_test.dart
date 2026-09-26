import 'package:dispatch_console_flutter/Services/location_service.dart'
    show GeoPoint;
import 'package:dispatch_console_flutter/Services/socket_service.dart';
import 'package:dispatch_console_flutter/models/eras_models.dart';
import 'package:dispatch_console_flutter/services/direct_connection_service.dart';
import 'package:dispatch_console_flutter/widgets/board_panel.dart';
import 'package:dispatch_console_flutter/widgets/operational_google_map.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// PHASE F multi-responder UI tests (requester + responder surfaces).
void main() {
  // A realistic multi-responder snapshot: lead 9, additional ACTIVE 11,
  // ENDED 12 (history only).
  EmergencyRequest multiRequest({String status = 'IN_PROGRESS'}) {
    return EmergencyRequest.fromJson(<String, dynamic>{
      'id': 42,
      'emergencyType': 'Medical',
      'description': 'Multi responder UI test',
      'location': 'Thrissur, Kerala',
      'priority': 'HIGH',
      'status': status,
      'createdAt': '2026-09-26T09:00:00.000Z',
      'updatedAt': '2026-09-26T10:00:00.000Z',
      'acceptedAt': '2026-09-26T09:05:00.000Z',
      'requiredResources': <dynamic>[
        <String, dynamic>{
          'resourceId': 4,
          'resourceName': 'Blood',
          'quantity': 5,
        },
      ],
      'allocations': <dynamic>[],
      'acceptedBy': <String, dynamic>{
        'id': 9,
        'name': 'Asha Menon',
        'phone': '555-0101',
      },
      'assignments': <dynamic>[
        <String, dynamic>{
          'id': 1,
          'requestId': 42,
          'responderId': 9,
          'status': 'ACTIVE',
          'acceptedAt': '2026-09-26T09:05:00.000Z',
          'responder': <String, dynamic>{
            'id': 9,
            'name': 'Asha Menon',
            'phone': '555-0101',
          },
        },
        <String, dynamic>{
          'id': 2,
          'requestId': 42,
          'responderId': 11,
          'status': 'ACTIVE',
          'acceptedAt': '2026-09-26T09:20:00.000Z',
          'responder': <String, dynamic>{
            'id': 11,
            'name': 'Rahul Pillai',
            'phone': '555-0102',
          },
        },
        <String, dynamic>{
          'id': 3,
          'requestId': 42,
          'responderId': 12,
          'status': 'ENDED',
          'acceptedAt': '2026-09-26T09:25:00.000Z',
          'endedAt': '2026-09-26T10:40:00.000Z',
          'responder': <String, dynamic>{
            'id': 12,
            'name': 'Former Responder',
          },
        },
      ],
    });
  }

  Widget host(Widget child) => MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: child,
        ),
      );

  // Phase F case 25 --------------------------------------------------------
  testWidgets('requester board shows lead and additional responders',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host(
      SingleChildScrollView(
        child: BoardPanel(
          title: 'Active emergencies',
          hint: 'Requests being handled',
          requests: <EmergencyRequest>[multiRequest()],
          role: 'REQUESTER',
          currentUserId: 5,
          emptyMessage: 'No active emergencies',
        ),
      ),
    ));
    await tester.pump();

    expect(tester.takeException(), isNull);

    // Lead is labelled through the preserved acceptedBy semantics.
    expect(find.text('Asha Menon'), findsWidgets);
    expect(find.textContaining('LEAD · ACTIVE'), findsOneWidget);
    // The additional ACTIVE assignment is visible with contact details.
    expect(find.text('Rahul Pillai'), findsOneWidget);
    expect(find.textContaining('ASSIGNED · ACTIVE'), findsOneWidget);
    expect(find.text('555-0102'), findsOneWidget);
    // The ENDED assignment is history and never renders as active work.
    expect(find.text('Former Responder'), findsNothing);
  });

  // Phase F case 26 --------------------------------------------------------
  testWidgets('an additional assigned responder gets the allocation actions',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host(
      SingleChildScrollView(
        child: BoardPanel(
          title: 'My assignments',
          hint: 'Emergencies you are assigned to',
          requests: <EmergencyRequest>[multiRequest()],
          role: 'RESPONDER',
          // Rahul Pillai (id 11) is the ADDITIONAL responder, not the lead.
          currentUserId: 11,
          emptyMessage: 'No assignments',
          onAllocate: (_) {},
          onStartLocationSharing: (_) async {},
          onStopLocationSharing: (_) async {},
        ),
      ),
    ));
    await tester.pump();

    expect(tester.takeException(), isNull);
    // Part 7 gate A/B: participates via ACTIVE assignment -> may allocate
    // and share location, even though acceptedBy is somebody else.
    expect(find.text('Allocate'), findsOneWidget);
    expect(find.textContaining('Share Live Location'), findsOneWidget);
  });

  testWidgets('an ENDED-only responder gets no responder actions',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host(
      SingleChildScrollView(
        child: BoardPanel(
          title: 'My assignments',
          hint: 'Emergencies you are assigned to',
          requests: <EmergencyRequest>[multiRequest()],
          role: 'RESPONDER',
          currentUserId: 12, // only an ENDED assignment
          emptyMessage: 'No assignments',
          onAllocate: (_) {},
          onStartLocationSharing: (_) async {},
          onStopLocationSharing: (_) async {},
        ),
      ),
    ));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Allocate'), findsNothing);
    expect(find.textContaining('Share Live Location'), findsNothing);
  });

  // Phase F case 27 --------------------------------------------------------
  testWidgets('an allocation-only responder drives their own allocation',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final request = EmergencyRequest.fromJson(<String, dynamic>{
      'id': 43,
      'emergencyType': 'Medical',
      'location': 'Thrissur, Kerala',
      'priority': 'HIGH',
      'status': 'IN_PROGRESS',
      'createdAt': '2026-09-26T09:00:00.000Z',
      'requiredResources': <dynamic>[],
      // No assignments at all: participation comes only from the
      // RESERVED allocation (Phase B decision: allocation does not
      // require an assignment).
      'assignments': <dynamic>[],
      'allocations': <dynamic>[
        <String, dynamic>{
          'id': 9001,
          'requestId': 43,
          'resourceId': 4,
          'responderId': 11,
          'responderResourceId': 7,
          'quantity': 2,
          'status': 'RESERVED',
          'resource': <String, dynamic>{'id': 4, 'name': 'Blood'},
          'responder': <String, dynamic>{'id': 11, 'name': 'Rahul Pillai'},
        },
      ],
    });

    await tester.pumpWidget(host(
      SingleChildScrollView(
        child: BoardPanel(
          title: 'My work',
          hint: 'Allocation ownership drives actions',
          requests: <EmergencyRequest>[request],
          role: 'RESPONDER',
          currentUserId: 11,
          emptyMessage: 'No work',
          onAllocate: (_) {},
          onDispatchAllocation: (_) {},
          onMarkDelivered: (_) {},
          onStartLocationSharing: (_) async {},
          onStopLocationSharing: (_) async {},
        ),
      ),
    ));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('Confirm & Dispatch · Blood'), findsOneWidget);
    expect(find.textContaining('Share Live Location'), findsOneWidget);
  });

  // Phase F case 28 --------------------------------------------------------
  testWidgets('mobile board renders a multi-responder card without overflow',
      (tester) async {
    addTearDown(tester.view.reset);

    for (final width in <double>[320, 360, 390]) {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;

      await tester.pumpWidget(host(
        SingleChildScrollView(
          child: SizedBox(
            width: width,
            child: BoardPanel(
              title: 'My assignments',
              hint: 'Multi responder card',
              requests: <EmergencyRequest>[multiRequest()],
              role: 'RESPONDER',
              currentUserId: 9,
              emptyMessage: 'No assignments',
              isMobile: true,
              onAllocate: (_) {},
              onStartLocationSharing: (_) async {},
              onStopLocationSharing: (_) async {},
              liveLocations: <int, Map<int, LiveResponderLocation>>{
                42: <int, LiveResponderLocation>{
                  9: LiveResponderLocation(
                    requestId: 42,
                    responderId: 9,
                    latitude: 10.53111,
                    longitude: 76.22111,
                    updatedAt: DateTime.utc(2026, 9, 26, 10),
                  ),
                  11: LiveResponderLocation(
                    requestId: 42,
                    responderId: 11,
                    latitude: 10.53222,
                    longitude: 76.22222,
                    updatedAt: DateTime.utc(2026, 9, 26, 10),
                    isLive: false,
                  ),
                },
              },
            ),
          ),
        ),
      ));
      await tester.pump();

      expect(tester.takeException(), isNull,
          reason: 'no overflow at width $width');
      expect(find.text('Asha Menon'), findsOneWidget);
      expect(find.text('Rahul Pillai'), findsOneWidget);
      // Per-responder location rows are labelled with the responder name.
      expect(find.textContaining('LOCATION SHARING ACTIVE · Asha Menon'),
          findsOneWidget);
      expect(find.textContaining('LAST-KNOWN RESPONDER LOCATION · Rahul Pillai'),
          findsOneWidget);
    }
  });

  // Phase F case 29 --------------------------------------------------------
  testWidgets('mobile NavigationDeck stacks multiple cards without overflow',
      (tester) async {
    addTearDown(tester.view.reset);

    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;

    final request = multiRequest();
    final connections = <DirectConnection>[
      for (final responderId in <int>[9, 11, 12])
        DirectConnection(
          requestId: request.id,
          responderId: responderId,
          responder: GeoPoint(
            10.5 + responderId / 1000,
            76.2 + responderId / 1000,
          ),
          emergency: GeoPoint(10.527642, 76.214435),
        ),
    ];

    await tester.pumpWidget(host(
      SizedBox(
        width: 320,
        child: NavigationDeck(
          connections: connections,
          onGetDirections: (_) {},
          isMobile: true,
        ),
      ),
    ));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.widgetWithText(TextButton, 'Get directions'), findsNWidgets(3));
  });
}
