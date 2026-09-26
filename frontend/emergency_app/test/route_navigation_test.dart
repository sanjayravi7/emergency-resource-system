import 'dart:async';

import 'package:dispatch_console_flutter/models/eras_models.dart';
import 'package:dispatch_console_flutter/services/active_route_controller.dart';
import 'package:dispatch_console_flutter/services/location_service.dart'
    show GeoPoint;
import 'package:dispatch_console_flutter/services/route_service.dart';
import 'package:dispatch_console_flutter/widgets/operational_google_map.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records every route request so the tests can prove the throttling rules,
/// and never performs any network/Google call.
class FakeRouteService implements RouteService {
  FakeRouteService();

  final List<({GeoPoint origin, GeoPoint destination})> calls =
      <({GeoPoint origin, GeoPoint destination})>[];

  /// When set, the *next* call hangs on this completer (loading state).
  Completer<RoutePlan>? pending;

  /// When set, the next call fails with this error.
  Object? error;

  /// Optional custom plan factory.
  RoutePlan Function(GeoPoint origin, GeoPoint destination)? planBuilder;

  int get callCount => calls.length;

  @override
  Future<RoutePlan> computeRoute({
    required GeoPoint origin,
    required GeoPoint destination,
  }) {
    calls.add((origin: origin, destination: destination));

    final completer = pending;
    if (completer != null) {
      pending = null;
      return completer.future;
    }

    final failure = error;
    if (failure != null) {
      error = null;
      return Future<RoutePlan>.error(failure);
    }

    final builder = planBuilder;
    if (builder != null) return Future<RoutePlan>.value(builder(origin, destination));

    return Future<RoutePlan>.value(routePlan(origin: origin, destination: destination));
  }
}

/// Canonical Google encoded polyline sample:
/// (38.5, -120.2) → (40.7, -120.95) → (43.252, -126.453).
const String kSamplePolyline = '_p~iF~ps|U_ulLnnqC_mqNvxq`@';

