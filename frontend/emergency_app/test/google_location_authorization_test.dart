import 'package:dispatch_console_flutter/services/location_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Part A/B regression guards.
///
/// The browser reported two distinct Google Cloud authorization failures:
///
///   GEOCODER_GEOCODE: REQUEST_DENIED: The webpage is not allowed to use the
///   geocoder.
///
///   Requests to this API places.googleapis.com method
///   google.maps.places.v1.Places.AutocompletePlaces are blocked.
///
/// Both are key/API-restriction problems, and ERAS must classify them as such
/// (to show the right guidance) without ever hiding the raw Google text.
void main() {
  group('isGeocodingApiDeniedError', () {
    test('recognises the Maps JS geocoder denial verbatim', () {
      expect(
        isGeocodingApiDeniedError(
          'GEOCODER_GEOCODE: REQUEST_DENIED: The webpage is not allowed to '
          'use the geocoder.',
        ),
        isTrue,
      );
    });

    test('recognises a disabled Geocoding API and a referrer rejection', () {
      expect(
        isGeocodingApiDeniedError(
          'Geocoding API has not been used in project 123 before or it is disabled.',
        ),
        isTrue,
      );
      expect(isGeocodingApiDeniedError('RefererNotAllowedMapError'), isTrue);
      expect(isGeocodingApiDeniedError('ApiTargetBlockedMapError'), isTrue);
    });

    test(
      'does not treat an empty Google answer as an authorization failure',
      () {
        expect(isGeocodingApiDeniedError('ZERO_RESULTS'), isFalse);
        expect(
          isGeocodingApiDeniedError('No address found for these coordinates.'),
          isFalse,
        );
        expect(isGeocodingApiDeniedError('OVER_QUERY_LIMIT'), isFalse);
      },
    );

    test('the hint names the Google Cloud settings that must be fixed', () {
      expect(kGeocodingApiDeniedHint, contains('Geocoding API'));
      expect(kGeocodingApiDeniedHint, contains('API restrictions'));
      expect(kGeocodingApiDeniedHint, contains('HTTP referrer'));
    });
  });

  group('isPlacesApiDisabledError', () {
    test('recognises the blocked Places API (New) v1 method', () {
      expect(
        isPlacesApiDisabledError(
          'Requests to this API places.googleapis.com method '
          'google.maps.places.v1.Places.AutocompletePlaces are blocked.',
        ),
        isTrue,
      );
    });

    test('recognises a project that never enabled Places API (New)', () {
      expect(
        isPlacesApiDisabledError(
          'Places API (New) has not been used in project 3804150054 before or '
          'it is disabled.',
        ),
        isTrue,
      );
      expect(isPlacesApiDisabledError('REQUEST_DENIED'), isTrue);
      expect(isPlacesApiDisabledError('ApiTargetBlockedMapError'), isTrue);
    });

    test('keeps the graceful user message stable', () {
      expect(
        PlacesApiDisabledException.userMessage,
        'Nearby places unavailable. Enable Places API (New) in Google Cloud.',
      );
    });
  });
}
