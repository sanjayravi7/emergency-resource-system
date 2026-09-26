/// Real road routing for ERAS.
///
/// The route always comes from Google's **current** Routes API
/// (`directions/v2:computeRoutes`, travelMode `DRIVE`,
/// routingPreference `TRAFFIC_AWARE`), never from the deprecated Maps
/// JavaScript `DirectionsService` and never from a straight-line estimate.
///
/// Security: the Routes API key is a *server* key. Flutter Web never sees it —
/// it calls the authenticated ERAS endpoint `POST /api/routes/compute`, and the
/// backend (`backend/src/services/routesService.js`) is the only place that
/// holds `GOOGLE_ROUTES_API_KEY`.
library;

import 'dart:math' as math;

import '../Services/api_service.dart';
import 'location_service.dart' show GeoPoint;

/// Raised when a route could not be computed. Callers must keep whatever
/// route/markers they already have; no distance or ETA is ever invented.
class RouteServiceException implements Exception {
  const RouteServiceException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// One computed road route between the responder and the emergency.
///
/// Every value originates from Google: [distanceMeters] and [duration] are the
/// Routes API's own numbers and [encodedPolyline] is its own geometry. ERAS
/// only decodes the polyline and formats the labels.
class RoutePlan {
  RoutePlan({
    required this.origin,
    required this.destination,
    required this.distanceMeters,
    required this.duration,
    required this.encodedPolyline,
    required this.points,
    required this.computedAt,
    this.distanceText,
    this.durationText,
  });

  /// Responder's live (or last known) position the route starts from.
  final GeoPoint origin;

  /// The emergency request coordinates the route ends at.
  final GeoPoint destination;

  /// `routes.distanceMeters` from the Routes API.
  final int distanceMeters;

  /// `routes.duration` from the Routes API (traffic aware).
  final Duration duration;

  /// `routes.polyline.encodedPolyline` exactly as Google returned it.
  final String encodedPolyline;

  /// Decoded polyline vertices, in order. These follow real roads.
  final List<GeoPoint> points;

  /// When this route was received (used by the throttle and the UI).
  final DateTime computedAt;

  /// Optional localized readouts computed by the backend from Google's numbers.
  final String? distanceText;
  final String? durationText;

  bool get hasGeometry => points.length > 1;

  /// "7.4 km" — the backend's localized value when present, otherwise the same
  /// formatting applied locally to Google's `distanceMeters`.
  String get distanceLabel {
    final text = distanceText?.trim();
    if (text != null && text.isNotEmpty) return text;
    return formatRouteDistance(distanceMeters);
  }

  /// "18 min" — Google's own traffic-aware duration. ERAS never derives an ETA
  /// from distance ÷ speed.
  String get etaLabel {
    final text = durationText?.trim();
    if (text != null && text.isNotEmpty) return text;
    return formatRouteDuration(duration);
  }

  /// Parses the ERAS backend response body (`data` object of
  /// `POST /api/routes/compute`).
  factory RoutePlan.fromBackendJson(
    Map<String, dynamic> json, {
    required GeoPoint origin,
    required GeoPoint destination,
    DateTime? computedAt,
  }) {
    final distance = json['distanceMeters'];
    final distanceMeters =
        distance is num ? distance.round() : int.tryParse('$distance');
    if (distanceMeters == null) {
      throw const RouteServiceException('Route response had no distance.');
    }

    final seconds = _durationSecondsFrom(json);
    if (seconds == null) {
      throw const RouteServiceException('Route response had no duration.');
    }

    final encoded = (json['encodedPolyline'] as String?)?.trim() ?? '';
    if (encoded.isEmpty) {
      throw const RouteServiceException('Route response had no polyline.');
    }

    return RoutePlan(
      origin: origin,
      destination: destination,
      distanceMeters: distanceMeters,
      duration: Duration(seconds: seconds),
      encodedPolyline: encoded,
      points: decodeRoutePolyline(encoded),
      computedAt: computedAt ?? DateTime.now(),
      distanceText: (json['distanceText'] as String?)?.trim(),
      durationText: (json['durationText'] as String?)?.trim(),
    );
  }

