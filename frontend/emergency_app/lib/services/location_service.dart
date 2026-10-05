/// Reusable location resolution service for ERAS.
///
/// Responsibilities:
///   * reverse geocoding (latitude/longitude -> human readable place)
///   * place autocomplete predictions (biased to the requester location)
///   * resolving a selected prediction back to exact coordinates
///   * nearby places around the requester's GPS position (Google Places API
///     (New) Nearby Search), so the requester can pick a real named place
///     such as a hospital or police station instead of typing
///
/// Architectural rules honoured here:
///   * latitude/longitude stay the canonical, precise location.
///   * the human readable place text is only a label for those coordinates.
///   * no coordinate is ever fabricated; failures surface as exceptions.
///   * on Flutter Web reverse geocoding uses the authenticated ERAS backend
///     (Photon), while search, place details and nearby places continue to use
///     the already-loaded Google Places library.
library;

import 'dart:math' as math;

import '../models/eras_models.dart' show isValidCoordinatePair;
import 'location_service_stub.dart'
    if (dart.library.js_interop) 'location_service_web.dart' as impl;

/// A plain latitude/longitude pair (kept independent of geolocator/Google types
/// so widgets and tests do not need a platform plugin).
class GeoPoint {
  const GeoPoint(this.latitude, this.longitude);

  final double latitude;
  final double longitude;

  @override
  String toString() => '$latitude, $longitude';

  @override
  bool operator ==(Object other) =>
      other is GeoPoint &&
      other.latitude == latitude &&
      other.longitude == longitude;

  @override
  int get hashCode => Object.hash(latitude, longitude);
}

/// Returns true only for a real coordinate pair the requester may use.
///
/// `isValidCoordinatePair` validates ranges and finite values; the zero/zero
/// sentinel is rejected as well because it is never a usable device fix.
bool isUsableDeviceLocation(GeoPoint? point) =>
    point != null &&
    isValidCoordinatePair(point.latitude, point.longitude) &&
    !(point.latitude == 0.0 && point.longitude == 0.0);

/// A human readable place bound to exact coordinates.
class ResolvedPlace {
  const ResolvedPlace({
    required this.label,
    required this.latitude,
    required this.longitude,
    this.placeId,
  });

  /// Best human readable description (place name + address, or formatted
  /// address for a reverse geocode result).
  final String label;

  /// Canonical precise coordinates. Always present.
  final double latitude;
  final double longitude;

  /// Google place id when the result came from the Places API.
  final String? placeId;

  GeoPoint get point => GeoPoint(latitude, longitude);
}

/// One autocomplete suggestion. It carries no coordinates on purpose: the
/// coordinates are only fetched when the requester actually selects it.
class PlacePrediction {
  const PlacePrediction({
    required this.placeId,
    required this.primaryText,
    this.secondaryText = '',
  });

  final String placeId;
  final String primaryText;
  final String secondaryText;

  String get fullText =>
      secondaryText.isEmpty ? primaryText : '$primaryText, $secondaryText';
}

// ---------------------------------------------------------------------------
// Nearby places (Google Places API (New) Nearby Search)
// ---------------------------------------------------------------------------

/// Search radius for the requester-visible NEARBY PLACES list: 5 km.
///
/// 5 km is a neighbourhood-scale radius: the list exists to name the
/// requester's immediate surroundings, and results are ranked with
/// `rankPreference = DISTANCE`, so a wider circle would only add farther
/// places, never better ones. (The 30 km circle used by autocomplete is a
/// *bias*, not a restriction, and belongs to the separate search feature.)
const double kNearbySearchRadiusMeters = 5000;

/// Nearby Search (New) accepts 1..20 results. 10 keeps the visible list short
/// and the request cheap.
const int kNearbySearchMaxResultCount = 10;