/// A route as the ERAS backend returns it (values produced by Google).
RoutePlan routePlan({
  GeoPoint origin = const GeoPoint(10.00846, 76.45163),
  GeoPoint destination = const GeoPoint(10.05276, 76.35211),
  int distanceMeters = 7412,
  String duration = '1080s',
  String encodedPolyline = kSamplePolyline,
  String? distanceText = '7.4 km',
  String? durationText = '18 min',
}) {
  return RoutePlan.fromBackendJson(
    <String, dynamic>{
      'distanceMeters': distanceMeters,
      'duration': duration,
      'durationSeconds': int.parse(duration.replaceAll('s', '')),
      'encodedPolyline': encodedPolyline,
      if (distanceText != null) 'distanceText': distanceText,
      if (durationText != null) 'durationText': durationText,
    },
    origin: origin,
    destination: destination,
    computedAt: DateTime.utc(2026, 9, 26, 10),
  );
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
    'description': 'Route test',
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

Widget host(Widget child) => MaterialApp(
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  group('ActiveRouteController', () {
    late FakeRouteService service;
    late DateTime now;
    late ActiveRouteController controller;

    setUp(() {
      service = FakeRouteService();
      now = DateTime.utc(2026, 9, 26, 10);
      controller = ActiveRouteController(
        routeService: service,
        clock: () => now,
      );
    });

    tearDown(() => controller.dispose());

    // 1 -----------------------------------------------------------------
    test('responder + emergency coordinates produce a route request', () async {
      await controller.sync(
        requests: <EmergencyRequest>[request()],
        liveLocations: <int, LiveResponderLocation>{501: live()},
      );

      expect(service.callCount, 1);
      expect(service.calls.single.origin, const GeoPoint(10.00846, 76.45163));
      expect(service.calls.single.destination, const GeoPoint(10.05276, 76.35211));

      expect(controller.hasRoute, isTrue);
      expect(controller.requestId, 501);
      expect(controller.route!.distanceMeters, 7412);
      expect(controller.route!.duration, const Duration(seconds: 1080));
      expect(controller.errorMessage, isNull);
    });

    // 5 -----------------------------------------------------------------
    test('no route is requested when the responder has no GPS point', () async {
      await controller.sync(
        requests: <EmergencyRequest>[request()],
        liveLocations: const <int, LiveResponderLocation>{},
      );

      expect(service.callCount, 0);
      expect(controller.route, isNull);
      expect(controller.requestId, isNull);
    });

    test('no route is requested when the responder is not the assignee', () async {
      await controller.sync(
        requests: <EmergencyRequest>[request(responderId: 9)],
        liveLocations: <int, LiveResponderLocation>{501: live(responderId: 42)},
      );

      expect(service.callCount, 0);
      expect(controller.route, isNull);
    });

    test('no route is requested when nobody accepted the emergency', () async {
      await controller.sync(
        requests: <EmergencyRequest>[
          request(status: 'PENDING', responderId: null),
        ],
        liveLocations: <int, LiveResponderLocation>{501: live()},
      );

      expect(service.callCount, 0);
      expect(controller.route, isNull);
    });

    // 6 -----------------------------------------------------------------
    test('no route is requested when the emergency has no coordinates', () async {
      await controller.sync(
        requests: <EmergencyRequest>[request(latitude: null, longitude: null)],
        liveLocations: <int, LiveResponderLocation>{501: live()},
      );

      expect(service.callCount, 0);
      expect(controller.route, isNull);
    });

    // 7 -----------------------------------------------------------------
    test('tiny GPS movements do not recalculate the route', () async {
      await controller.sync(
        requests: <EmergencyRequest>[request()],
        liveLocations: <int, LiveResponderLocation>{501: live()},
      );
      expect(service.callCount, 1);

      // ~2 m of jitter, 1 second later: throttled by both rules.
      now = now.add(const Duration(seconds: 1));
      await controller.sync(
        requests: <EmergencyRequest>[request()],
        liveLocations: <int, LiveResponderLocation>{
          501: live(latitude: 10.008478, longitude: 76.451638),
        },
      );

      // ~11 m of movement well after the 15 s interval: still below 100 m.
      now = now.add(const Duration(seconds: 40));
      await controller.sync(
        requests: <EmergencyRequest>[request()],
        liveLocations: <int, LiveResponderLocation>{
          501: live(latitude: 10.00856, longitude: 76.451685),
        },
      );

      expect(service.callCount, 1);
      expect(controller.route, isNotNull);
    });

    test('a burst of Socket.IO updates issues a single Routes API request', () async {
      for (var i = 0; i < 25; i++) {
        now = now.add(const Duration(milliseconds: 400));
        await controller.sync(
          requests: <EmergencyRequest>[request()],
          liveLocations: <int, LiveResponderLocation>{
            501: live(latitude: 10.00846 + i * 0.0005, longitude: 76.45163),
          },
        );
      }

      expect(service.callCount, 1);
    });

    // 8 -----------------------------------------------------------------
    test('the route recalculates after the throttle interval AND movement', () async {
      await controller.sync(
        requests: <EmergencyRequest>[request()],
        liveLocations: <int, LiveResponderLocation>{501: live()},
      );
      expect(service.callCount, 1);

      // 300 m of movement but only 5 s later: still throttled.
      now = now.add(const Duration(seconds: 5));
      await controller.sync(
        requests: <EmergencyRequest>[request()],
        liveLocations: <int, LiveResponderLocation>{
          501: live(latitude: 10.011160, longitude: 76.45163),
        },
      );
      expect(service.callCount, 1);

      // 16 s after the last request and ~300 m away: recalculated.
      now = now.add(const Duration(seconds: 16));
      await controller.sync(
        requests: <EmergencyRequest>[request()],
        liveLocations: <int, LiveResponderLocation>{
          501: live(latitude: 10.011160, longitude: 76.45163),
        },
      );

      expect(service.callCount, 2);
      expect(service.calls.last.origin.latitude, closeTo(10.011160, 1e-9));
    });

    test('a changed emergency coordinate recalculates immediately', () async {
      await controller.sync(
        requests: <EmergencyRequest>[request()],
        liveLocations: <int, LiveResponderLocation>{501: live()},
      );
      expect(service.callCount, 1);

      now = now.add(const Duration(seconds: 1));
      await controller.sync(
        requests: <EmergencyRequest>[
          request(latitude: 10.06000, longitude: 76.36000),
        ],
        liveLocations: <int, LiveResponderLocation>{501: live()},
      );

      expect(service.callCount, 2);
      expect(service.calls.last.destination, const GeoPoint(10.06, 76.36));
    });

    // 9 -----------------------------------------------------------------
    test('the old route stays visible while a new route is loading', () async {
      await controller.sync(
        requests: <EmergencyRequest>[request()],
        liveLocations: <int, LiveResponderLocation>{501: live()},
      );
      final firstRoute = controller.route;
      expect(firstRoute, isNotNull);

      final pending = Completer<RoutePlan>();
      service.pending = pending;

      now = now.add(const Duration(seconds: 20));
      final inFlight = controller.sync(
        requests: <EmergencyRequest>[request()],
        liveLocations: <int, LiveResponderLocation>{
          501: live(latitude: 10.011160, longitude: 76.45163),
        },
      );
      await Future<void>.delayed(Duration.zero);

      expect(service.callCount, 2);
      expect(controller.isUpdating, isTrue);
      // Previous route is still displayed: the map must not flicker.
      expect(identical(controller.route, firstRoute), isTrue);

      pending.complete(
        routePlan(distanceMeters: 5200, duration: '900s', distanceText: '5.2 km', durationText: '15 min'),
      );
      await inFlight;

      expect(controller.isUpdating, isFalse);
      expect(controller.route!.distanceMeters, 5200);
    });

    test('a failed recalculation keeps the previous route and reports the error', () async {
      await controller.sync(
        requests: <EmergencyRequest>[request()],
        liveLocations: <int, LiveResponderLocation>{501: live()},
      );
      final firstRoute = controller.route;

      service.error = const RouteServiceException('Google Routes API error (HTTP 502).');
      now = now.add(const Duration(seconds: 20));
      await controller.sync(
        requests: <EmergencyRequest>[request()],
        liveLocations: <int, LiveResponderLocation>{
          501: live(latitude: 10.011160, longitude: 76.45163),
        },
      );

      expect(controller.isUpdating, isFalse);
      expect(identical(controller.route, firstRoute), isTrue);
      expect(controller.errorMessage, contains('Routes API'));
    });

    // 10 ----------------------------------------------------------------
    test('a completed request removes the route and stops recalculation', () async {
      await controller.sync(
        requests: <EmergencyRequest>[request()],
        liveLocations: <int, LiveResponderLocation>{501: live()},
      );
      expect(controller.route, isNotNull);

      now = now.add(const Duration(minutes: 1));
      await controller.sync(
        requests: <EmergencyRequest>[request(status: 'COMPLETED')],
        liveLocations: <int, LiveResponderLocation>{501: live()},
      );

      expect(controller.route, isNull);
      expect(controller.requestId, isNull);
      expect(service.callCount, 1);
    });

    test('a cancelled request removes the route and stops recalculation', () async {
      await controller.sync(
        requests: <EmergencyRequest>[request()],
        liveLocations: <int, LiveResponderLocation>{501: live()},
      );

      now = now.add(const Duration(minutes: 1));
      await controller.sync(
        requests: <EmergencyRequest>[request(status: 'CANCELLED')],
        liveLocations: <int, LiveResponderLocation>{501: live()},
      );

      expect(controller.route, isNull);
      expect(service.callCount, 1);
    });

    test('an in-flight route for a completed request is discarded', () async {
      final pending = Completer<RoutePlan>();
      service.pending = pending;

      final inFlight = controller.sync(
        requests: <EmergencyRequest>[request()],
        liveLocations: <int, LiveResponderLocation>{501: live()},
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.isUpdating, isTrue);

      await controller.sync(
        requests: <EmergencyRequest>[request(status: 'COMPLETED')],
        liveLocations: const <int, LiveResponderLocation>{},
      );

      pending.complete(routePlan());
      await inFlight;

      expect(controller.route, isNull);
      expect(controller.isUpdating, isFalse);
    });

    test('a last-known responder position still produces a route', () async {
      await controller.sync(
        requests: <EmergencyRequest>[request()],
        liveLocations: <int, LiveResponderLocation>{501: live(isLive: false)},
      );

      expect(service.callCount, 1);
      expect(controller.route, isNotNull);
      expect(controller.target!.responderIsLive, isFalse);
    });
  });

  group('Route rendering', () {
    // 2 -----------------------------------------------------------------
    test('the returned encoded polyline is decoded and rendered as a Polyline', () {
      final plan = routePlan();
      final polyline = buildRoutePolyline(plan);

      expect(polyline.polylineId, kActiveRoutePolylineId);
      expect(polyline.points, hasLength(3));
      expect(polyline.points.first.latitude, closeTo(38.5, 1e-5));
      expect(polyline.points.first.longitude, closeTo(-120.2, 1e-5));
      expect(polyline.points[1].latitude, closeTo(40.7, 1e-5));
      expect(polyline.points[1].longitude, closeTo(-120.95, 1e-5));
      expect(polyline.points.last.latitude, closeTo(43.252, 1e-5));
      expect(polyline.points.last.longitude, closeTo(-126.453, 1e-5));
      expect(polyline.width, greaterThan(0));
    });

    test('decodeRoutePolyline follows the Google polyline algorithm', () {
      final points = decodeRoutePolyline(kSamplePolyline);

      expect(points, hasLength(3));
      expect(points.first.latitude, closeTo(38.5, 1e-6));
      expect(points.last.longitude, closeTo(-126.453, 1e-6));
      expect(decodeRoutePolyline(''), isEmpty);
    });

    // 3 -----------------------------------------------------------------
    testWidgets('the route card displays the Google distance', (tester) async {
      await tester.pumpWidget(host(RouteInfoCard(route: routePlan())));

      expect(find.text('RESPONDER → EMERGENCY'), findsOneWidget);
      expect(find.text('Distance: 7.4 km'), findsOneWidget);
    });

    // 4 -----------------------------------------------------------------
    testWidgets('the route card displays the Google ETA', (tester) async {
      await tester.pumpWidget(host(RouteInfoCard(route: routePlan())));

      expect(find.text('ETA: 18 min'), findsOneWidget);
    });

    testWidgets(
      'distance and ETA fall back to Google numbers when no localized text is sent',
      (tester) async {
        await tester.pumpWidget(
          host(
            RouteInfoCard(
              route: routePlan(distanceText: null, durationText: null),
            ),
          ),
        );

        expect(find.text('Distance: 7.4 km'), findsOneWidget);
        expect(find.text('ETA: 18 min'), findsOneWidget);
      },
    );

    // 9 (UI half) --------------------------------------------------------
    testWidgets('the card keeps the old route visible while updating', (tester) async {
      await tester.pumpWidget(
        host(RouteInfoCard(route: routePlan(), isUpdating: true)),
      );

      expect(find.text('Distance: 7.4 km'), findsOneWidget);
      expect(find.text('ETA: 18 min'), findsOneWidget);
      expect(find.text('Updating route…'), findsOneWidget);
    });

    testWidgets('a route error is shown without removing the route', (tester) async {
      await tester.pumpWidget(
        host(
          RouteInfoCard(
            route: routePlan(),
            errorMessage: 'Google Routes API error (HTTP 502).',
          ),
        ),
      );

      expect(find.text('Distance: 7.4 km'), findsOneWidget);
      expect(find.text('Google Routes API error (HTTP 502).'), findsOneWidget);
    });
  });

  group('RoutePlan mapping', () {
    test('maps the backend payload (Google distance, duration, polyline)', () {
      final plan = RoutePlan.fromBackendJson(
        <String, dynamic>{
          'distanceMeters': 7412,
          'duration': '1080s',
          'durationSeconds': 1080,
          'encodedPolyline': kSamplePolyline,
          'distanceText': '7.4 km',
          'durationText': '18 min',
        },
        origin: const GeoPoint(10.00846, 76.45163),
        destination: const GeoPoint(10.05276, 76.35211),
      );

      expect(plan.distanceMeters, 7412);
      expect(plan.duration, const Duration(seconds: 1080));
      expect(plan.encodedPolyline, kSamplePolyline);
      expect(plan.points, hasLength(3));
      expect(plan.distanceLabel, '7.4 km');
      expect(plan.etaLabel, '18 min');
    });

    test('parses a protobuf duration string without durationSeconds', () {
      final plan = RoutePlan.fromBackendJson(
        <String, dynamic>{
          'distanceMeters': 940,
          'duration': '95s',
          'encodedPolyline': kSamplePolyline,
        },
        origin: const GeoPoint(10, 76),
        destination: const GeoPoint(10.1, 76.1),
      );

      expect(plan.duration, const Duration(seconds: 95));
      expect(plan.distanceLabel, '940 m');
      expect(plan.etaLabel, '2 min');
    });

    test('rejects an incomplete route instead of inventing values', () {
      expect(
        () => RoutePlan.fromBackendJson(
          <String, dynamic>{'distanceMeters': 100, 'duration': '60s'},
          origin: const GeoPoint(10, 76),
          destination: const GeoPoint(10.1, 76.1),
        ),
        throwsA(isA<RouteServiceException>()),
      );
    });

    test('formats distances and durations from Google values only', () {
      expect(formatRouteDistance(740), '740 m');
      expect(formatRouteDistance(7412), '7.4 km');
      expect(formatRouteDuration(const Duration(seconds: 45)), '45 s');
      expect(formatRouteDuration(const Duration(seconds: 1080)), '18 min');
      expect(formatRouteDuration(const Duration(seconds: 3900)), '1 h 5 min');
    });
  });
}
