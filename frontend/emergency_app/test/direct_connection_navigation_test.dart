/// ERAS navigation: direct connection line + external Google Maps directions.
///
/// No Google Routes API, no routing service and no real navigation launch is
/// involved: the line is local map geometry and the URL launcher is faked.
library;

import 'package:dispatch_console_flutter/models/eras_models.dart';
import 'package:dispatch_console_flutter/services/direct_connection_service.dart';
import 'package:dispatch_console_flutter/services/location_service.dart'
    show GeoPoint;
import 'package:dispatch_console_flutter/widgets/operational_google_map.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Records every URL instead of opening Google Maps.
class FakeUrlLauncher implements ExternalUrlLauncher {
  final List<Uri> launched = <Uri>[];
  bool result = true;
  Object? error;

  @override
  Future<bool> launch(Uri url) async {
    launched.add(url);
    final failure = error;
    if (failure != null) throw failure;
    return result;
  }

  Uri get last => launched.last;
}

Map<String, dynamic> assignment(int responderId, {String status = 'ACTIVE'}) =>
    <String, dynamic>{
      'id': responderId,
      'requestId': 501,
      'responderId': responderId,
      'status': status,
      'acceptedAt': '2026-09-26T09:30:00.000Z',
      'responder': <String, dynamic>{
        'id': responderId,
        'name': 'Responder $responderId',
      },
    };

Map<String, dynamic> allocationRow(int responderId,
        {String status = 'RESERVED'}) =>
    <String, dynamic>{
      'id': 900 + responderId,
      'requestId': 501,
      'resourceId': 4,
      'responderId': responderId,
      'responderResourceId': 100 + responderId,
      'quantity': 1,
      'status': status,
      'resource': <String, dynamic>{'id': 4, 'name': 'Blood'},
      'responder': <String, dynamic>{
        'id': responderId,
        'name': 'Responder $responderId',
      },
    };

EmergencyRequest request({
  int id = 501,
  String status = 'IN_PROGRESS',
  double? latitude = 10.05276,
  double? longitude = 76.35211,
  int? responderId = 9,
  List<Map<String, dynamic>> assignments = const [],
  List<Map<String, dynamic>> allocations = const [],
}) {
  return EmergencyRequest.fromJson(<String, dynamic>{
    'id': id,
    'emergencyType': 'Medical',
    'description': 'Navigation test',
    'location': 'Kochi, Kerala',
    'priority': 'HIGH',
    'status': status,
    'createdAt': '2026-09-26T09:00:00.000Z',
    'updatedAt': '2026-09-26T10:00:00.000Z',
    'latitude': latitude,
    'longitude': longitude,
    'requiredResources': <dynamic>[],
    'allocations': allocations,
    'assignments': assignments,
    if (responderId != null)
      'acceptedBy': <String, dynamic>{
        'id': responderId,
        'name': 'Responder $responderId',
      },
  });
}

LiveResponderLocation live({
  int requestId = 501,
  int responderId = 9,
  double latitude = 10.00846,
  double longitude = 76.45163,
  bool isLive = true,
}) {
  return LiveResponderLocation(
    requestId: requestId,
    responderId: responderId,
    latitude: latitude,
    longitude: longitude,
    updatedAt: DateTime.utc(2026, 9, 26, 10),
    isLive: isLive,
  );
}

Set<Polyline> polylinesFor({
  required List<EmergencyRequest> requests,
  required Map<int, Map<int, LiveResponderLocation>> liveLocations,
}) {
  return <Polyline>{
    for (final connection in selectDirectConnections(
      requests: requests,
      liveLocations: liveLocations,
    ))
      buildDirectConnectionPolyline(connection),
  };
}