/// Categories offered in the NEARBY PLACES section of the requester form.
///
/// Every category maps to real Google Places API (New) place types from
/// Table A of https://developers.google.com/maps/documentation/places/web-service/place-types
/// — only Table A values may be used as `includedTypes` filters in Nearby
/// Search (New). That is why, for example, the Landmark category searches
/// `tourist_attraction`/`cultural_landmark`/… instead of the Table B type
/// `landmark`, and why there is no Junction category (`intersection` is also a
/// Table B value that Nearby Search cannot filter by).
enum NearbyPlaceCategory {
  hospital('Hospital', 'Hospitals', <String>['hospital']),
  police('Police', 'Police stations', <String>['police']),
  fireStation('Fire Station', 'Fire stations', <String>['fire_station']),
  school('School', 'Schools', <String>[
    'school',
    'primary_school',
    'secondary_school',
  ]),
  college('College', 'Colleges', <String>['university']),
  railwayStation('Railway', 'Railway stations', <String>[
    'train_station',
    'light_rail_station',
    'subway_station',
  ]),
  busStation('Bus Station', 'Bus stations', <String>[
    'bus_station',
    'bus_stop',
  ]),
  landmark('Landmark', 'Landmarks', <String>[
    'cultural_landmark',
    'historical_landmark',
    'monument',
    'historical_place',
    'tourist_attraction',
    'plaza',
  ]),
  church('Church', 'Churches', <String>['church']),
  temple('Temple', 'Temples', <String>[
    'hindu_temple',
    'buddhist_temple',
    'shinto_shrine',
  ]),
  mosque('Mosque', 'Mosques', <String>['mosque']);

  const NearbyPlaceCategory(this.label, this.pluralLabel, this.googleTypes);

  /// Short chip label shown in the requester form.
  final String label;

  /// Header above the result list ("Hospitals").
  final String pluralLabel;

  /// Google Places API (New) Table A types sent as `includedTypes`.
  final List<String> googleTypes;
}

/// A real place returned by Google Places API (New) Nearby Search.
///
/// Everything here comes from Google — ERAS never fabricates nearby places,
/// and [latitude]/[longitude] are the place's own coordinates, not the
/// requester's search text.
class NearbyPlace {
  const NearbyPlace({
    required this.placeId,
    required this.name,
    required this.address,
    required this.latitude,
    required this.longitude,
    this.distanceMeters,
  });

  final String placeId;
  final String name;
  final String address;
  final double latitude;
  final double longitude;

  /// Straight-line distance from the search center (the requester's position)
  /// in metres, computed locally from the real coordinates.
  final double? distanceMeters;

  /// Human readable label used for the place field: "Name, address".
  String get label {
    if (name.isEmpty) return address;
    if (address.isEmpty) return name;
    return '$name, $address';
  }

  /// "350 m" / "1.2 km" readout, or an empty string when no distance is known.
  String get distanceLabel {
    final meters = distanceMeters;
    if (meters == null) return '';
    if (meters < 1000) return '${meters.round()} m';
    return '${(meters / 1000).toStringAsFixed(1)} km';
  }

  GeoPoint get point => GeoPoint(latitude, longitude);

  /// Great-circle distance in metres between two coordinates (haversine).
  /// Earth radius per mean radius defined by Google/WGS-84 (~6371008.8 m).
  static double haversineDistanceMeters(
    double latitude1,
    double longitude1,
    double latitude2,
    double longitude2,
  ) {
    const earthRadiusMeters = 6371008.8;
    const toRadians = math.pi / 180;

    final dLat = (latitude2 - latitude1) * toRadians;
    final dLng = (longitude2 - longitude1) * toRadians;
    final sinLat = math.sin(dLat / 2);
    final sinLng = math.sin(dLng / 2);
    final a = sinLat * sinLat +
        math.cos(latitude1 * toRadians) *
            math.cos(latitude2 * toRadians) *
            sinLng *
            sinLng;
    final c = 2 * math.asin(math.sqrt(a.clamp(0.0, 1.0)));
    return earthRadiusMeters * c;
  }
}

/// Raised when Google Places API (New) is disabled, has never been used by the
/// project, or is blocked for the key. The UI must degrade gracefully: the
/// NEARBY PLACES section shows the guidance below, while the map, GPS and
/// reverse geocoding (other Google APIs) keep working.
class PlacesApiDisabledException extends LocationServiceException {
  /// Exact message the requester sees in the NEARBY PLACES section.
  static const String userMessage =
      'Nearby places unavailable. Enable Places API (New) in Google Cloud.';

