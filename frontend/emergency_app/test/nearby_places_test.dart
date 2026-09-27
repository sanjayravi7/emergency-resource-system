import 'package:dispatch_console_flutter/services/live_location_store.dart';
import 'package:dispatch_console_flutter/models/eras_models.dart';
import 'package:dispatch_console_flutter/services/location_service.dart';
import 'package:dispatch_console_flutter/widgets/new_request_panel.dart';
import 'package:dispatch_console_flutter/widgets/requester_location_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;

/// Fake Google-backed location service that records every call, so the tests
/// can prove exactly when Nearby Search (New) runs and with which
/// center/category — and that autocomplete/reverse geocoding stay untouched.
class NearbyRecordingLocationService implements LocationService {
  NearbyRecordingLocationService({
    this.nearbyResults = const <NearbyPlace>[],
    this.nearbyError,
    this.predictions = const <PlacePrediction>[],
    this.reverseLabel = 'Kolenchery, Kerala',
    this.reverseError,
  });

  List<NearbyPlace> nearbyResults;

  /// Exception thrown by searchNearbyPlaces (for example
  /// [PlacesApiDisabledException] when Places API (New) is disabled).
  Object? nearbyError;

  List<PlacePrediction> predictions;
  String reverseLabel;
  String? reverseError;

  final List<({
    double latitude,
    double longitude,
    NearbyPlaceCategory category,
    double radiusMeters,
  })> nearbyCalls = [];

  final List<GeoPoint> reverseGeocodeCalls = <GeoPoint>[];
  final List<String> autocompleteCalls = <String>[];

  @override
  bool get isAvailable => true;

  @override
  Future<ResolvedPlace> reverseGeocode(double latitude, double longitude) async {
    reverseGeocodeCalls.add(GeoPoint(latitude, longitude));
    if (reverseError != null) {
      throw LocationServiceException(reverseError!);
    }
    return ResolvedPlace(
      label: reverseLabel,
      latitude: latitude,
      longitude: longitude,
    );
  }

  @override
  Future<List<PlacePrediction>> autocomplete(
    String query, {
    GeoPoint? bias,
    double biasRadiusMeters = 30000,
  }) async {
    autocompleteCalls.add(query);
    return predictions;
  }

  @override
  Future<ResolvedPlace> resolvePrediction(PlacePrediction prediction) async {
    return ResolvedPlace(
      label: prediction.fullText,
      latitude: 9.99,
      longitude: 76.66,
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
    nearbyCalls.add((
      latitude: latitude,
      longitude: longitude,
      category: category,
      radiusMeters: radiusMeters,
    ));
    if (nearbyError != null) throw nearbyError!;
    return nearbyResults;
  }
}

const BackendResource _ambulance = BackendResource(
  id: 1,
  name: 'Ambulance',
  type: 'VEHICLE',
  totalQuantity: 5,
  availableQuantity: 5,
  isActive: true,
  lowStockThreshold: 1,
  unit: 'units',
);

const List<NearbyPlace> _hospitals = <NearbyPlace>[
  NearbyPlace(
    placeId: 'place-hospital-a',
    name: 'Hospital A',
    address: 'Main Road, Kolenchery',
    latitude: 9.991,
    longitude: 76.662,
    distanceMeters: 1200,
  ),
  NearbyPlace(
    placeId: 'place-hospital-b',
    name: 'Hospital B',
    address: 'Church Road, Kolenchery',
    latitude: 9.995,
    longitude: 76.658,
    distanceMeters: 2000,
  ),
];

Finder _descriptionField() => find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.hintText ==
              'What happened, how many people are affected…',
    );

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