  static int? _durationSecondsFrom(Map<String, dynamic> json) {
    final numeric = json['durationSeconds'];
    if (numeric is num) return numeric.round();

    // Protobuf duration string, e.g. "1080s".
    final raw = json['duration'];
    if (raw is num) return raw.round();
    final text = raw?.toString().trim() ?? '';
    if (text.isEmpty) return null;
    final match = RegExp(r'^(\d+(?:\.\d+)?)s$').firstMatch(text);
    if (match == null) return int.tryParse(text);
    return double.parse(match.group(1)!).round();
  }
}

/// "740 m" / "7.4 km" (metric, matching the Routes API `units: METRIC`).
String formatRouteDistance(int meters) {
  if (meters < 1000) return '$meters m';
  return '${(meters / 1000).toStringAsFixed(1)} km';
}

/// "45 s" / "18 min" / "1 h 5 min" — formatting only, never an estimate.
String formatRouteDuration(Duration duration) {
  final seconds = duration.inSeconds;
  if (seconds < 60) return '$seconds s';

  final totalMinutes = (seconds / 60).round();
  if (totalMinutes < 60) return '$totalMinutes min';

  final hours = totalMinutes ~/ 60;
  final minutes = totalMinutes % 60;
  return minutes == 0 ? '$hours h' : '$hours h $minutes min';
}

/// Decodes a Google encoded polyline into its vertices.
///
/// https://developers.google.com/maps/documentation/utilities/polylinealgorithm
List<GeoPoint> decodeRoutePolyline(String encoded) {
  final points = <GeoPoint>[];
  var index = 0;
  var latitude = 0;
  var longitude = 0;

  while (index < encoded.length) {
    var shift = 0;
    var result = 0;
    int byte;

    do {
      if (index >= encoded.length) return points;
      byte = encoded.codeUnitAt(index++) - 63;
      result |= (byte & 0x1f) << shift;
      shift += 5;
    } while (byte >= 0x20);
    latitude += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);

    shift = 0;
    result = 0;
    do {
      if (index >= encoded.length) return points;
      byte = encoded.codeUnitAt(index++) - 63;
      result |= (byte & 0x1f) << shift;
      shift += 5;
    } while (byte >= 0x20);
    longitude += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);

    points.add(GeoPoint(latitude / 1e5, longitude / 1e5));
  }

  return points;
}

/// Great-circle distance in metres (haversine). Used only by the route-update
/// throttle to measure how far the responder moved — never to estimate an ETA.
double distanceBetweenMeters(GeoPoint a, GeoPoint b) {
  const earthRadiusMeters = 6371008.8;
  const toRadians = math.pi / 180;

  final dLat = (b.latitude - a.latitude) * toRadians;
  final dLng = (b.longitude - a.longitude) * toRadians;
  final sinLat = math.sin(dLat / 2);
  final sinLng = math.sin(dLng / 2);
  final h = sinLat * sinLat +
      math.cos(a.latitude * toRadians) *
          math.cos(b.latitude * toRadians) *
          sinLng *
          sinLng;
  return earthRadiusMeters * 2 * math.asin(math.sqrt(h.clamp(0.0, 1.0)));
}

/// Contract used by the map widget. Injectable so tests never hit the network.
abstract class RouteService {
  Future<RoutePlan> computeRoute({
    required GeoPoint origin,
    required GeoPoint destination,
  });
}

/// Default implementation: authenticated ERAS backend call.
///
/// `POST /api/routes/compute` → the backend performs the Google Routes API
/// request with the server key and returns only distance, duration and the
/// encoded polyline.
class BackendRouteService implements RouteService {
  const BackendRouteService();

  @override
  Future<RoutePlan> computeRoute({
    required GeoPoint origin,
    required GeoPoint destination,
  }) async {
    final Map<String, dynamic> data;
    try {
      data = await ApiService.computeRoute(
        originLatitude: origin.latitude,
        originLongitude: origin.longitude,
        destinationLatitude: destination.latitude,
        destinationLongitude: destination.longitude,
      );
    } on RouteServiceException {
      rethrow;
    } catch (error) {
      throw RouteServiceException(_cleanMessage(error));
    }

    return RoutePlan.fromBackendJson(
      data,
      origin: origin,
      destination: destination,
    );
  }

  String _cleanMessage(Object error) {
    final text = error.toString();
    return text.startsWith('Exception: ')
        ? text.substring('Exception: '.length)
        : text;
  }
}