  const PlacesApiDisabledException({String? details})
      : super(
          'Nearby places unavailable. Enable Places API (New) in Google Cloud.',
          details: details,
        );
}

/// Whether a Google error [message] is a *reverse geocoding authorization*
/// failure rather than a "no result" answer.
///
/// The Maps JavaScript Geocoder reports an unauthorized key/origin as
/// `GEOCODER_GEOCODE: REQUEST_DENIED: The webpage is not allowed to use the
/// geocoder.` That means one of three Google Cloud settings is wrong:
///   1. the Geocoding API is not enabled on the project,
///   2. the browser key's *API restrictions* do not include the Geocoding API,
///   3. the page origin is not an allowed HTTP referrer for that key.
///
/// `ZERO_RESULTS` and similar "Google answered, but had nothing" cases are
/// deliberately not matched: they are not authorization problems.
bool isGeocodingApiDeniedError(String message) {
  final text = message.toLowerCase();
  if (text.contains('not allowed to use the geocoder')) return true;
  if (text.contains('geocoder_geocode') && text.contains('request_denied')) {
    return true;
  }
  if (text.contains('geocoding api') &&
      (text.contains('disabled') || text.contains('has not been used'))) {
    return true;
  }
  if (text.contains('referernotallowedmaperror')) return true;
  if (text.contains('apitargetblockedmaperror')) return true;
  return false;
}

/// Actionable guidance appended to a denied reverse-geocoding error. The raw
/// Google error text is always shown next to it — the failure is never hidden.
const String kGeocodingApiDeniedHint =
    ' Google denied the Geocoding API request for this browser key/origin: '
    'enable the Geocoding API, add it to the key API restrictions and '
    'allow this page origin as an HTTP referrer.';

/// Whether a Google error [message] means the Places API (New) is disabled,
/// not yet used, or not authorized for this project/key.
///
/// Native builds never see raw Google text: the ERAS backend classifies the
/// upstream failure and answers a disabled Places API (New) with its own
/// explicit, stable message (used by nearby search *and* autocomplete), which
/// is the same text as [PlacesApiDisabledException.userMessage]. It is matched
/// below so those responses are classified from the message the client
/// actually receives.
bool isPlacesApiDisabledError(String message) {
  final text = message.toLowerCase();
  if (text.contains('places api (new) has not been used')) return true;
  if (text.contains('places api') && text.contains('disabled')) return true;
  // The backend's explicit "Places API disabled" answer. Both halves of the
  // sentence are required, so an unrelated error that happens to mention one
  // of them is never mistaken for a disabled Places API.
  if (text.contains('nearby places unavailable') &&
      text.contains('enable places api')) {
    return true;
  }
  if (text.contains('request_denied')) return true;
  if (text.contains('permission_denied')) return true;
  if (text.contains('apitargetblockedmaperror')) return true;
  if (text.contains('is not authorized to use this service')) return true;
  // The Places API (New) surface reports a key whose API restrictions do not
  // include it as, verbatim:
  //   "Requests to this API places.googleapis.com method
  //    google.maps.places.v1.Places.AutocompletePlaces are blocked."
  // Note this text contains "api places.googleapis.com", not "places api",
  // so it needs its own match.
  if (text.contains('places.googleapis.com') && text.contains('blocked')) {
    return true;
  }
  if (text.contains('google.maps.places.v1')) return true;
  return false;
}

/// Safe app-facing message for Maps/Places authorization and configuration
/// failures. The raw Google detail remains available in the ERAS diagnostics,
/// but invalid key strings, project identifiers and provider errors are not
/// echoed into the requester's normal workflow UI.
const String kGoogleMapsConfigurationUserMessage =
    'Place search is temporarily unavailable. Please try again later '
    'or contact ERAS support.';

