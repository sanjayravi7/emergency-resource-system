import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter/services.dart' show PlatformException;
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

/// A cold high-accuracy GPS/network fix can take longer than the old 8-second
/// limit. If it times out, request a balanced-accuracy fix (often Wi-Fi/cell)
/// before telling the requester that no position is available.
const Duration kHighAccuracyLocationTimeout = Duration(seconds: 25);
const Duration kFallbackLocationTimeout = Duration(seconds: 15);
const Duration _locationTimeoutGuard = Duration(seconds: 2);

/// Requests [LocationAccuracy.high] first and retries with medium accuracy only
/// when the high-accuracy attempt times out. Both attempts have a hard upper
/// bound, in addition to the Geolocator `timeLimit` passed by the caller.
///
/// Exposed for focused strategy tests; production passes the Geolocator reader.
@visibleForTesting
Future<T> acquireLocationWithAccuracyFallback<T>({
  required Future<T> Function(
    LocationAccuracy accuracy,
    Duration timeLimit,
  ) acquire,
  Duration highAccuracyTimeout = kHighAccuracyLocationTimeout,
  Duration fallbackTimeout = kFallbackLocationTimeout,
}) async {
  Future<T> request(
    LocationAccuracy accuracy,
    Duration timeLimit,
  ) =>
      acquire(accuracy, timeLimit).timeout(timeLimit + _locationTimeoutGuard);

  try {
    return await request(LocationAccuracy.high, highAccuracyTimeout);
  } on TimeoutException {
    return request(LocationAccuracy.medium, fallbackTimeout);
  } on PlatformException catch (error) {
    if (!_isPlatformTimeout(error)) rethrow;
    return request(LocationAccuracy.medium, fallbackTimeout);
  }
}

bool _isPlatformTimeout(PlatformException error) {
  final code = error.code.toLowerCase();
  return code.contains('timeout') || code.contains('timed_out');
}

Future<LocationPermissionResult> checkDeviceLocationPermission() async {
  try {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return _permissionFailureResult(LocationFailureReason.serviceDisabled);
    }

    return _permissionResult(await Geolocator.checkPermission());
  } catch (error) {
    final result = await _permissionResultForException(error);
    _logPermissionDiagnostic(result);
    return result;
  }
}

Future<LocationPermissionResult> ensureDeviceLocationPermission() async {
  try {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return _permissionFailureResult(LocationFailureReason.serviceDisabled);
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      // Geolocator requests foreground permission only. No background
      // permission is requested for the requester's current-location action.
      permission = await Geolocator.requestPermission();
    }
    return _permissionResult(permission);
  } catch (error) {
    final result = await _permissionResultForException(error);
    _logPermissionDiagnostic(result);
    return result;
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
      return _permissionFailureResult(
        LocationFailureReason.permissionDeniedForever,
      );
    case LocationPermission.denied:
      return _permissionFailureResult(LocationFailureReason.permissionDenied);
    case LocationPermission.unableToDetermine:
      return _permissionFailureResult(
        LocationFailureReason.unexpectedFailure,
        diagnosticCode: 'permission_state_unavailable',
      );
  }
}

LocationPermissionResult _permissionFailureResult(
  LocationFailureReason reason, {
  String? diagnosticCode,
}) {
  final status = switch (reason) {
    LocationFailureReason.permissionDenied => LocationPermissionStatus.denied,
    LocationFailureReason.permissionDeniedForever =>
      LocationPermissionStatus.deniedForever,
    LocationFailureReason.serviceDisabled =>
      LocationPermissionStatus.serviceDisabled,
    LocationFailureReason.timeout => LocationPermissionStatus.unavailable,
    LocationFailureReason.providerUnavailable =>
      LocationPermissionStatus.unavailable,
    LocationFailureReason.unexpectedFailure =>
      LocationPermissionStatus.unavailable,
  };
  return LocationPermissionResult(
    status: status,
    message: reason.userMessage,
    failureReason: reason,
    diagnosticCode: diagnosticCode ?? reason.diagnosticCode,
  );
}

