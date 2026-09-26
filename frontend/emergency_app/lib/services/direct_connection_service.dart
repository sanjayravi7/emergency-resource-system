/// Direct responder → emergency connection + external Google Maps directions.
///
/// ERAS does **not** compute driving routes itself:
///   * The map draws a simple straight connection line between the responder's
///     latest coordinate and the emergency coordinate. This is pure local map
///     geometry — no API request, no routing service, no throttling.
///   * Real driving directions are delegated to Google Maps through a
///     universal Maps URL (`https://www.google.com/maps/dir/?api=1`), which
///     opens the Google Maps app on Android/iOS and the Google Maps website on
///     desktop, and requires no API key.
library;

import 'dart:math' as math;

import '../models/eras_models.dart';
import 'location_service.dart' show GeoPoint;

/// The responder/emergency coordinate pair a direct connection may be drawn
/// for.
class DirectConnection {
  const DirectConnection({
    required this.requestId,
    required this.responderId,
    required this.responder,
    required this.emergency,
    required this.responderIsLive,
  });

  final int requestId;
  final int responderId;

  /// Responder's latest live (or last known) position.
  final GeoPoint responder;

  /// The emergency request coordinates.
  final GeoPoint emergency;

  /// Whether [responder] came from an active Socket.IO stream.
  final bool responderIsLive;

  /// Straight-line (great-circle) distance in metres. This is **not** a road
  /// or driving distance and is never used to derive an ETA.
  double get directDistanceMeters =>
      distanceBetweenMeters(responder, emergency);

  /// "Direct distance: 7.4 km" value part — clearly a straight-line number.
  String get directDistanceLabel =>
      formatDirectDistance(directDistanceMeters.round());

  @override
  bool operator ==(Object other) =>
      other is DirectConnection &&
      other.requestId == requestId &&
      other.responderId == responderId &&
      other.responder == responder &&
      other.emergency == emergency &&
      other.responderIsLive == responderIsLive;

  @override
  int get hashCode => Object.hash(
    requestId,
    responderId,
    responder,
    emergency,
    responderIsLive,
  );
}

/// Picks the one emergency that may show a direct connection line.
///
/// A connection is allowed only when
///   * the request is still active (not completed/cancelled),
///   * the request has latitude + longitude,
///   * a responder accepted the request, and
///   * that same responder has a live or last-known coordinate.
///
/// Returns null when no request qualifies. Live responders win over
/// last-known ones; ties are resolved by request id so the choice is stable.
DirectConnection? selectDirectConnection({
  required Iterable<EmergencyRequest> requests,
  required Map<int, LiveResponderLocation> liveLocations,
}) {
  final candidates = <DirectConnection>[];

  for (final request in requests) {
    if (!request.isOpen) continue;
    if (!request.hasPreciseLocation) continue;

    final responder = request.acceptedBy;
    if (responder == null) continue;

    final live = liveLocations[request.id];
    if (live == null) continue;
    if (live.responderId != responder.id) continue;

    candidates.add(
      DirectConnection(
        requestId: request.id,
        responderId: responder.id,
        responder: GeoPoint(live.latitude, live.longitude),
        emergency: GeoPoint(request.latitude!, request.longitude!),
        responderIsLive: live.isLive,
      ),
    );
  }

  if (candidates.isEmpty) return null;

  candidates.sort((left, right) {
    if (left.responderIsLive != right.responderIsLive) {
      return left.responderIsLive ? -1 : 1;
    }
    return left.requestId.compareTo(right.requestId);
  });

  return candidates.first;
}

/// "740 m" / "7.4 km" — straight-line distance formatting only.
String formatDirectDistance(int meters) {
  if (meters < 1000) return '$meters m';
  return '${(meters / 1000).toStringAsFixed(1)} km';
}

