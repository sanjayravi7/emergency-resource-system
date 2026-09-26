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
class PlacesApiDisabledException implements LocationServiceException {
  const PlacesApiDisabledException({this.details});

  /// Exact message the requester sees in the NEARBY PLACES section.
  static const String userMessage =
      'Nearby places unavailable. Enable Places API (New) in Google Cloud.';

  @override
  String get message => userMessage;

  /// Original Google error text, kept for logging/debugging.
  final String? details;

  @override
  String toString() => userMessage;
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
bool isPlacesApiDisabledError(String message) {
  final text = message.toLowerCase();
  if (text.contains('places api (new) has not been used')) return true;
  if (text.contains('places api') && text.contains('disabled')) return true;
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

/// Raised when Google could not resolve a location. The caller must keep the
/// coordinates it already has and must not invent a place name.
class LocationServiceException implements Exception {
  const LocationServiceException(this.message);

  final String message;

  @override
  String toString() => message;
}

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
