import 'package:geolocator/geolocator.dart';

import '../models/eras_models.dart' show isValidCoordinatePair;
import 'api_service.dart';
import 'location_service.dart';

/// Real native/mobile place lookup implementation for Android and other IO targets.
///
/// Talks to the authenticated ERAS backend endpoints which query Google Places
/// API (New) REST on the server, keeping Google API credentials and quota
/// enforcement out of the mobile APK.
class NativeLocationService implements LocationService {
  const NativeLocationService();

  @override
  bool get isAvailable => true;

  @override
  Future<ResolvedPlace> reverseGeocode(
    double latitude,
    double longitude,
  ) async {
    if (!isValidCoordinatePair(latitude, longitude) ||
        (latitude == 0.0 && longitude == 0.0)) {
      throw const LocationServiceException(
        'Invalid coordinates provided for reverse geocoding.',
      );
    }

    try {
      final result = await ApiService.reverseGeocode(
        latitude: latitude,
        longitude: longitude,
      );
      final label = (result['displayName'] as String?)?.trim() ?? '';
      if (label.isEmpty) {
        throw const LocationServiceException(
          'The reverse geocoding service returned no address.',
        );
      }
      return ResolvedPlace(
        label: label,
        latitude: latitude,
        longitude: longitude,
      );
    } on LocationServiceException {
      rethrow;
    } catch (error) {
      throw LocationServiceException('Reverse geocoding failed: $error');
    }
  }

  @override
  Future<List<PlacePrediction>> autocomplete(
    String query, {
    GeoPoint? bias,
    double biasRadiusMeters = 30000,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const <PlacePrediction>[];

    final hasValidBias = bias != null &&
        isValidCoordinatePair(bias.latitude, bias.longitude) &&
        !(bias.latitude == 0.0 && bias.longitude == 0.0);

    try {
      final rawList = await ApiService.autocompletePlaces(
        query: trimmed,
        latitude: hasValidBias ? bias.latitude : null,
        longitude: hasValidBias ? bias.longitude : null,
        radiusMeters: biasRadiusMeters,
      );

      return rawList
          .map(
            (item) => PlacePrediction(
              placeId: (item['placeId'] as String?) ?? '',
              primaryText: (item['primaryText'] as String?) ?? '',
              secondaryText: (item['secondaryText'] as String?) ?? '',
            ),
          )
          .where((p) => p.placeId.isNotEmpty && p.primaryText.isNotEmpty)
          .toList(growable: false);
    } catch (error) {
      final message = error.toString().replaceFirst('Exception: ', '').trim();
      if (isPlacesApiDisabledError(message)) {
        throw PlacesApiDisabledException(details: message);
      }
      throw LocationServiceException('Place search failed: $message');
    }
  }

  @override
  Future<ResolvedPlace> resolvePrediction(PlacePrediction prediction) async {
    if (prediction.placeId.trim().isEmpty) {
      throw const LocationServiceException('Invalid place prediction.');
    }

    try {
      final result = await ApiService.resolvePlaceDetails(
        placeId: prediction.placeId.trim(),
      );

      final latitude = (result['latitude'] as num?)?.toDouble();
      final longitude = (result['longitude'] as num?)?.toDouble();

      if (latitude == null ||
          longitude == null ||
          !isValidCoordinatePair(latitude, longitude) ||
          (latitude == 0.0 && longitude == 0.0)) {
        throw const LocationServiceException(
          'Google returned no valid coordinates for the selected place.',
        );
      }

      final label = (result['label'] as String?)?.trim();

      return ResolvedPlace(
        label: (label == null || label.isEmpty) ? prediction.fullText : label,
        latitude: latitude,
        longitude: longitude,
        placeId: prediction.placeId,
      );
    } on LocationServiceException {
      rethrow;
    } catch (error) {
      final message = error.toString().replaceFirst('Exception: ', '').trim();
      throw LocationServiceException('Could not resolve place: $message');
    }
  }

  @override
  Future<List<NearbyPlace>> searchNearbyPlaces({
    required double latitude,
    required double longitude,
    required NearbyPlaceCategory category,
    double radiusMeters = kNearbySearchRadiusMeters,
    int maxResults = kNearbySearchMaxResultCount,
  }) async {
    if (!isValidCoordinatePair(latitude, longitude) ||
        (latitude == 0.0 && longitude == 0.0)) {
      throw const LocationServiceException(
        'Invalid coordinates provided for nearby search.',
      );
    }

    try {
      final rawPlaces = await ApiService.searchNearbyPlaces(
        latitude: latitude,
        longitude: longitude,
        category: category.name,
        radiusMeters: radiusMeters,
        maxResults: maxResults,
      );

      final places = rawPlaces
          .map((item) {
            final placeLat = (item['latitude'] as num?)?.toDouble();
            final placeLng = (item['longitude'] as num?)?.toDouble();
            final placeId = (item['placeId'] as String?) ?? '';
            final name = (item['name'] as String?) ?? '';

            if (placeLat == null ||
                placeLng == null ||
                !isValidCoordinatePair(placeLat, placeLng) ||
                (placeLat == 0.0 && placeLng == 0.0) ||
                placeId.isEmpty ||
                name.isEmpty) {
              return null;
            }

            final serverDistance = (item['distanceMeters'] as num?)?.toDouble();
            final distance = serverDistance ??
                NearbyPlace.haversineDistanceMeters(
                  latitude,
                  longitude,
                  placeLat,
                  placeLng,
                );

            return NearbyPlace(
              placeId: placeId,
              name: name,
              address: (item['address'] as String?) ?? '',
              latitude: placeLat,
              longitude: placeLng,
              distanceMeters: distance,
            );
          })
          .whereType<NearbyPlace>()
          .toList();

      places.sort(
        (a, b) => (a.distanceMeters ?? 0).compareTo(b.distanceMeters ?? 0),
      );
      return List<NearbyPlace>.unmodifiable(places);
    } catch (error) {
      final message = error.toString().replaceFirst('Exception: ', '').trim();
      if (isPlacesApiDisabledError(message)) {
        throw PlacesApiDisabledException(details: message);
      }
      throw LocationServiceException('Nearby search failed: $message');
    }
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
    const NativeLocationService();
