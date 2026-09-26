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

EmergencyRequest request({
  int id = 501,
  String status = 'IN_PROGRESS',
  double? latitude = 10.05276,
  double? longitude = 76.35211,
  int? responderId = 9,
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
    'allocations': <dynamic>[],
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
  required Map<int, LiveResponderLocation> liveLocations,
}) {
  final connection = selectDirectConnection(
    requests: requests,
    liveLocations: liveLocations,
  );
  return <Polyline>{
    if (connection != null) buildDirectConnectionPolyline(connection),
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
        liveLocations: <int, LiveResponderLocation>{501: live()},
      );

      expect(polylines, hasLength(1));
      final line = polylines.single;
      expect(line.polylineId, kDirectConnectionPolylineId);
      expect(line.points, <LatLng>[
        const LatLng(10.00846, 76.45163),
        const LatLng(10.05276, 76.35211),
      ]);
    });

    // 2 -------------------------------------------------------------------
    test('updates when the responder coordinate changes', () {
      final before = polylinesFor(
        requests: <EmergencyRequest>[request()],
        liveLocations: <int, LiveResponderLocation>{501: live()},
      ).single;

      final after = polylinesFor(
        requests: <EmergencyRequest>[request()],
        liveLocations: <int, LiveResponderLocation>{
          501: live(latitude: 10.02000, longitude: 76.44000),
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
        liveLocations: <int, LiveResponderLocation>{501: live()},
      );

      expect(polylines, isEmpty);
    });

    // 4 -------------------------------------------------------------------
    test('no line when responder coordinates are missing', () {
      final polylines = polylinesFor(
        requests: <EmergencyRequest>[request()],
        liveLocations: const <int, LiveResponderLocation>{},
      );

      expect(polylines, isEmpty);
    });

    test('no line when nobody accepted the emergency', () {
      final polylines = polylinesFor(
        requests: <EmergencyRequest>[
          request(status: 'PENDING', responderId: null),
        ],
        liveLocations: <int, LiveResponderLocation>{501: live()},
      );

      expect(polylines, isEmpty);
    });

    test('no line when the live responder is not the assignee', () {
      final polylines = polylinesFor(
        requests: <EmergencyRequest>[request(responderId: 9)],
        liveLocations: <int, LiveResponderLocation>{501: live(responderId: 42)},
      );

      expect(polylines, isEmpty);
    });

    // 5 -------------------------------------------------------------------
    test('line is removed when the request becomes completed or cancelled', () {
      expect(
        polylinesFor(
          requests: <EmergencyRequest>[request()],
          liveLocations: <int, LiveResponderLocation>{501: live()},
        ),
        hasLength(1),
      );

      for (final terminal in <String>['COMPLETED', 'CANCELLED']) {
        expect(
          polylinesFor(
            requests: <EmergencyRequest>[request(status: terminal)],
            liveLocations: <int, LiveResponderLocation>{501: live()},
          ),
          isEmpty,
          reason: '$terminal requests must not keep a connection line',
        );
      }
    });

    test('a last-known responder point still draws the connection', () {
      final polylines = polylinesFor(
        requests: <EmergencyRequest>[request()],
        liveLocations: <int, LiveResponderLocation>{
          501: live(isLive: false),
        },
      );

      expect(polylines, hasLength(1));
    });
  });

  group('Google Maps directions URL', () {
    final connection = selectDirectConnection(
      requests: <EmergencyRequest>[request()],
      liveLocations: <int, LiveResponderLocation>{501: live()},
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
        liveLocations: <int, LiveResponderLocation>{501: live(isLive: false)},
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
      liveLocations: <int, LiveResponderLocation>{501: live()},
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
  });

  test('direct distance is straight-line only', () {
    final connection = selectDirectConnection(
      requests: <EmergencyRequest>[request()],
      liveLocations: <int, LiveResponderLocation>{501: live()},
    )!;

    // Haversine distance between the two fixed points ≈ 12.0 km.
    expect(connection.directDistanceMeters, closeTo(11959, 50));
    expect(connection.directDistanceLabel, endsWith('km'));
    expect(formatDirectDistance(740), '740 m');
  });
}
