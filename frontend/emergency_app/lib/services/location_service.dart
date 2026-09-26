/// Reusable location resolution service for ERAS.
///
/// Responsibilities:
///   * reverse geocoding (latitude/longitude -> human readable place)
///   * place autocomplete predictions (biased to the requester location)
///   * resolving a selected prediction back to exact coordinates
///
/// Architectural rules honoured here:
///   * latitude/longitude stay the canonical, precise location.
///   * the human readable place text is only a label for those coordinates.
///   * no coordinate is ever fabricated; failures surface as exceptions.
///   * on Flutter Web every call goes through the already-loaded Google Maps
///     JavaScript API (Geocoder + Places library), so the referrer restricted
///     browser key configured in web/google_maps_config.js is reused and no
///     key is ever embedded in Dart or backend source.
library;

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
}

/// Returns the platform implementation (Google Maps JS on web, unavailable
/// elsewhere). Injectable so widget tests can pass a fake.
LocationService createLocationService() => impl.createPlatformLocationService();