/// Great-circle distance in metres (haversine). Straight-line only: never a
/// road distance and never an ETA input.
double distanceBetweenMeters(GeoPoint a, GeoPoint b) {
  const earthRadiusMeters = 6371008.8;
  const toRadians = math.pi / 180;

  final dLat = (b.latitude - a.latitude) * toRadians;
  final dLng = (b.longitude - a.longitude) * toRadians;
  final sinLat = math.sin(dLat / 2);
  final sinLng = math.sin(dLng / 2);
  final h =
      sinLat * sinLat +
      math.cos(a.latitude * toRadians) *
          math.cos(b.latitude * toRadians) *
          sinLng *
          sinLng;
  return earthRadiusMeters * 2 * math.asin(math.sqrt(h.clamp(0.0, 1.0)));
}

/// Base of the Google Maps universal (cross-platform, key-less) URL scheme.
const String kGoogleMapsDirectionsBase =
    'https://www.google.com/maps/dir/?api=1';

/// Builds the Google Maps universal Directions URL used by "Get directions".
///
/// ```
/// https://www.google.com/maps/dir/?api=1
///   &origin=<responderLat>,<responderLng>
///   &destination=<emergencyLat>,<emergencyLng>
///   &travelmode=driving
///   &dir_action=navigate
/// ```
///
/// Works on Android and iOS (opens the Google Maps app when installed) and
/// falls back to the Google Maps website on desktop/web. No API key needed.
Uri buildGoogleMapsDirectionsUri({
  required GeoPoint origin,
  required GeoPoint destination,
  bool navigate = true,
}) {
  return Uri.https('www.google.com', '/maps/dir/', <String, String>{
    'api': '1',
    'origin': formatCoordinateParameter(origin),
    'destination': formatCoordinateParameter(destination),
    'travelmode': 'driving',
    if (navigate) 'dir_action': 'navigate',
  });
}

/// Same as [buildGoogleMapsDirectionsUri] but returns the URL-encoded string.
String buildGoogleMapsDirectionsUrl({
  required GeoPoint origin,
  required GeoPoint destination,
  bool navigate = true,
}) => buildGoogleMapsDirectionsUri(
  origin: origin,
  destination: destination,
  navigate: navigate,
).toString();

/// "12.9716,77.5946" — the exact coordinates, never rounded into a fake place.
String formatCoordinateParameter(GeoPoint point) =>
    '${_trimCoordinate(point.latitude)},${_trimCoordinate(point.longitude)}';

String _trimCoordinate(double value) {
  final text = value.toStringAsFixed(6);
  if (!text.contains('.')) return text;
  final trimmed = text.replaceFirst(RegExp(r'0+$'), '');
  return trimmed.endsWith('.')
      ? trimmed.substring(0, trimmed.length - 1)
      : trimmed;
}

/// Opens the Google Maps universal Directions URL for [connection] through
/// the injected [launcher]. Returns false when the platform refused it.
///
/// `dir_action=navigate` is only requested when the responder position is a
/// live GPS fix — a stale last-known point should not start turn-by-turn
/// navigation automatically.
Future<bool> openGoogleMapsDirections({
  required DirectConnection connection,
  required ExternalUrlLauncher launcher,
}) async {
  final uri = buildGoogleMapsDirectionsUri(
    origin: connection.responder,
    destination: connection.emergency,
    navigate: connection.responderIsLive,
  );
  try {
    return await launcher.launch(uri);
  } catch (_) {
    return false;
  }
}

/// Abstraction over the platform URL opener so widget tests never launch a
/// real Google Maps navigation session.
abstract class ExternalUrlLauncher {
  /// Opens [url] in the platform handler (Google Maps app or browser).
  /// Returns false when the platform refused to handle it.
  Future<bool> launch(Uri url);
}

/// Launches maps URLs through the platform default handler.
///
/// Implemented with a lazily-injected opener so the package dependency lives
/// in exactly one place (see `url_launcher_adapter.dart`).
class PlatformUrlLauncher implements ExternalUrlLauncher {
  const PlatformUrlLauncher(this._open);

  final Future<bool> Function(Uri url) _open;

  @override
  Future<bool> launch(Uri url) => _open(url);
}
