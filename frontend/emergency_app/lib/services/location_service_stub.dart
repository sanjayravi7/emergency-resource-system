import 'package:geolocator/geolocator.dart';

import '../models/eras_models.dart' show isValidCoordinatePair;
import 'location_service.dart';

/// Non-web place lookup remains unavailable because the Places JavaScript
/// bridge is a Web-only feature. GPS permission/position access, however, is
/// implemented here for Android and other IO targets so requester and
/// responder flows share one permission pipeline.
class UnavailableLocationService implements LocationService {
  const UnavailableLocationService();

  static const _message =
      'Place lookup is only available in the web build, where the Google Maps '
      'JavaScript API is loaded.';

  @override
  bool get isAvailable => false;

  @override
  Future<ResolvedPlace> reverseGeocode(
      double latitude, double longitude) async {
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

Future<LocationPermissionResult> checkDeviceLocationPermission() async {
  try {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return const LocationPermissionResult(
        status: LocationPermissionStatus.serviceDisabled,
        message: 'Location services are disabled. Turn on device location.',
      );
    }

    final permission = await Geolocator.checkPermission();
    return _permissionResult(permission);
  } catch (_) {
    return const LocationPermissionResult(
      status: LocationPermissionStatus.unavailable,
      message: 'The device location service is unavailable.',
    );
  }
}

Future<LocationPermissionResult> ensureDeviceLocationPermission() async {
  try {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return const LocationPermissionResult(
        status: LocationPermissionStatus.serviceDisabled,
        message: 'Location services are disabled. Turn on device location.',
      );
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    return _permissionResult(permission);
  } catch (_) {
    return const LocationPermissionResult(
      status: LocationPermissionStatus.unavailable,
      message: 'The device location service is unavailable.',
    );
  }
}

LocationPermissionResult _permissionResult(LocationPermission permission) {
  switch (permission) {
    case LocationPermission.always:
    case LocationPermission.whileInUse:
      return const LocationPermissionResult(
        status: LocationPermissionStatus.granted,
        message: 'Location permission granted.',
      );
    case LocationPermission.deniedForever:
      return const LocationPermissionResult(
        status: LocationPermissionStatus.deniedForever,
        message:
            'Location permission is blocked. Allow it in Android app settings.',
      );
    case LocationPermission.denied:
    case LocationPermission.unableToDetermine:
      return const LocationPermissionResult(
        status: LocationPermissionStatus.denied,
        message: 'Location permission was not granted.',
      );
  }
}

Future<GeoPoint?> readDeviceLocation() async {
  try {
    final position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
    ).timeout(const Duration(seconds: 8));
    if (!isValidCoordinatePair(position.latitude, position.longitude)) {
      return null;
    }
    return GeoPoint(position.latitude, position.longitude);
  } catch (_) {
    return null;
  }
}

Stream<GeoPoint> watchDeviceLocation() => Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      ),
    )
        .where(
          (position) =>
              isValidCoordinatePair(position.latitude, position.longitude),
        )
        .map((position) => GeoPoint(position.latitude, position.longitude));

Future<bool> openDeviceLocationSettings() async {
  try {
    final current = await checkDeviceLocationPermission();
    if (current.status == LocationPermissionStatus.serviceDisabled) {
      return await Geolocator.openLocationSettings();
    }
    return await Geolocator.openAppSettings();
  } catch (_) {
    return false;
  }
}

LocationService createPlatformLocationService() =>
    const UnavailableLocationService();
