import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'location_service.dart';

/// Flutter Web implementation.
///
/// All Google calls are made by `web/eras_location_bridge.js`, which talks to
/// the Maps JavaScript API that `web/index.html` already loads with the
/// referrer-restricted browser key from `web/google_maps_config.js`:
///
///   * reverse geocoding -> google.maps.Geocoder
///   * autocomplete      -> google.maps.places.AutocompleteSuggestion
///                          (Place Autocomplete Data API, new)
///                          with a legacy AutocompleteService fallback
///   * prediction detail -> google.maps.places.Place#fetchFields(location)
///   * nearby places     -> google.maps.places.Place.searchNearby
///                          (Nearby Search (New): circle + includedTypes +
///                          rankPreference DISTANCE)
///
/// The bridge always resolves with a JSON string so the Dart side never has to
/// walk untyped JS objects.
class WebLocationService implements LocationService {
  const WebLocationService();

  static const _bridgeName = 'erasLocationBridge';

  JSObject? get _bridge {
    if (!globalContext.hasProperty(_bridgeName.toJS).toDart) return null;
    final bridge = globalContext.getProperty<JSAny?>(_bridgeName.toJS);
    // `is`/`is!` against a dart:js_interop type is not platform-consistent
    // (JS values are not differentiated at runtime on Wasm), so use the
    // supported `isA<JSObject>()` interop check instead.
    if (bridge == null || !bridge.isA<JSObject>()) return null;
    return bridge as JSObject;
  }

  @override
  bool get isAvailable {
    final bridge = _bridge;
    if (bridge == null) return false;
    final available = bridge.callMethod<JSBoolean?>('isAvailable'.toJS);
    return available?.toDart ?? false;
  }

  Future<Map<String, dynamic>> _call(
    String method,
    List<JSAny?> args,
  ) async {
    final bridge = _bridge;
    if (bridge == null) {
      throw const LocationServiceException(
        'Google Maps JavaScript API is not loaded, so places cannot be '
        'resolved. Configure web/google_maps_config.js.',
      );
    }

    final JSAny? raw;
    try {
      final promise = bridge.callMethodVarArgs<JSPromise>(
        method.toJS,
        args,
      );
      raw = await promise.toDart;
    } catch (error) {
      throw LocationServiceException('Google place lookup failed: $error');
    }

    if (raw == null) {
      throw const LocationServiceException('Google place lookup returned no data.');
    }

    final decoded = jsonDecode((raw as JSString).toDart);
    if (decoded is! Map) {
      throw const LocationServiceException('Unexpected Google response.');
    }

    final map = Map<String, dynamic>.from(decoded);
    if (map['ok'] != true) {
      throw LocationServiceException(
        (map['error'] as String?) ?? 'Google place lookup failed.',
      );
    }
    return map;
  }

  @override
  Future<ResolvedPlace> reverseGeocode(double latitude, double longitude) async {
    final result = await _call(
      'reverseGeocode',
      <JSAny?>[latitude.toJS, longitude.toJS],
    );

    final label = (result['label'] as String?)?.trim() ?? '';
    if (label.isEmpty) {
      throw const LocationServiceException(
        'Google returned no address for these coordinates.',
      );
    }

    // The coordinates the caller passed in stay canonical: reverse geocoding
    // only produces the human readable label.
    return ResolvedPlace(
      label: label,
      latitude: latitude,
      longitude: longitude,
      placeId: result['placeId'] as String?,
    );
  }

  @override
  Future<List<PlacePrediction>> autocomplete(
    String query, {
    GeoPoint? bias,
    double biasRadiusMeters = 30000,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const <PlacePrediction>[];

    final result = await _call('autocomplete', <JSAny?>[
      trimmed.toJS,
      bias?.latitude.toJS,
      bias?.longitude.toJS,
      biasRadiusMeters.toJS,
    ]);

    final predictions = (result['predictions'] as List?) ?? const <dynamic>[];
    return predictions
        .whereType<Map>()
        .map(
          (item) => PlacePrediction(
            placeId: (item['placeId'] as String?) ?? '',
            primaryText: (item['primaryText'] as String?) ?? '',
            secondaryText: (item['secondaryText'] as String?) ?? '',
          ),
        )
        .where((p) => p.placeId.isNotEmpty && p.primaryText.isNotEmpty)
        .toList(growable: false);
  }

  @override
  Future<ResolvedPlace> resolvePrediction(PlacePrediction prediction) async {
    final result = await _call(
      'placeDetails',
      <JSAny?>[prediction.placeId.toJS],
    );

    final latitude = (result['latitude'] as num?)?.toDouble();
    final longitude = (result['longitude'] as num?)?.toDouble();

    if (latitude == null || longitude == null) {
      throw const LocationServiceException(
        'Google returned no coordinates for the selected place.',
      );
    }

    final label = (result['label'] as String?)?.trim();

    return ResolvedPlace(
      label: (label == null || label.isEmpty) ? prediction.fullText : label,
      latitude: latitude,
      longitude: longitude,
      placeId: prediction.placeId,
    );
  }

  @override
  Future<List<NearbyPlace>> searchNearbyPlaces({
    required double latitude,
    required double longitude,
    required NearbyPlaceCategory category,
    double radiusMeters = kNearbySearchRadiusMeters,
    int maxResults = kNearbySearchMaxResultCount,
  }) async {
    // Nearby Search (New) bounds: 0 < radius <= 50000 m, 1..20 results.
    final radius = radiusMeters.clamp(1.0, 50000.0).toDouble();
    final limit = maxResults.clamp(1, 20).toInt();
    final types = category.googleTypes
        .map((type) => type.toJS)
        .toList()
        .toJS; // JSArray<JSString>

    final Map<String, dynamic> result;
    try {
      result = await _call('searchNearby', <JSAny?>[
        latitude.toJS,
        longitude.toJS,
        types,
        radius.toJS,
        limit.toJS,
      ]);
    } on LocationServiceException catch (error) {
      // The screenshot failure mode: Places API (New) disabled/not enabled.
      // Surface it as a distinct, actionable error so the NEARBY PLACES
      // section can degrade gracefully without touching the rest of the form.
      if (isPlacesApiDisabledError(error.message)) {
        throw PlacesApiDisabledException(details: error.message);
      }
      rethrow;
    }

    final places = (result['places'] as List?) ?? const <dynamic>[];
    return places
        .whereType<Map>()
        .map((item) {
          final placeLatitude = (item['latitude'] as num?)?.toDouble();
          final placeLongitude = (item['longitude'] as num?)?.toDouble();
          final placeId = (item['placeId'] as String?) ?? '';
          final name = (item['name'] as String?) ?? '';

          if (placeLatitude == null ||
              placeLongitude == null ||
              placeId.isEmpty ||
              name.isEmpty) {
            return null;
          }

          return NearbyPlace(
            placeId: placeId,
            name: name,
            address: (item['address'] as String?) ?? '',
            latitude: placeLatitude,
            longitude: placeLongitude,
            // Straight-line distance from the requester's own position.
            distanceMeters: NearbyPlace.haversineDistanceMeters(
              latitude,
              longitude,
              placeLatitude,
              placeLongitude,
            ),
          );
        })
        .whereType<NearbyPlace>()
        .toList(growable: false);
  }
}

LocationService createPlatformLocationService() => const WebLocationService();