/// The requester form is a tall page; give the test a realistically sized
/// surface so every tap stays inside the render tree (same approach as
/// requester_location_test.dart).
void _useDesktopSizedSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 1800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _scrollIntoViewAndTap(WidgetTester tester, Finder finder) async {
  expect(finder, findsOneWidget);
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// Hosts [RequesterLocationPicker] while really storing the coordinates it
/// reports, exactly like [NewRequestPanel] does in production.
Future<void> _pumpPicker(
  WidgetTester tester, {
  required NearbyRecordingLocationService service,
  required TextEditingController placeController,
  required Future<GeoPoint?> Function() gps,
  Duration searchDebounce = const Duration(milliseconds: 350),
  GlobalKey<State<RequesterLocationPicker>>? key,
}) {
  double? latitude;
  double? longitude;

  return tester.pumpWidget(_host(StatefulBuilder(
    builder: (context, setState) => RequesterLocationPicker(
      key: key,
      placeController: placeController,
      latitude: latitude,
      longitude: longitude,
      locationService: service,
      showMapPreview: false,
      searchDebounce: searchDebounce,
      onUseCurrentLocation: gps,
      onLocationChanged: (lat, lng) => setState(() {
        latitude = lat;
        longitude = lng;
      }),
    ),
  )));
}

void main() {
  group('Nearby place models and category mapping', () {
    test('2. every category maps to valid Google Table A place types', () {
      // Documented Table A values usable as Nearby Search (New) filters:
      // https://developers.google.com/maps/documentation/places/web-service/place-types
      const allowedTypes = <String>{
        'hospital',
        'police',
        'fire_station',
        'school',
        'primary_school',
        'secondary_school',
        'university',
        'train_station',
        'light_rail_station',
        'subway_station',
        'bus_station',
        'bus_stop',
        'cultural_landmark',
        'historical_landmark',
        'monument',
        'historical_place',
        'tourist_attraction',
        'plaza',
        'church',
        'hindu_temple',
        'buddhist_temple',
        'shinto_shrine',
        'mosque',
      };

      // Table B values are NOT valid Nearby Search filters.
      const forbiddenTableBTypes = <String>{
        'landmark',
        'intersection',
        'place_of_worship',
        'point_of_interest',
        'establishment',
        'neighborhood',
      };

      expect(NearbyPlaceCategory.values, isNotEmpty);
      for (final category in NearbyPlaceCategory.values) {
        expect(
          category.googleTypes,
          isNotEmpty,
          reason: '${category.name} maps to no Google place type',
        );
        for (final type in category.googleTypes) {
          expect(
            allowedTypes.contains(type),
            isTrue,
            reason: '$category -> "$type" is not a documented Table A type',
          );
          expect(
            forbiddenTableBTypes.contains(type),
            isFalse,
            reason: '$category -> "$type" is a Table B type and cannot be '
                'used as a Nearby Search (New) filter',
          );
        }
      }
    });

    test('2b. specific categories map to the expected Google types', () {
      expect(NearbyPlaceCategory.hospital.googleTypes, <String>['hospital']);
      expect(NearbyPlaceCategory.police.googleTypes, <String>['police']);
      expect(NearbyPlaceCategory.fireStation.googleTypes,
          <String>['fire_station']);
      expect(
        NearbyPlaceCategory.school.googleTypes,
        containsAll(<String>['school', 'primary_school', 'secondary_school']),
      );
      expect(NearbyPlaceCategory.college.googleTypes, contains('university'));
      expect(
        NearbyPlaceCategory.railwayStation.googleTypes,
        containsAll(<String>[
          'train_station',
          'light_rail_station',
          'subway_station',
        ]),
      );
      expect(
          NearbyPlaceCategory.busStation.googleTypes, contains('bus_station'));
      expect(
        NearbyPlaceCategory.landmark.googleTypes,
        containsAll(<String>['tourist_attraction', 'cultural_landmark']),
      );
      expect(NearbyPlaceCategory.church.googleTypes, <String>['church']);
      expect(NearbyPlaceCategory.temple.googleTypes, contains('hindu_temple'));
      expect(NearbyPlaceCategory.mosque.googleTypes, <String>['mosque']);
    });

    test('3. NearbyPlace exposes name/address/coordinates + labels', () {
      const place = NearbyPlace(
        placeId: 'place-hospital-a',
        name: 'Hospital A',
        address: 'Main Road, Kolenchery',
        latitude: 9.991,
        longitude: 76.662,
        distanceMeters: 1200,
      );

      expect(place.placeId, 'place-hospital-a');
      expect(place.name, 'Hospital A');
      expect(place.address, 'Main Road, Kolenchery');
      expect(place.latitude, 9.991);
      expect(place.longitude, 76.662);
      expect(place.label, 'Hospital A, Main Road, Kolenchery');
      expect(place.distanceLabel, '1.2 km');
      expect(place.point, const GeoPoint(9.991, 76.662));
    });

    test('distance labels format metres and kilometres', () {
      const close = NearbyPlace(
        placeId: 'a',
        name: 'A',
        address: '',
        latitude: 0,
        longitude: 0,
        distanceMeters: 350,
      );
      const far = NearbyPlace(
        placeId: 'b',
        name: 'B',
        address: '',
        latitude: 0,
        longitude: 0,
        distanceMeters: 2000,
      );
      const unknown = NearbyPlace(
        placeId: 'c',
        name: 'C',
        address: '',
        latitude: 0,
        longitude: 0,
      );

      expect(close.distanceLabel, '350 m');
      expect(far.distanceLabel, '2.0 km');
      expect(unknown.distanceLabel, '');
    });

    test('haversine distance matches real-world scale', () {
      // ~111 km per degree of latitude.
      final oneDegree =
          NearbyPlace.haversineDistanceMeters(10.0, 76.0, 11.0, 76.0);
      expect(oneDegree, closeTo(111000, 500));

      // Same point -> zero.
      expect(NearbyPlace.haversineDistanceMeters(9.99, 76.66, 9.99, 76.66), 0);
    });

    test('the default nearby radius is 5 km, not 30 km', () {
      expect(kNearbySearchRadiusMeters, 5000);
      expect(kNearbySearchMaxResultCount, 10);
    });

    test('Places API disabled errors are recognised from Google messages', () {
      expect(
        isPlacesApiDisabledError(
          'Places API (New) has not been used in project 3804150054 before or '
          'it is disabled. Enable it by visiting '
          'https://console.developers.google.com/apis/api/places.googleapis.com/overview?project=3804150054 '
          'then retry.',
        ),
        isTrue,
      );
      expect(isPlacesApiDisabledError('ApiTargetBlockedMapError'), isTrue);
      expect(isPlacesApiDisabledError('Request denied.'), isFalse);
      expect(isPlacesApiDisabledError('Some network timeout'), isFalse);
    });

    test('PlacesApiDisabledException carries the exact user guidance', () {
      const error = PlacesApiDisabledException();
      expect(
        error.message,
        'Nearby places unavailable. Enable Places API (New) in Google Cloud.',
      );
      expect(error, isA<LocationServiceException>());
      expect(error.toString(), error.message);
    });
  });

  group('Nearby places — requester workflow', () {
    testWidgets(
        '1. nearby request uses the current GPS latitude/longitude (5 km)',
        (tester) async {
      final service = NearbyRecordingLocationService(nearbyResults: _hospitals);
      final controller = TextEditingController();

      _useDesktopSizedSurface(tester);
      await _pumpPicker(
        tester,
        service: service,
        placeController: controller,
        gps: () async => const GeoPoint(9.9876, 76.6543),
      );

      await _scrollIntoViewAndTap(
        tester,
        find.byKey(const Key('use-current-location-button')),
      );

      // Obtaining GPS alone performs no Nearby Search: a category must be
      // picked first (call policy: explicit requester actions only).
      expect(service.nearbyCalls, isEmpty);

      await _scrollIntoViewAndTap(
        tester,
        find.byKey(const Key('nearby-category-hospital')),
      );

      expect(service.nearbyCalls, hasLength(1));
      final call = service.nearbyCalls.single;
      expect(call.latitude, 9.9876);
      expect(call.longitude, 76.6543);
      expect(call.category, NearbyPlaceCategory.hospital);
      // 5 km radius, not the 30 km autocomplete bias.
      expect(call.radiusMeters, kNearbySearchRadiusMeters);
    });

    testWidgets('3. nearby results render name, distance and address',
        (tester) async {
      final service = NearbyRecordingLocationService(nearbyResults: _hospitals);
      final controller = TextEditingController();

      _useDesktopSizedSurface(tester);
      await _pumpPicker(
        tester,
        service: service,
        placeController: controller,
        gps: () async => const GeoPoint(9.9876, 76.6543),
      );

      await _scrollIntoViewAndTap(
        tester,
        find.byKey(const Key('use-current-location-button')),
      );
      await _scrollIntoViewAndTap(
        tester,
        find.byKey(const Key('nearby-category-hospital')),
      );

      expect(find.byKey(const Key('nearby-places-section')), findsOneWidget);
      expect(find.text('Hospitals'), findsOneWidget);
      expect(find.text('Hospital A'), findsOneWidget);
      expect(find.text('1.2 km'), findsOneWidget);
      expect(find.text('Main Road, Kolenchery'), findsOneWidget);
      expect(find.text('Hospital B'), findsOneWidget);
      expect(find.text('2.0 km'), findsOneWidget);
      expect(find.text('Church Road, Kolenchery'), findsOneWidget);
    });

    testWidgets(
        '4. selecting a nearby place updates the form label + exact '
        'coordinates and allows submission', (tester) async {
      final service = NearbyRecordingLocationService(nearbyResults: _hospitals);
      NewRequestPayload? submitted;

      _useDesktopSizedSurface(tester);
      await tester.pumpWidget(_host(NewRequestPanel(
        resources: const <BackendResource>[_ambulance],
        locationService: service,
        showMapPreview: false,
        onReload: () {},
        onUseCurrentLocation: () async => const GeoPoint(9.9876, 76.6543),
        onSubmit: (payload) async {
          submitted = payload;
          return true;
        },
      )));

      await tester.enterText(_descriptionField(), 'Two people trapped');
      await _scrollIntoViewAndTap(
        tester,
        find.byKey(const Key('use-current-location-button')),
      );
      await _scrollIntoViewAndTap(
        tester,
        find.byKey(const Key('nearby-category-hospital')),
      );
      await _scrollIntoViewAndTap(
        tester,
        find.byKey(const Key('nearby-result-place-hospital-a')),
      );

      // The selected Google place's own name/address becomes the label and
      // its own coordinates become canonical.
      final placeField =
          tester.widget<TextField>(find.byKey(const Key('location-place-field')));
      expect(placeField.controller!.text, 'Hospital A, Main Road, Kolenchery');
      expect(find.textContaining('Coordinates: 9.991000'), findsOneWidget);
      expect(find.textContaining('Selected: Hospital A'), findsOneWidget);

      // Selecting a nearby place is a location change -> the nearby list is
      // re-queried around the newly selected coordinates.
      expect(service.nearbyCalls, hasLength(2));
      expect(service.nearbyCalls.last.latitude, 9.991);
      expect(service.nearbyCalls.last.longitude, 76.662);

      // Complete the form and submit from the nearby-selected location.
      await _scrollIntoViewAndTap(
        tester,
        find.byType(DropdownButtonFormField<int>),
      );
      final menuItem = find.text('Ambulance').hitTestable();
      expect(menuItem, findsOneWidget);
      await tester.tap(menuItem);
      await tester.pumpAndSettle();

      await _scrollIntoViewAndTap(tester, find.text('Submit request'));

      expect(submitted, isNotNull);
      expect(submitted!.location, 'Hospital A, Main Road, Kolenchery');
      expect(submitted!.latitude, 9.991);
      expect(submitted!.longitude, 76.662);
      expect(submitted!.hasPreciseLocation, isTrue);
    });

    testWidgets(
        '5. Places API (New) disabled -> graceful message, no crash, form '
        'keeps working', (tester) async {
      final service = NearbyRecordingLocationService(
        nearbyError: const PlacesApiDisabledException(
          details: 'Places API (New) has not been used in project 3804150054 '
              'before or it is disabled.',
        ),
      );
      final controller = TextEditingController();

      _useDesktopSizedSurface(tester);
      await _pumpPicker(
        tester,
        service: service,
        placeController: controller,
        gps: () async => const GeoPoint(9.9876, 76.6543),
      );

      await _scrollIntoViewAndTap(
        tester,
        find.byKey(const Key('use-current-location-button')),
      );
      // Current-location + reverse geocode workflow keeps working (Geocoding
      // API is a separate API).
      expect(controller.text, 'Kolenchery, Kerala');

      await _scrollIntoViewAndTap(
        tester,
        find.byKey(const Key('nearby-category-hospital')),
      );

      expect(
        find.text(
            'Nearby places unavailable. Enable Places API (New) in Google Cloud.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('nearby-unavailable-text')), findsOneWidget);
      expect(tester.takeException(), isNull);

      // The form is still fully usable: manual place entry still works and
      // the nearby section can be retried via Refresh.
      await tester.enterText(
        find.byKey(const Key('location-place-field')),
        'Near Kolenchery junction',
      );
      expect(controller.text, 'Near Kolenchery junction');
      expect(find.byKey(const Key('nearby-refresh-button')), findsOneWidget);
    });

    testWidgets('5b. generic nearby failure -> status text, no crash',
        (tester) async {
      final service = NearbyRecordingLocationService(
        nearbyError: const LocationServiceException(
          'Google Places library is not loaded.',
        ),
      );
      final controller = TextEditingController();

      _useDesktopSizedSurface(tester);
      await _pumpPicker(
        tester,
        service: service,
        placeController: controller,
        gps: () async => const GeoPoint(9.9876, 76.6543),
      );

      await _scrollIntoViewAndTap(
        tester,
        find.byKey(const Key('use-current-location-button')),
      );
      await _scrollIntoViewAndTap(
        tester,
        find.byKey(const Key('nearby-category-hospital')),
      );

      expect(
        find.text(
            'Nearby places unavailable: Google Places library is not loaded.'),
        findsOneWidget,
      );
      // The Places-API-disabled guidance is only shown for that failure mode.
      expect(
        find.text(
            'Nearby places unavailable. Enable Places API (New) in Google Cloud.'),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        '6. existing autocomplete still works while nearby is unavailable',
        (tester) async {
      final service = NearbyRecordingLocationService(
        nearbyError: const PlacesApiDisabledException(),
        predictions: const <PlacePrediction>[
          PlacePrediction(
            placeId: 'place-junction',
            primaryText: 'Kolenchery Junction',
            secondaryText: 'Kerala, India',
          ),
        ],
      );
      final controller = TextEditingController();

      _useDesktopSizedSurface(tester);
      await _pumpPicker(
        tester,
        service: service,
        placeController: controller,
        gps: () async => const GeoPoint(9.9876, 76.6543),
        searchDebounce: const Duration(milliseconds: 10),
      );

      await _scrollIntoViewAndTap(
        tester,
        find.byKey(const Key('use-current-location-button')),
      );
      await _scrollIntoViewAndTap(
        tester,
        find.byKey(const Key('nearby-category-hospital')),
      );
      expect(
        find.text(
            'Nearby places unavailable. Enable Places API (New) in Google Cloud.'),
        findsOneWidget,
      );

      // Manual search is a separate feature and keeps working.
      await tester.enterText(
        find.byKey(const Key('location-search-field')),
        'kolenchery',
      );
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();

      expect(service.autocompleteCalls, <String>['kolenchery']);
      expect(find.text('Kolenchery Junction'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('7. reverse geocoding keeps working after nearby failures',
        (tester) async {
      final service = NearbyRecordingLocationService(
        nearbyError: const PlacesApiDisabledException(),
      );
      final controller = TextEditingController();

      _useDesktopSizedSurface(tester);
      await _pumpPicker(
        tester,
        service: service,
        placeController: controller,
        gps: () async => const GeoPoint(9.9876, 76.6543),
      );

      await _scrollIntoViewAndTap(
        tester,
        find.byKey(const Key('use-current-location-button')),
      );
      await _scrollIntoViewAndTap(
        tester,
        find.byKey(const Key('nearby-category-hospital')),
      );

      // Detecting the current location again re-runs reverse geocoding even
      // though the nearby request keeps failing.
      await _scrollIntoViewAndTap(
        tester,
        find.byKey(const Key('use-current-location-button')),
      );

      expect(service.reverseGeocodeCalls, hasLength(2));
      expect(controller.text, 'Kolenchery, Kerala');
      expect(
        find.text(
            'Nearby places unavailable. Enable Places API (New) in Google Cloud.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'explicit refresh and location changes re-query; typing never does',
        (tester) async {
      final service = NearbyRecordingLocationService(nearbyResults: _hospitals);
      final controller = TextEditingController();
      final key = GlobalKey<State<RequesterLocationPicker>>();

      var gpsPoint = const GeoPoint(10.0, 76.0);

      _useDesktopSizedSurface(tester);
      await _pumpPicker(
        tester,
        service: service,
        placeController: controller,
        gps: () async => gpsPoint,
        searchDebounce: const Duration(milliseconds: 10),
        key: key,
      );

      await _scrollIntoViewAndTap(
        tester,
        find.byKey(const Key('use-current-location-button')),
      );
      await _scrollIntoViewAndTap(
        tester,
        find.byKey(const Key('nearby-category-hospital')),
      );
      expect(service.nearbyCalls, hasLength(1));

      // Refresh re-runs the selected category at the same coordinates.
      await _scrollIntoViewAndTap(
        tester,
        find.byKey(const Key('nearby-refresh-button')),
      );
      expect(service.nearbyCalls, hasLength(2));
      expect(service.nearbyCalls.last.latitude, 10.0);

      // Typing triggers autocomplete only — never Nearby Search.
      await tester.enterText(
        find.byKey(const Key('location-search-field')),
        'hospital',
      );
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();
      expect(service.nearbyCalls, hasLength(2));

      // A location change (map tap) re-queries around the new point.
      await (key.currentState as dynamic).handleMapTap(const LatLng(10.5, 76.5));
      await tester.pumpAndSettle();
      expect(service.nearbyCalls, hasLength(3));
      expect(service.nearbyCalls.last.latitude, 10.5);
      expect(service.nearbyCalls.last.longitude, 76.5);
    });

    testWidgets('no coordinates -> nearby section hidden', (tester) async {
      final service = NearbyRecordingLocationService();
      final controller = TextEditingController();

      await _pumpPicker(
        tester,
        service: service,
        placeController: controller,
        gps: () async => null,
      );

      expect(find.byKey(const Key('nearby-places-section')), findsNothing);
      expect(service.nearbyCalls, isEmpty);
    });
  });

  group('8. Socket.IO live responder updates', () {
    test('live responder location updates never trigger Nearby Search', () {
      final service = NearbyRecordingLocationService();
      final store = LiveLocationStore();
      addTearDown(store.dispose);

      store.applyUpdate(LiveResponderLocation(
        requestId: 1,
        responderId: 9,
        latitude: 10.11,
        longitude: 76.22,
        updatedAt: DateTime.utc(2026, 9, 26, 10),
      ));
      store.applyUpdate(LiveResponderLocation(
        requestId: 1,
        responderId: 9,
        latitude: 10.12,
        longitude: 76.23,
        updatedAt: DateTime.utc(2026, 9, 26, 10, 1),
      ));

      // Pair-keyed API (Phase F): responder 9 is the only responder of
      // request 1 in this fixture, so the pair is explicit here.
      expect(store.locationFor(1, 9)!.latitude, 10.12);
      expect(store.singleLocationFor(1)!.latitude, 10.12);
      expect(service.nearbyCalls, isEmpty);
      expect(service.reverseGeocodeCalls, isEmpty);
      expect(service.autocompleteCalls, isEmpty);
    });
  });
}