/// Whether [message] indicates browser key, referrer, or Maps API setup rather
/// than an ordinary no-results/network response.
bool isGoogleMapsConfigurationError(String message) {
  final text = message.toLowerCase();
  return text.contains('invalidkeymaperror') ||
      text.contains('referernotallowedmaperror') ||
      text.contains('apitargetblockedmaperror') ||
      text.contains('api key not valid') ||
      text.contains('invalid api key') ||
      text.contains('request_denied') ||
      text.contains('permission_denied') ||
      text.contains('not authorized to use') ||
      text.contains('are blocked') ||
      text.contains('google maps javascript api is not loaded') ||
      text.contains('google places library is not loaded') ||
      text.contains('eras_google_maps_api_key');
}

/// Keeps ordinary provider failures useful, while reducing credential and
/// authorization failures to one safe user-facing message.
String googleLocationUserMessage(String message) {
  if (isGoogleMapsConfigurationError(message) ||
      isPlacesApiDisabledError(message)) {
    return kGoogleMapsConfigurationUserMessage;
  }
  return message;
}

/// Stable, platform-neutral reasons for a failed current-location request.
///
/// These values intentionally contain safe user-facing copy and diagnostic
/// codes rather than native/plugin exception strings.
enum LocationFailureReason {
  permissionDenied(
    'permission_denied',
    'Location permission is required to use your current location.',
  ),
  permissionDeniedForever(
    'permission_denied_forever',
    'Location permission is blocked. Allow it in Android app settings.',
  ),
  serviceDisabled(
    'service_disabled',
    'Location services are turned off. Enable location services and try again.',
  ),
  timeout(
    'timeout',
    'Getting your current location is taking longer than expected. Please try again.',
  ),
  providerUnavailable(
    'provider_unavailable',
    'Your device could not provide a current location. Please try again or select a place manually.',
  ),
  unexpectedFailure(
    'unexpected_failure',
    'Could not determine your current location. Please try again.',
  );

  const LocationFailureReason(this.diagnosticCode, this.userMessage);

  final String diagnosticCode;
  final String userMessage;
}

/// Raised when a location or place operation could not resolve a location.
///
/// For current-location failures, [reason] determines safe UI copy and
/// [diagnosticCode] is a stable, non-sensitive internal diagnostic. Native
/// exception text must never be copied into either field.
class LocationServiceException implements Exception {
  const LocationServiceException(
    this.message, {
    this.details,
    this.reason,
    this.diagnosticCode,
  });

  factory LocationServiceException.forReason(
    LocationFailureReason reason, {
    String? diagnosticCode,
  }) =>
      LocationServiceException(
        reason.userMessage,
        reason: reason,
        diagnosticCode: diagnosticCode ?? reason.diagnosticCode,
      );

  final String message;

  /// Optional provider detail retained for diagnostics, never required for UI.
  final String? details;

  /// Structured reason, null for unrelated place-search/reverse-geocode errors.
  final LocationFailureReason? reason;

  /// Safe code such as `timeout` or `platform_exception`; never raw details.
  final String? diagnosticCode;

  /// The only current-location diagnostic suitable for internal logs.
  String? get diagnosticMessage {
    final code = diagnosticCode ?? reason?.diagnosticCode;
    return code == null ? null : 'location_error=$code';
  }

  /// The safe message the requester should see for a classified GPS failure.
  String get userFacingMessage => reason?.userMessage ?? message;

  @override
  String toString() => userFacingMessage;
}

/// The result of the platform GPS permission/service check.
///
/// This is intentionally separate from Geolocator's platform enum. Widgets use
/// this small, platform-neutral result so Android permission handling remains
/// centralized without leaking plugin types into the Web location bridge.
enum LocationPermissionStatus {
  granted,
  serviceDisabled,
  denied,
  deniedForever,
  unavailable,
}

class LocationPermissionResult {
  const LocationPermissionResult({
    required this.status,
    required this.message,
    this.failureReason,
    this.diagnosticCode,
  });

  final LocationPermissionStatus status;
  final String message;

  /// Optional classification when a platform check itself failed.
  final LocationFailureReason? failureReason;

  /// Safe internal code; never includes native exception details.
  final String? diagnosticCode;

  bool get isGranted => status == LocationPermissionStatus.granted;
  bool get isDeniedForever => status == LocationPermissionStatus.deniedForever;