Widget host(Widget child) => MaterialApp(
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  group('direct connection line', () {
    // 1 -------------------------------------------------------------------
    test('appears for two valid points', () {
      final polylines = polylinesFor(
        requests: <EmergencyRequest>[request()],
        liveLocations: <int, Map<int, LiveResponderLocation>>{501: <int, LiveResponderLocation>{9: live()}},
      );

      expect(polylines, hasLength(1));
      final line = polylines.single;
      // PHASE F: each (request, responder) pair draws its own line with a
      // unique id (was the single shared kDirectConnectionPolylineId).
      expect(line.polylineId, directConnectionPolylineIdFor(501, 9));
      expect(line.points, <LatLng>[
        const LatLng(10.00846, 76.45163),
        const LatLng(10.05276, 76.35211),
      ]);
    });

    // 2 -------------------------------------------------------------------
    test('updates when the responder coordinate changes', () {
      final before = polylinesFor(
        requests: <EmergencyRequest>[request()],
        liveLocations: <int, Map<int, LiveResponderLocation>>{501: <int, LiveResponderLocation>{9: live()}},
      ).single;

      final after = polylinesFor(
        requests: <EmergencyRequest>[request()],
        liveLocations: <int, Map<int, LiveResponderLocation>>{
          501: <int, LiveResponderLocation>{
            9: live(latitude: 10.02000, longitude: 76.44000),
          },
        },
      ).single;

      expect(after.polylineId, before.polylineId);
      expect(after.points.first, const LatLng(10.02000, 76.44000));
      // The emergency endpoint never moves.
      expect(after.points.last, before.points.last);
      expect(after.points, isNot(before.points));
    });

    // 3 -------------------------------------------------------------------
    test('no line when emergency coordinates are missing', () {
      final polylines = polylinesFor(
        requests: <EmergencyRequest>[request(latitude: null, longitude: null)],
        liveLocations: <int, Map<int, LiveResponderLocation>>{501: <int, LiveResponderLocation>{9: live()}},
      );

      expect(polylines, isEmpty);
    });

    // 4 -------------------------------------------------------------------
    test('no line when responder coordinates are missing', () {
      final polylines = polylinesFor(
        requests: <EmergencyRequest>[request()],
        liveLocations: const <int, Map<int, LiveResponderLocation>>{},
      );

      expect(polylines, isEmpty);
    });

    test('no line when nobody accepted the emergency', () {
      final polylines = polylinesFor(
        requests: <EmergencyRequest>[
          request(status: 'PENDING', responderId: null),
        ],
        liveLocations: <int, Map<int, LiveResponderLocation>>{501: <int, LiveResponderLocation>{9: live()}},
      );

      expect(polylines, isEmpty);
    });

    test('no line when the live responder is not the assignee', () {
      final polylines = polylinesFor(
        requests: <EmergencyRequest>[request(responderId: 9)],
        liveLocations: <int, Map<int, LiveResponderLocation>>{501: <int, LiveResponderLocation>{42: live(responderId: 42)}},
      );

      expect(polylines, isEmpty);
    });

    // 5 -------------------------------------------------------------------
    test('line is removed when the request becomes completed or cancelled', () {
      expect(
        polylinesFor(
          requests: <EmergencyRequest>[request()],
          liveLocations: <int, Map<int, LiveResponderLocation>>{501: <int, LiveResponderLocation>{9: live()}},
        ),
        hasLength(1),
      );

      for (final terminal in <String>['COMPLETED', 'CANCELLED']) {
        expect(
          polylinesFor(
            requests: <EmergencyRequest>[request(status: terminal)],
            liveLocations: <int, Map<int, LiveResponderLocation>>{501: <int, LiveResponderLocation>{9: live()}},
          ),
          isEmpty,
          reason: '$terminal requests must not keep a connection line',
        );
      }
    });

    test('a last-known responder point still draws the connection', () {
      final polylines = polylinesFor(
        requests: <EmergencyRequest>[request()],
        liveLocations: <int, Map<int, LiveResponderLocation>>{
          501: <int, LiveResponderLocation>{
            9: live(isLive: false),
          },
        },
      );

      expect(polylines, hasLength(1));
    });
  });

  group('Google Maps directions URL', () {
    final connection = selectDirectConnection(
      requests: <EmergencyRequest>[request()],
      liveLocations: <int, Map<int, LiveResponderLocation>>{501: <int, LiveResponderLocation>{9: live()}},
    )!;

    // 6 -------------------------------------------------------------------
    test('Get directions constructs the correct universal Maps URL', () {
      final url = buildGoogleMapsDirectionsUrl(
        origin: connection.responder,
        destination: connection.emergency,
      );

      expect(
        url,
        'https://www.google.com/maps/dir/?api=1'
        '&origin=10.00846%2C76.45163'
        '&destination=10.05276%2C76.35211'
        '&travelmode=driving'
        '&dir_action=navigate',
      );
    });

    // 7 -------------------------------------------------------------------
    test('URL carries the responder coordinates as origin', () {
      final uri = buildGoogleMapsDirectionsUri(
        origin: const GeoPoint(12.9716, 77.5946),
        destination: connection.emergency,
      );

      expect(uri.queryParameters['origin'], '12.9716,77.5946');
    });

    // 8 -------------------------------------------------------------------
    test('URL carries the emergency coordinates as destination', () {
      final uri = buildGoogleMapsDirectionsUri(
        origin: connection.responder,
        destination: const GeoPoint(-33.8688, 151.2093),
      );

      expect(uri.queryParameters['destination'], '-33.8688,151.2093');
      expect(uri.query, contains('destination=-33.8688%2C151.2093'));
    });

    // 9 -------------------------------------------------------------------
    test('URL requests driving mode and the api=1 scheme', () {
      final uri = buildGoogleMapsDirectionsUri(
        origin: connection.responder,
        destination: connection.emergency,
      );

      expect(uri.queryParameters['travelmode'], 'driving');
      expect(uri.queryParameters['api'], '1');
      expect(uri.scheme, 'https');
      expect(uri.host, 'www.google.com');
      expect(uri.path, '/maps/dir/');
    });

    test('dir_action=navigate is omitted when navigation is not appropriate',
        () {
      final uri = buildGoogleMapsDirectionsUri(
        origin: connection.responder,
        destination: connection.emergency,
        navigate: false,
      );

      expect(uri.queryParameters.containsKey('dir_action'), isFalse);
      expect(uri.queryParameters['travelmode'], 'driving');
    });

    // 10 ------------------------------------------------------------------
    test('the URL opens through the injected URL launcher abstraction',
        () async {
      final launcher = FakeUrlLauncher();

      final opened = await openGoogleMapsDirections(
        connection: connection,
        launcher: launcher,
      );

      expect(opened, isTrue);
      expect(launcher.launched, hasLength(1));
      expect(launcher.last.host, 'www.google.com');
      expect(launcher.last.queryParameters['origin'], '10.00846,76.45163');
      expect(launcher.last.queryParameters['destination'], '10.05276,76.35211');
      expect(launcher.last.queryParameters['travelmode'], 'driving');
      expect(launcher.last.queryParameters['dir_action'], 'navigate');
    });

    test('a last-known responder position does not force navigate mode',
        () async {
      final lastKnown = selectDirectConnection(
        requests: <EmergencyRequest>[request()],
        liveLocations: <int, Map<int, LiveResponderLocation>>{501: <int, LiveResponderLocation>{9: live(isLive: false)}},
      )!;
      final launcher = FakeUrlLauncher();

      await openGoogleMapsDirections(
        connection: lastKnown,
        launcher: launcher,
      );

      expect(launcher.last.queryParameters.containsKey('dir_action'), isFalse);
    });

    test('a launcher failure is reported instead of thrown', () async {
      final launcher = FakeUrlLauncher()..error = Exception('no handler');

      expect(
        await openGoogleMapsDirections(
          connection: connection,
          launcher: launcher,
        ),
        isFalse,
      );
    });
  });

  group('NavigationInfoCard', () {
    final connection = selectDirectConnection(
      requests: <EmergencyRequest>[request()],
      liveLocations: <int, Map<int, LiveResponderLocation>>{501: <int, LiveResponderLocation>{9: live()}},
    )!;

    testWidgets('shows LIVE/SET state and a clearly labelled direct distance',
        (tester) async {
      await tester.pumpWidget(
        host(
          NavigationInfoCard(
            connection: connection,
            onGetDirections: () {},
          ),
        ),
      );

      expect(find.text('RESPONDER → EMERGENCY'), findsOneWidget);
      expect(find.text('Responder location: LIVE'), findsOneWidget);
      expect(find.text('Emergency location: SET'), findsOneWidget);
      expect(
        find.textContaining('Direct distance:'),
        findsOneWidget,
      );
      expect(find.textContaining('ETA'), findsNothing);
      expect(find.textContaining('Driving distance'), findsNothing);
    });

    testWidgets('Get directions button triggers the callback', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        host(
          NavigationInfoCard(
            connection: connection,
            onGetDirections: () => taps++,
          ),
        ),
      );

      await tester.tap(find.text('Get directions'));
      await tester.pump();

      expect(taps, 1);
    });

    testWidgets('mobile widths use a full-width tappable directions button',
        (tester) async {
      addTearDown(tester.view.reset);

      for (final width in <double>[320, 360, 390, 430]) {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1;

        await tester.pumpWidget(
          host(
            SizedBox(
              width: width,
              child: NavigationInfoCard(
                connection: connection,
                onGetDirections: () {},
              ),
            ),
          ),
        );

        expect(tester.takeException(), isNull);
        expect(find.text('RESPONDER → EMERGENCY'), findsOneWidget);
        expect(find.text('Responder location:'), findsOneWidget);
        expect(find.text('LIVE'), findsOneWidget);
        expect(find.text('Emergency location:'), findsOneWidget);
        expect(find.text('SET'), findsOneWidget);
        expect(find.text('Direct distance:'), findsOneWidget);
        expect(find.text(connection.directDistanceLabel), findsOneWidget);

        final button = find.widgetWithText(TextButton, 'Get directions');
        expect(button, findsOneWidget);

        final buttonSize = tester.getSize(button);
        expect(buttonSize.height, greaterThanOrEqualTo(44));
        expect(buttonSize.width, greaterThanOrEqualTo(width * .80));
      }
    });

    testWidgets('desktop width keeps the compact card', (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        host(
          NavigationInfoCard(
            connection: connection,
            onGetDirections: () {},
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Responder location: LIVE'), findsOneWidget);
      expect(find.text('Emergency location: SET'), findsOneWidget);

      final cardSize = tester.getSize(find.byType(NavigationInfoCard));
      expect(cardSize.width, lessThanOrEqualTo(250));

      final buttonSize =
          tester.getSize(find.widgetWithText(TextButton, 'Get directions'));
      expect(buttonSize.width, lessThan(cardSize.width));
    });

    testWidgets('last-known responder state renders LAST KNOWN',
        (tester) async {
      final lastKnownConnection = selectDirectConnection(
        requests: <EmergencyRequest>[request()],
        liveLocations: <int, Map<int, LiveResponderLocation>>{
          501: <int, LiveResponderLocation>{
            9: live(isLive: false),
          },
        },
      )!;

      await tester.pumpWidget(
        host(
          SizedBox(
            width: 360,
            child: NavigationInfoCard(
              connection: lastKnownConnection,
              onGetDirections: () {},
              isMobile: true,
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Responder location:'), findsOneWidget);
      expect(find.text('LAST KNOWN'), findsOneWidget);
      expect(find.text('Emergency location:'), findsOneWidget);
      expect(find.text('SET'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Get directions'), findsOneWidget);
    });
  });

  group('OperationalGoogleMap responsive layout', () {
    final activeRequest = request();
    final liveLoc = live();

    testWidgets('mobile widths (320, 360, 390, 430) render map, controls, card, and legend without overflow',
        (tester) async {
      addTearDown(tester.view.reset);

      for (final width in <double>[320, 360, 390, 430]) {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;

        final launcher = FakeUrlLauncher();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: SizedBox(
                  width: width,
                  child: OperationalGoogleMap(
                    requests: <EmergencyRequest>[activeRequest],
                    liveLocations: <int, Map<int, LiveResponderLocation>>{501: <int, LiveResponderLocation>{9: liveLoc}},
                    isMobile: true,
                    urlLauncher: launcher,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        expect(tester.takeException(), isNull,
            reason: 'Should render without overflow at width $width');

        // Map controls: compact mobile labels
        expect(find.text('Center'), findsOneWidget);
        expect(find.text('Fit pins'), findsOneWidget);

        // Navigation info card placed below map
        expect(find.text('RESPONDER → EMERGENCY'), findsOneWidget);
        expect(find.text('Responder location:'), findsOneWidget);
        expect(find.text('LIVE'), findsOneWidget);
        expect(find.text('Emergency location:'), findsOneWidget);
        expect(find.text('SET'), findsOneWidget);
        expect(find.text('Direct distance:'), findsOneWidget);

        // Get directions button is visible and full-width
        final directionsButton =
            find.widgetWithText(TextButton, 'Get directions');
        expect(directionsButton, findsOneWidget);
        final buttonSize = tester.getSize(directionsButton);
        expect(buttonSize.height, greaterThanOrEqualTo(44));
        expect(buttonSize.width, greaterThanOrEqualTo((width - 24) * .80));

        // Tap Get directions
        await tester.tap(directionsButton);
        await tester.pump();
        expect(launcher.launched, isNotEmpty);

        // Legend items are all present and visible
        expect(find.text('Active emergency'), findsOneWidget);
        expect(find.text('Pending request'), findsOneWidget);
        expect(find.text('LIVE responder'), findsOneWidget);
        expect(find.text('LAST KNOWN responder'), findsOneWidget);
        expect(
          find.text('Direct connection (straight line)'),
          findsOneWidget,
        );
      }
    });

    testWidgets('completed/cancelled requests remove navigation card on mobile',
        (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      for (final status in ['COMPLETED', 'CANCELLED']) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 360,
                child: OperationalGoogleMap(
                  requests: <EmergencyRequest>[request(status: status)],
                  liveLocations: <int, Map<int, LiveResponderLocation>>{501: <int, LiveResponderLocation>{9: liveLoc}},
                  isMobile: true,
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(find.text('RESPONDER → EMERGENCY'), findsNothing);
        expect(find.widgetWithText(TextButton, 'Get directions'), findsNothing);
        expect(
          find.text('Direct connection (straight line)'),
          findsNothing,
        );
      }
    });

    testWidgets('desktop width keeps overlay layout with full control labels',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 1200,
              child: OperationalGoogleMap(
                requests: <EmergencyRequest>[activeRequest],
                liveLocations: <int, Map<int, LiveResponderLocation>>{501: <int, LiveResponderLocation>{9: liveLoc}},
                isMobile: false,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('Center on emergency'), findsOneWidget);
      expect(find.text('Fit pins'), findsOneWidget);
      expect(find.text('RESPONDER → EMERGENCY'), findsOneWidget);
      expect(find.text('Responder location: LIVE'), findsOneWidget);
    });
  });

  group('Emergency request description optionality', () {
    test('empty description is normalized to null', () {
      final req = EmergencyRequest.fromJson(<String, dynamic>{
        'id': 601,
        'emergencyType': 'Medical',
        'description': '',
        'location': 'Kochi',
        'priority': 'HIGH',
        'status': 'PENDING',
        'createdAt': '2026-09-26T09:00:00.000Z',
        'updatedAt': '2026-09-26T10:00:00.000Z',
        'requiredResources': <dynamic>[],
        'allocations': <dynamic>[],
      });
      expect(req.description, isNull);
    });

    test('whitespace-only description is normalized to null', () {
      final req = EmergencyRequest.fromJson(<String, dynamic>{
        'id': 604,
        'emergencyType': 'Medical',
        'description': '   \n\t  ',
        'location': 'Kochi',
        'priority': 'HIGH',
        'status': 'PENDING',
        'createdAt': '2026-09-26T09:00:00.000Z',
        'updatedAt': '2026-09-26T10:00:00.000Z',
        'requiredResources': <dynamic>[],
        'allocations': <dynamic>[],
      });
      expect(req.description, isNull);
    });

    test('accepts null/missing description', () {
      final req = EmergencyRequest.fromJson(<String, dynamic>{
        'id': 602,
        'emergencyType': 'Medical',
        'location': 'Kochi',
        'priority': 'HIGH',
        'status': 'PENDING',
        'createdAt': '2026-09-26T09:00:00.000Z',
        'updatedAt': '2026-09-26T10:00:00.000Z',
        'requiredResources': <dynamic>[],
        'allocations': <dynamic>[],
      });
      expect(req.description, isNull);
    });

    test('preserves non-empty description', () {
      final req = EmergencyRequest.fromJson(<String, dynamic>{
        'id': 603,
        'emergencyType': 'Medical',
        'description': '  Two people trapped near east gate.  ',
        'location': 'Kochi',
        'priority': 'HIGH',
        'status': 'PENDING',
        'createdAt': '2026-09-26T09:00:00.000Z',
        'updatedAt': '2026-09-26T10:00:00.000Z',
        'requiredResources': <dynamic>[],
        'allocations': <dynamic>[],
      });
      expect(req.description, '  Two people trapped near east gate.  ');
    });
  });

  group('multi-responder direct connections (Phase F)', () {
    final assignedRequest = request(
      assignments: [assignment(9), assignment(11), assignment(12, status: 'ENDED')],
    );

    Map<int, Map<int, LiveResponderLocation>> twoResponderLocations() =>
        <int, Map<int, LiveResponderLocation>>{
          501: <int, LiveResponderLocation>{
            9: live(latitude: 10.05276, longitude: 76.35211),
            11: live(latitude: 10.10000, longitude: 76.40000),
          },
        };

    // Phase F case 19 ----------------------------------------------------
    test('one live connection per participating responder', () {
      final connections = selectDirectConnections(
        requests: <EmergencyRequest>[assignedRequest],
        liveLocations: twoResponderLocations(),
      );

      // Responder 12 is ENDED: never active work, no connection.
      expect(connections, hasLength(2));
      expect(connections.map((c) => c.responderId), <int>[9, 11]);
    });

    // Phase F case 20 ----------------------------------------------------
    test('each (request, responder) pair draws its own polyline id', () {
      final polylines = polylinesFor(
        requests: <EmergencyRequest>[assignedRequest],
        liveLocations: twoResponderLocations(),
      );

      expect(polylines, hasLength(2));
      expect(
        polylines.map((line) => line.polylineId.value).toSet(),
        <String>{
          directConnectionPolylineIdFor(501, 9).value,
          directConnectionPolylineIdFor(501, 11).value,
        },
      );
      // Every polyline runs responder point -> emergency point.
      for (final line in polylines) {
        expect(line.points, hasLength(2));
      }
      final responder9Line = polylines.firstWhere((line) =>
          line.polylineId == directConnectionPolylineIdFor(501, 9));
      expect(responder9Line.points.first.latitude, 10.05276);
      expect(responder9Line.points.last.latitude, 10.05276,
          reason: 'destination is the emergency coordinate');
    });

    // Phase F case 21 ----------------------------------------------------
    test('a live point of a non-participating responder creates no line', () {
      final connections = selectDirectConnections(
        requests: <EmergencyRequest>[request()],
        liveLocations: <int, Map<int, LiveResponderLocation>>{
          501: <int, LiveResponderLocation>{
            42: live(responderId: 42),
          },
        },
      );

      expect(connections, isEmpty);
    });

    test('an allocation-only responder is relevant without an assignment', () {
      final connections = selectDirectConnections(
        requests: <EmergencyRequest>[
          request(assignments: const [], allocations: [allocationRow(11)]),
        ],
        liveLocations: <int, Map<int, LiveResponderLocation>>{
          501: <int, LiveResponderLocation>{
            11: live(latitude: 10.05, longitude: 76.35),
          },
        },
      );

      expect(connections, hasLength(1));
      expect(connections.single.responderId, 11);
    });

    test('a CANCELLED allocation alone does not make a responder relevant', () {
      final connections = selectDirectConnections(
        requests: <EmergencyRequest>[
          request(assignments: const [], allocations: [
            allocationRow(11, status: 'CANCELLED'),
          ]),
        ],
        liveLocations: <int, Map<int, LiveResponderLocation>>{
          501: <int, LiveResponderLocation>{
            11: live(latitude: 10.05, longitude: 76.35),
          },
        },
      );

      expect(connections, isEmpty);
    });

    // Phase F case 22 ----------------------------------------------------
    test('two requests with two responders produce four isolated lines', () {
      final secondRequest = request(
        id: 502,
        latitude: 9.9,
        longitude: 76.3,
        responderId: 9,
        assignments: [assignment(9)],
      );

      final polylines = polylinesFor(
        requests: <EmergencyRequest>[assignedRequest, secondRequest],
        liveLocations: <int, Map<int, LiveResponderLocation>>{
          501: <int, LiveResponderLocation>{
            9: live(latitude: 10.05276, longitude: 76.35211),
            11: live(latitude: 10.10000, longitude: 76.40000),
          },
          502: <int, LiveResponderLocation>{
            9: live(latitude: 10.0, longitude: 76.25),
          },
        },
      );

      expect(polylines, hasLength(3));
      expect(
        polylines.map((line) => line.polylineId.value).toSet(),
        <String>{
          directConnectionPolylineIdFor(501, 9).value,
          directConnectionPolylineIdFor(501, 11).value,
          directConnectionPolylineIdFor(502, 9).value,
        },
      );
    });

    // Phase F case 23 ----------------------------------------------------
    testWidgets('Get directions opens the Google Maps URL for each responder',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final launcher = FakeUrlLauncher();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 1200,
              child: OperationalGoogleMap(
                requests: <EmergencyRequest>[assignedRequest],
                liveLocations: twoResponderLocations(),
                isMobile: false,
                urlLauncher: launcher,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      final buttons = find.widgetWithText(TextButton, 'Get directions');
      expect(buttons, findsNWidgets(2));

      await tester.tap(buttons.first);
      await tester.pump();
      await tester.tap(buttons.at(1));
      await tester.pump();

      expect(launcher.launched, hasLength(2));
      final urls = launcher.launched.map((url) => url.toString()).toList();
      // Both use the existing Google Maps directions launcher - no Routes
      // API, no ETA - and each origin is that responder's live point while
      // the destination stays the emergency location.
      for (final url in urls) {
        expect(url, startsWith('https://www.google.com/maps/dir/'));
        expect(url, contains('destination=10.05276,76.35211'));
      }
      expect(urls.first, contains('origin=10.05276,76.35211'));
      expect(urls.last, contains('origin=10.1,76.4'));
    });

    // Phase F case 24 ----------------------------------------------------
    test('every connection distance is haversine straight-line only', () {
      final connections = selectDirectConnections(
        requests: <EmergencyRequest>[assignedRequest],
        liveLocations: twoResponderLocations(),
      );

      // Responder 9 sits exactly on the emergency: ~0 m. Responder 11 is
      // roughly 7.3 km away. No driving distance, no ETA anywhere.
      expect(connections.first.responderId, 9);
      expect(connections.first.directDistanceMeters, lessThan(50));
      expect(connections[1].responderId, 11);
      expect(connections[1].directDistanceMeters, closeTo(7422, 60));
      expect(connections[1].directDistanceLabel, endsWith('km'));
    });
  });

  test('direct distance is straight-line only', () {
    final connection = selectDirectConnection(
      requests: <EmergencyRequest>[request()],
      liveLocations: <int, Map<int, LiveResponderLocation>>{501: <int, LiveResponderLocation>{9: live()}},
    )!;

    // Haversine distance between the two fixed points ≈ 12.0 km.
    expect(connection.directDistanceMeters, closeTo(11959, 50));
    expect(connection.directDistanceLabel, endsWith('km'));
    expect(formatDirectDistance(740), '740 m');
  });
}
