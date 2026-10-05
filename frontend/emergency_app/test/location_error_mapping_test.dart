import 'dart:async';

import 'package:dispatch_console_flutter/services/location_service.dart';
import 'package:dispatch_console_flutter/services/location_service_stub.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart'
    show
        LocationAccuracy,
        LocationServiceDisabledException,
        PermissionDeniedException;

void main() {
  group('platform-neutral current-location failure mapping', () {
    test('a granted foreground permission is not a failure', () {
      const permission = LocationPermissionResult(
        status: LocationPermissionStatus.granted,
        message: 'granted',
      );

      expect(permission.toLocationServiceException(), isNull);
    });

    test('normal permission denial has its own safe reason and diagnostic', () {
      const permission = LocationPermissionResult(
        status: LocationPermissionStatus.denied,
        message: 'ignored platform copy',
      );

      final failure = permission.toLocationServiceException()!;
      expect(failure.reason, LocationFailureReason.permissionDenied);
      expect(failure.userFacingMessage,
          'Location permission is required to use your current location.');
      expect(failure.diagnosticMessage, 'location_error=permission_denied');
    });

    test('denied forever is distinct from a normal denial', () {
      const permission = LocationPermissionResult(
        status: LocationPermissionStatus.deniedForever,
        message: 'ignored platform copy',
      );

      final failure = permission.toLocationServiceException()!;
      expect(failure.reason, LocationFailureReason.permissionDeniedForever);
      expect(failure.userFacingMessage,
          'Location permission is blocked. Allow it in Android app settings.');
      expect(failure.diagnosticMessage,
          'location_error=permission_denied_forever');
    });

    test('disabled service is not reported as a permission denial', () {
      const permission = LocationPermissionResult(
        status: LocationPermissionStatus.serviceDisabled,
        message: 'ignored platform copy',
      );

      final failure = permission.toLocationServiceException()!;
      expect(failure.reason, LocationFailureReason.serviceDisabled);
      expect(
        failure.userFacingMessage,
        'Location services are turned off. Enable location services and try again.',
      );
      expect(failure.diagnosticMessage, 'location_error=service_disabled');
    });

    test('timeout and provider failures have distinct safe copy', () {
      final timeout = LocationServiceException.forReason(
        LocationFailureReason.timeout,
      );
      final provider = LocationServiceException.forReason(
        LocationFailureReason.providerUnavailable,
      );

      expect(timeout.userFacingMessage,
          'Getting your current location is taking longer than expected. Please try again.');
      expect(timeout.diagnosticMessage, 'location_error=timeout');
      expect(
        provider.userFacingMessage,
        'Your device could not provide a current location. Please try again or select a place manually.',
      );
      expect(provider.diagnosticMessage,
          'location_error=provider_unavailable');
    });

    test('unexpected failures do not expose exception text', () {
      final failure = locationServiceExceptionForError(
        StateError('sensitive native details'),
      );
      final unclassifiedServiceFailure = locationServiceExceptionForError(
        const LocationServiceException('sensitive platform message'),
      );

      for (final mappedFailure in <LocationServiceException>[
        failure,
        unclassifiedServiceFailure,
      ]) {
        expect(mappedFailure.reason, LocationFailureReason.unexpectedFailure);
        expect(
          mappedFailure.userFacingMessage,
          'Could not determine your current location. Please try again.',
        );
        expect(mappedFailure.diagnosticMessage,
            'location_error=unexpected_failure');
        expect(mappedFailure.toString(),
            isNot(contains('sensitive native details')));
        expect(mappedFailure.toString(),
            isNot(contains('sensitive platform message')));
      }
    });

    test('Geolocator permission and service exceptions are classified', () {
      final permission = locationServiceExceptionForError(
        const PermissionDeniedException('private permission detail'),
      );
      final service = locationServiceExceptionForError(
        const LocationServiceDisabledException(),
      );

      expect(permission.reason, LocationFailureReason.permissionDenied);
      expect(permission.diagnosticMessage,
          'location_error=permission_denied');
      expect(permission.toString(),
          'Location permission is required to use your current location.');
      expect(service.reason, LocationFailureReason.serviceDisabled);
      expect(service.diagnosticMessage, 'location_error=service_disabled');
      expect(service.toString(),
          'Location services are turned off. Enable location services and try again.');
    });

    test('platform exceptions retain only a safe diagnostic code', () {
      final failure = locationServiceExceptionForError(
        PlatformException(
          code: 'native_location_channel_failed',
          message: 'private device/provider details',
        ),
      );
      final providerFailure = locationServiceExceptionForError(
        PlatformException(
          code: 'position_unavailable',
          message: 'private provider details',
        ),
      );

      expect(failure.reason, LocationFailureReason.providerUnavailable);
      expect(failure.diagnosticMessage, 'location_error=platform_exception');
      expect(failure.userFacingMessage,
          'Your device could not provide a current location. Please try again or select a place manually.');
      expect(failure.toString(), isNot(contains('private device')));
      expect(providerFailure.reason,
          LocationFailureReason.providerUnavailable);
      expect(providerFailure.diagnosticMessage,
          'location_error=provider_unavailable');
      expect(providerFailure.toString(),
          isNot(contains('private provider details')));
    });

    test('Dart and platform timeouts map to timeout, not permission denial', () {
      final dartFailure = locationServiceExceptionForError(
        TimeoutException('the provider was slow'),
      );
      final platformFailure = locationServiceExceptionForError(
        PlatformException(
          code: 'location_timeout',
          message: 'private platform detail',
        ),
      );

      for (final failure in <LocationServiceException>[
        dartFailure,
        platformFailure,
      ]) {
        expect(failure.reason, LocationFailureReason.timeout);
        expect(failure.diagnosticMessage, 'location_error=timeout');
        expect(
          failure.userFacingMessage,
          'Getting your current location is taking longer than expected. Please try again.',
        );
        expect(failure.toString(), isNot(contains('private platform detail')));
      }
    });

    test('valid coordinates are accepted, invalid and zero/zero rejected', () {
      expect(
        isUsableDeviceLocation(const GeoPoint(9.9816, 76.2999)),
        isTrue,
      );
      expect(isUsableDeviceLocation(const GeoPoint(0, 0)), isFalse);
      expect(isUsableDeviceLocation(const GeoPoint(91, 0)), isFalse);
      expect(isUsableDeviceLocation(const GeoPoint(0, -181)), isFalse);
      expect(
        isUsableDeviceLocation(GeoPoint(double.nan, 76.3)),
        isFalse,
      );
      expect(
        isUsableDeviceLocation(GeoPoint(double.infinity, 76.3)),
        isFalse,
      );
    });
  });

  group('accuracy fallback strategy', () {
    test('high accuracy timeout retries with balanced accuracy', () async {
      final requests = <(LocationAccuracy, Duration)>[];
      final position = Object();

      final result = await acquireLocationWithAccuracyFallback<Object>(
        highAccuracyTimeout: const Duration(milliseconds: 1),
        fallbackTimeout: const Duration(milliseconds: 2),
        acquire: (accuracy, timeLimit) {
          requests.add((accuracy, timeLimit));
          if (accuracy == LocationAccuracy.high) {
            return Future<Object>.error(TimeoutException('high fix timed out'));
          }
          return Future<Object>.value(position);
        },
      );

      expect(identical(result, position), isTrue);
      expect(requests, <(LocationAccuracy, Duration)>[
        (LocationAccuracy.high, const Duration(milliseconds: 1)),
        (LocationAccuracy.medium, const Duration(milliseconds: 2)),
      ]);
    });

    test('fallback timeout is surfaced instead of swallowed', () async {
      var attempts = 0;

      await expectLater(
        acquireLocationWithAccuracyFallback<void>(
          highAccuracyTimeout: const Duration(milliseconds: 1),
          fallbackTimeout: const Duration(milliseconds: 1),
          acquire: (accuracy, _) {
            attempts++;
            return Future<void>.error(TimeoutException('fix timed out'));
          },
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(attempts, 2);
    });

    test('provider failure is not misclassified as a timeout or retried', () async {
      var attempts = 0;
      final providerError = PlatformException(code: 'provider_unavailable');

      await expectLater(
        acquireLocationWithAccuracyFallback<Object>(
          acquire: (accuracy, _) {
            attempts++;
            return Future<Object>.error(providerError);
          },
        ),
        throwsA(same(providerError)),
      );
      expect(attempts, 1);
    });
  });
}
