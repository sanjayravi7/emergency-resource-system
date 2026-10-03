import 'dart:convert';

import 'package:dispatch_console_flutter/services/api_service.dart';
import 'package:dispatch_console_flutter/services/location_service.dart';
import 'package:dispatch_console_flutter/services/location_service_stub.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  setUp(() {
    ApiService.token = 'test-token';
  });

  tearDown(() {
    ApiService.token = null;
  });

  group('NativeLocationService', () {
    const service = NativeLocationService();

    test('isAvailable is true on native/Android', () {
      expect(service.isAvailable, isTrue);
    });

    test('reverseGeocode maps displayName to ResolvedPlace', () async {
      await http.runWithClient(() async {
        final place = await service.reverseGeocode(9.9816, 76.2999);
        expect(place.label, 'Kolenchery, Kerala, India');
        expect(place.latitude, 9.9816);
        expect(place.longitude, 76.2999);
      }, () => MockClient((request) async {
        expect(request.url.path, '/api/location/reverse');
        expect(request.url.queryParameters['latitude'], '9.9816');
        expect(request.url.queryParameters['longitude'], '76.2999');
        return http.Response(
          jsonEncode({
            'success': true,
            'data': {
              'displayName': 'Kolenchery, Kerala, India',
              'latitude': 9.9816,
              'longitude': 76.2999,
            },
          }),
          200,
        );
      }));
    });

    test('reverseGeocode rejects (0, 0) coordinates without making request', () async {
      expect(
        () => service.reverseGeocode(0.0, 0.0),
        throwsA(isA<LocationServiceException>()),
      );
    });

    test('autocomplete maps predictions and passes location bias', () async {
      await http.runWithClient(() async {
        final predictions = await service.autocomplete(
          'Government Hospital',
          bias: const GeoPoint(9.9816, 76.2999),
          biasRadiusMeters: 30000,
        );

        expect(predictions, hasLength(2));
        expect(predictions[0].placeId, 'place_1');
        expect(predictions[0].primaryText, 'Government Hospital');
        expect(predictions[0].secondaryText, 'Kolenchery');
        expect(predictions[1].placeId, 'place_2');
        expect(predictions[1].primaryText, 'Taluk Hospital');
      }, () => MockClient((request) async {
        expect(request.url.path, '/api/location/autocomplete');
        expect(request.url.queryParameters['query'], 'Government Hospital');
        expect(request.url.queryParameters['latitude'], '9.9816');
        expect(request.url.queryParameters['longitude'], '76.2999');
        return http.Response(
          jsonEncode({
            'success': true,
            'data': {
              'predictions': [
                {
                  'placeId': 'place_1',
                  'primaryText': 'Government Hospital',
                  'secondaryText': 'Kolenchery',
                },
                {
                  'placeId': 'place_2',
                  'primaryText': 'Taluk Hospital',
                  'secondaryText': '',
                },
              ],
            },
          }),
          200,
        );
      }));
    });

    test('autocomplete returns empty list for whitespace query without request', () async {
      final results = await service.autocomplete('   ');
      expect(results, isEmpty);
    });

    test('resolvePrediction maps canonical coordinates from selected place', () async {
      await http.runWithClient(() async {
        const prediction = PlacePrediction(
          placeId: 'place_gh_123',
          primaryText: 'Government Hospital',
          secondaryText: 'Kolenchery',
        );

        final resolved = await service.resolvePrediction(prediction);
        expect(resolved.placeId, 'place_gh_123');
        expect(resolved.latitude, 9.9795);
        expect(resolved.longitude, 76.4712);
        expect(resolved.label, 'Government Hospital, Kolenchery, Kerala');
      }, () => MockClient((request) async {
        expect(request.url.path, '/api/location/details');
        expect(request.url.queryParameters['placeId'], 'place_gh_123');
        return http.Response(
          jsonEncode({
            'success': true,
            'data': {
              'placeId': 'place_gh_123',
              'label': 'Government Hospital, Kolenchery, Kerala',
              'latitude': 9.9795,
              'longitude': 76.4712,
            },
          }),
          200,
        );
      }));
    });

    test('resolvePrediction rejects zero coordinates (0, 0)', () async {
      await http.runWithClient(() async {
        const prediction = PlacePrediction(
          placeId: 'place_zero',
          primaryText: 'Zero Place',
        );

        expect(
          () => service.resolvePrediction(prediction),
          throwsA(isA<LocationServiceException>()),
        );
      }, () => MockClient((request) async {
        return http.Response(
          jsonEncode({
            'success': true,
            'data': {
              'placeId': 'place_zero',
              'label': 'Zero Place',
              'latitude': 0.0,
              'longitude': 0.0,
            },
          }),
          200,
        );
      }));
    });

    test('searchNearbyPlaces returns places ranked by distance', async () async {
      await http.runWithClient(() async {
        final places = await service.searchNearbyPlaces(
          latitude: 9.9800,
          longitude: 76.3000,
          category: NearbyPlaceCategory.hospital,
          radiusMeters: 5000,
          maxResults: 10,
        );

        expect(places, hasLength(2));
        expect(places[0].placeId, 'hosp_close');
        expect(places[0].name, 'City Clinic');
        expect(places[1].placeId, 'hosp_far');
        expect(places[1].name, 'General Hospital');
        expect(places[0].distanceMeters!, lessThan(places[1].distanceMeters!));
      }, () => MockClient((request) async {
        expect(request.url.path, '/api/location/nearby');
        expect(request.url.queryParameters['category'], 'hospital');
        expect(request.url.queryParameters['latitude'], '9.98');
        expect(request.url.queryParameters['longitude'], '76.3');
        return http.Response(
          jsonEncode({
            'success': true,
            'data': {
              'places': [
                {
                  'placeId': 'hosp_close',
                  'name': 'City Clinic',
                  'address': 'MG Rd',
                  'latitude': 9.9810,
                  'longitude': 76.3010,
                  'distanceMeters': 150,
                },
                {
                  'placeId': 'hosp_far',
                  'name': 'General Hospital',
                  'address': 'Ring Rd',
                  'latitude': 9.9950,
                  'longitude': 76.3150,
                  'distanceMeters': 2300,
                },
              ],
            },
          }),
          200,
        );
      }));
    });

    test('searchNearbyPlaces surfaces PlacesApiDisabledException when disabled', () async {
      await http.runWithClient(() async {
        expect(
          () => service.searchNearbyPlaces(
            latitude: 9.98,
            longitude: 76.30,
            category: NearbyPlaceCategory.hospital,
          ),
          throwsA(isA<PlacesApiDisabledException>()),
        );
      }, () => MockClient((request) async {
        return http.Response(
          jsonEncode({
            'success': false,
            'message':
              'Nearby places unavailable. Enable Places API (New) in Google Cloud.',
            'code': 'PLACES_API_DISABLED',
          }),
          502,
        );
      }));
    });
  });
}