Future<LocationPermissionResult> _permissionResultForException(
  Object error,
) async {
  final failure = await _classifyLocationException(error);
  final result = _permissionFailureResult(
    failure.reason ?? LocationFailureReason.unexpectedFailure,
    diagnosticCode: failure.diagnosticCode,
  );
  return result;
}

void _logPermissionDiagnostic(LocationPermissionResult result) {
  final diagnostic = result.toLocationServiceException()?.diagnosticMessage;
  if (diagnostic != null) debugPrint(diagnostic);
}

/// Maps platform exceptions to a stable reason without exposing their raw
/// messages, codes, details, or stack traces to requester UI/logs.
@visibleForTesting
LocationServiceException locationServiceExceptionForError(Object error) {
  if (error is LocationServiceException) {
    if (error.reason != null) return error;
    return LocationServiceException.forReason(
      LocationFailureReason.unexpectedFailure,
    );
  }
  if (error is LocationServiceDisabledException) {
    return LocationServiceException.forReason(
      LocationFailureReason.serviceDisabled,
    );
  }
  if (error is PermissionDeniedException) {
    return LocationServiceException.forReason(
      LocationFailureReason.permissionDenied,
    );
  }
  if (error is TimeoutException) {
    return LocationServiceException.forReason(LocationFailureReason.timeout);
  }
  if (error is PlatformException) {
    final code = error.code.toLowerCase().replaceAll(
          RegExp(r'[^a-z0-9]'),
          '',
        );

    if (code.contains('service') && code.contains('disabled')) {
      return LocationServiceException.forReason(
        LocationFailureReason.serviceDisabled,
      );
    }
    if (code.contains('permission') && code.contains('denied')) {
      return LocationServiceException.forReason(
        LocationFailureReason.permissionDenied,
      );
    }
    if (code.contains('timeout') || code.contains('timedout')) {
      return LocationServiceException.forReason(
        LocationFailureReason.timeout,
      );
    }
    if (code.contains('provider') || code.contains('unavailable')) {
      return LocationServiceException.forReason(
        LocationFailureReason.providerUnavailable,
      );
    }

    // An unrecognized native location-channel error is a provider failure,
    // with only a safe diagnostic code retained for internal support.
    return LocationServiceException.forReason(
      LocationFailureReason.providerUnavailable,
      diagnosticCode: 'platform_exception',
    );
  }

  return LocationServiceException.forReason(
    LocationFailureReason.unexpectedFailure,
  );
}

Future<LocationServiceException> _classifyLocationException(
  Object error,
) async {
  final failure = locationServiceExceptionForError(error);
  if (failure.reason != LocationFailureReason.permissionDenied) return failure;

  // A denied exception can be raised after the initial permission check if the
  // OS permission changed mid-request. Only report "blocked" when Geolocator's
  // current permission enum explicitly confirms deniedForever.
  try {
    if (await Geolocator.checkPermission() == LocationPermission.deniedForever) {
      return LocationServiceException.forReason(
        LocationFailureReason.permissionDeniedForever,
      );
    }
  } catch (_) {
    // Keep the original denial classification; never replace it with raw
    // details from a failed diagnostic permission check.
  }
  return failure;
}

Future<GeoPoint?> readDeviceLocation() async {
  try {
    // Service state and foreground permission are rechecked here as well as in
    // the UI caller, so direct callers cannot read without a current grant.
    final permission = await ensureDeviceLocationPermission();
    final permissionFailure = permission.toLocationServiceException();
    if (permissionFailure != null) throw permissionFailure;

    final position = await acquireLocationWithAccuracyFallback<Position>(
      acquire: (accuracy, timeLimit) => Geolocator.getCurrentPosition(
        locationSettings: LocationSettings(
          accuracy: accuracy,
          timeLimit: timeLimit,
        ),
      ),
    );

    final point = GeoPoint(position.latitude, position.longitude);
    if (!isUsableDeviceLocation(point)) {
      throw LocationServiceException.forReason(
        LocationFailureReason.providerUnavailable,
      );
    }
    return point;
  } catch (error) {
    final failure = await _classifyLocationException(error);
    final diagnostic = failure.diagnosticMessage;
    if (diagnostic != null) debugPrint(diagnostic);
    throw failure;
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