  /// A normal denied state may still present the platform permission prompt.
  /// Disabled services, denied-forever and unavailable states require recovery
  /// UI instead and must not be treated as promptable.
  bool get canRequest => status == LocationPermissionStatus.denied;

  /// Converts a non-granted result to a safe structured location failure.
  LocationServiceException? toLocationServiceException() {
    if (isGranted) return null;

    final fallbackReason = switch (status) {
      LocationPermissionStatus.granted =>
        LocationFailureReason.unexpectedFailure,
      LocationPermissionStatus.serviceDisabled =>
        LocationFailureReason.serviceDisabled,
      LocationPermissionStatus.denied => LocationFailureReason.permissionDenied,
      LocationPermissionStatus.deniedForever =>
        LocationFailureReason.permissionDeniedForever,
      LocationPermissionStatus.unavailable =>
        LocationFailureReason.unexpectedFailure,
    };
    final reason = failureReason ?? fallbackReason;

    return LocationServiceException.forReason(
      reason,
      diagnosticCode: diagnosticCode,
    );
  }
}

/// Check the current service + permission state without showing a runtime
/// permission dialog. This is used to decide whether Google Maps may enable
/// its My Location layer.
Future<LocationPermissionResult> checkDeviceLocationPermission() =>
    impl.checkDeviceLocationPermission();

/// Check the service and request foreground Android permission when needed.
/// A denied-forever result is returned to the caller for recovery UI; this
/// method never fabricates a position and never throws for a normal denial.
Future<LocationPermissionResult> ensureDeviceLocationPermission() =>
    impl.ensureDeviceLocationPermission();

/// Read one real device position after verifying service state and foreground
/// permission. Native implementations retry a timed-out high-accuracy fix with
/// a balanced-accuracy request and throw structured [LocationServiceException]
/// failures rather than silently returning null.
Future<GeoPoint?> readDeviceLocation() => impl.readDeviceLocation();

/// Stream real device positions for responder live sharing. The caller owns
/// and must cancel the returned subscription.
Stream<GeoPoint> watchDeviceLocation() => impl.watchDeviceLocation();

/// Open the relevant Android settings screen for service/permission recovery.
Future<bool> openDeviceLocationSettings() => impl.openDeviceLocationSettings();

abstract class LocationService {
  /// True when the Google Maps JavaScript API (with the places library) is
  /// actually loaded. When false the UI falls back to manual place entry.
  bool get isAvailable;

  /// Latitude/longitude -> human readable place.
  Future<ResolvedPlace> reverseGeocode(double latitude, double longitude);

  /// Place predictions for [query]. When [bias] is provided results are biased
  /// (circle of [biasRadiusMeters]) around the requester's own position.
  Future<List<PlacePrediction>> autocomplete(
    String query, {
    GeoPoint? bias,
    double biasRadiusMeters = 30000,
  });

  /// Resolves a selected prediction into label + exact coordinates.
  Future<ResolvedPlace> resolvePrediction(PlacePrediction prediction);

  /// Google Places API (New) Nearby Search around the requester's position.
  ///
  /// [latitude]/[longitude] are the search center — normally the requester's
  /// current GPS coordinates. Searches a [kNearbySearchRadiusMeters] circle
  /// with `rankPreference = DISTANCE` so the nearest real places come first,
  /// and requests only the fields the UI needs (`id`, `displayName`,
  /// `formattedAddress`, `location`).
  ///
  /// Call policy: only on explicit requester actions (current location
  /// obtained, category selected/refreshed, requester location changed) —
  /// never from responder Socket.IO location updates.
  Future<List<NearbyPlace>> searchNearbyPlaces({
    required double latitude,
    required double longitude,
    required NearbyPlaceCategory category,
    double radiusMeters = kNearbySearchRadiusMeters,
    int maxResults = kNearbySearchMaxResultCount,
  });
}

/// Returns the platform implementation (Google Maps JS on web, unavailable
/// elsewhere). Injectable so widget tests can pass a fake.
LocationService createLocationService() => impl.createPlatformLocationService();
