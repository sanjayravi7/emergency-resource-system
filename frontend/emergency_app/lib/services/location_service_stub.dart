import 'location_service.dart';

/// Non-web implementation. ERAS resolves places through the Google Maps
/// JavaScript API that Flutter Web already loads, so on the VM/mobile targets
/// the service reports itself unavailable instead of fabricating results.
class UnavailableLocationService implements LocationService {
  const UnavailableLocationService();

  static const _message =
      'Place lookup is only available in the web build, where the Google Maps '
      'JavaScript API is loaded.';

  @override
  bool get isAvailable => false;

  @override
  Future<ResolvedPlace> reverseGeocode(
    double latitude,
    double longitude,
  ) async {
    throw const LocationServiceException(_message);
  }

  @override
  Future<List<PlacePrediction>> autocomplete(
    String query, {
    GeoPoint? bias,
    double biasRadiusMeters = 30000,
  }) async {
    throw const LocationServiceException(_message);
  }

  @override
  Future<ResolvedPlace> resolvePrediction(PlacePrediction prediction) async {
    throw const LocationServiceException(_message);
  }

  @override
  Future<List<NearbyPlace>> searchNearbyPlaces({
    required double latitude,
    required double longitude,
    required NearbyPlaceCategory category,
    double radiusMeters = kNearbySearchRadiusMeters,
    int maxResults = kNearbySearchMaxResultCount,
  }) async {
    // Nearby Search needs the Places API (New), which only the web build can
    // reach through the Maps JavaScript API bridge. Nothing is fabricated.
    throw const LocationServiceException(_message);
  }
}

LocationService createPlatformLocationService() =>
    const UnavailableLocationService();
