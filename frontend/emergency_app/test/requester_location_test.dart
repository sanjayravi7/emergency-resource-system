import 'package:dispatch_console_flutter/models/eras_models.dart';
import 'package:dispatch_console_flutter/Services/live_location_store.dart';
import 'package:dispatch_console_flutter/services/location_service.dart';
import 'package:dispatch_console_flutter/widgets/new_request_panel.dart';
import 'package:dispatch_console_flutter/widgets/requester_location_picker.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;
import 'package:flutter_test/flutter_test.dart';

/// Fake Google-backed location service. It records every call so the tests can
/// prove that reverse geocoding only happens on explicit requester actions.
class FakeLocationService implements LocationService {
  FakeLocationService({
    this.reverseResult,
    this.reverseError,
    this.predictions = const <PlacePrediction>[],
    this.resolved,
    this.resolveError,
  });

  ResolvedPlace? reverseResult;
  String? reverseError;
  List<PlacePrediction> predictions;
  ResolvedPlace? resolved;
  String? resolveError;

  final List<GeoPoint> reverseGeocodeCalls = <GeoPoint>[];
  final List<String> autocompleteCalls = <String>[];
  final List<GeoPoint?> autocompleteBiases = <GeoPoint?>[];
  final List<String> resolveCalls = <String>[];

  @override
  bool get isAvailable => true;

  @override
  Future<ResolvedPlace> reverseGeocode(double latitude, double longitude) async {
    reverseGeocodeCalls.add(GeoPoint(latitude, longitude));
    if (reverseError != null) {
      throw LocationServiceException(reverseError!);
    }
    return reverseResult ??
        ResolvedPlace(
          label: 'Fallback place',
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
    autocompleteBiases.add(bias);
    return predictions;
  }

  @override
  Future<ResolvedPlace> resolvePrediction(PlacePrediction prediction) async {
    resolveCalls.add(prediction.placeId);
    if (resolveError != null) {
      throw LocationServiceException(resolveError!);
    }
    return resolved!;
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

Finder _descriptionField() => find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.hintText ==
              'What happened, how many people are affected…',
    );

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  group('RequesterLocationPicker', () {
    testWidgets(
        'A. current location success: GPS -> reverse geocode -> place filled',
        (tester) async {
      final service = FakeLocationService(
        reverseResult: const ResolvedPlace(
          label: 'Sree Narayana Gurukulam College of Engineering, Kolenchery',
          latitude: 9.9876,
          longitude: 76.6543,
          placeId: 'place-college',
        ),
      );
      final controller = TextEditingController();
      double? latitude;
      double? longitude;

      await tester.pumpWidget(_host(StatefulBuilder(
        builder: (context, setState) => RequesterLocationPicker(
          placeController: controller,
          latitude: latitude,
          longitude: longitude,
          locationService: service,
          showMapPreview: false,
          onUseCurrentLocation: () async => const GeoPoint(9.9876, 76.6543),
          onLocationChanged: (lat, lng) =>
              setState(() {
                latitude = lat;
                longitude = lng;
              }),
        ),
      )));

      await tester.tap(find.byKey(const Key('use-current-location-button')));
      await tester.pumpAndSettle();

      expect(controller.text,
          'Sree Narayana Gurukulam College of Engineering, Kolenchery');
      expect(latitude, 9.9876);
      expect(longitude, 76.6543);
      expect(service.reverseGeocodeCalls.single,
          const GeoPoint(9.9876, 76.6543));
      expect(find.textContaining('Location detected'), findsOneWidget);
      expect(find.textContaining('9.9876'), findsOneWidget);
    });

    testWidgets(
        'B. reverse geocode failure keeps coordinates and asks for manual place',
        (tester) async {
      final service = FakeLocationService(reverseError: 'ZERO_RESULTS');
      final controller = TextEditingController();
      double? latitude;
      double? longitude;

      await tester.pumpWidget(_host(StatefulBuilder(
        builder: (context, setState) => RequesterLocationPicker(
          placeController: controller,
          latitude: latitude,
          longitude: longitude,
          locationService: service,
          showMapPreview: false,
          onUseCurrentLocation: () async => const GeoPoint(10.1, 76.2),
          onLocationChanged: (lat, lng) => setState(() {
            latitude = lat;
            longitude = lng;
          }),
        ),
      )));

      await tester.tap(find.byKey(const Key('use-current-location-button')));
      await tester.pumpAndSettle();

      // Coordinates retained, nothing fabricated, field still editable.
      expect(latitude, 10.1);
      expect(longitude, 76.2);
      expect(controller.text, isEmpty);
      expect(
        find.textContaining('place name could not be determined'),
        findsOneWidget,
      );

      await tester.enterText(
        find.byKey(const Key('location-place-field')),
        'Near Kolenchery junction',
      );
      expect(controller.text, 'Near Kolenchery junction');
    });

    testWidgets(
        'C. place selection sets both the place text and exact coordinates',
        (tester) async {
      final service = FakeLocationService(
        predictions: const <PlacePrediction>[
          PlacePrediction(
            placeId: 'place-hospital',
            primaryText: 'Kolenchery Government Hospital',
            secondaryText: 'Kerala, India',
          ),
        ],
        resolved: const ResolvedPlace(
          label: 'Kolenchery Government Hospital, Kerala',
          latitude: 9.9911,
          longitude: 76.6622,
          placeId: 'place-hospital',
        ),
      );
      final controller = TextEditingController();
      double? latitude = 10.0;
      double? longitude = 76.0;

      await tester.pumpWidget(_host(StatefulBuilder(
        builder: (context, setState) => RequesterLocationPicker(
          placeController: controller,
          latitude: latitude,
          longitude: longitude,
          locationService: service,
          showMapPreview: false,
          searchDebounce: const Duration(milliseconds: 10),
          onUseCurrentLocation: () async => null,
          onLocationChanged: (lat, lng) => setState(() {
            latitude = lat;
            longitude = lng;
          }),
        ),
      )));

      await tester.enterText(
          find.byKey(const Key('location-search-field')), 'hospital');
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();

      expect(service.autocompleteCalls, <String>['hospital']);
      // Nearby bias uses the coordinates the requester already has.
      expect(service.autocompleteBiases.single, const GeoPoint(10.0, 76.0));
      expect(find.text('Kolenchery Government Hospital'), findsOneWidget);

      await tester.tap(find.byKey(const Key('prediction-place-hospital')));
      await tester.pumpAndSettle();

      expect(controller.text, 'Kolenchery Government Hospital, Kerala');
      expect(latitude, 9.9911);
      expect(longitude, 76.6622);
      expect(find.textContaining('Selected:'), findsOneWidget);
    });

    testWidgets('map tap updates coordinates and reverse geocodes them',
        (tester) async {
      final service = FakeLocationService(
        reverseResult: const ResolvedPlace(
          label: 'Tapped point, Kerala',
          latitude: 10.5,
          longitude: 76.5,
        ),
      );
      final controller = TextEditingController();
      double? latitude;
      double? longitude;

      final key = GlobalKey<State<RequesterLocationPicker>>();

      await tester.pumpWidget(_host(StatefulBuilder(
        builder: (context, setState) => RequesterLocationPicker(
          key: key,
          placeController: controller,
          latitude: latitude,
          longitude: longitude,
          locationService: service,
          showMapPreview: false,
          onUseCurrentLocation: () async => null,
          onLocationChanged: (lat, lng) => setState(() {
            latitude = lat;
            longitude = lng;
          }),
        ),
      )));

      // Simulate the GoogleMap onTap callback without instantiating a
      // platform map view in the unit-test environment.
      await (key.currentState as dynamic)
          .handleMapTap(const LatLng(10.5, 76.5));
      await tester.pumpAndSettle();

      expect(latitude, 10.5);
      expect(longitude, 76.5);
      expect(controller.text, 'Tapped point, Kerala');
      expect(service.reverseGeocodeCalls.single, const GeoPoint(10.5, 76.5));
    });
  });

  group('NewRequestPanel validation', () {
    /// Scrolls [finder] into the test viewport and then taps it.
    ///
    /// The requester form is much taller than the default 800x600 test
    /// surface, so the controls near its bottom (resource dropdown, submit
    /// button) are laid out below the viewport. Tapping them straight away
    /// sends the pointer event to an offset outside the root render tree,
    /// which Flutter reports as "Offset ... is outside the bounds of the root
    /// of the render tree" and which never reaches the widget.
    Future<void> scrollAndTap(WidgetTester tester, Finder finder) async {
      expect(finder, findsOneWidget);
      await tester.ensureVisible(finder);
      // ensureVisible only moves the scroll position; the tap offset is read
      // from the render tree, so it has to be laid out again before tapping.
      await tester.pumpAndSettle();
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    /// Selects [resource] with the real dropdown and proves the panel stored
    /// the selection, so D/E/F submit an actual resource line.
    Future<void> selectResource(
      WidgetTester tester,
      BackendResource resource,
    ) async {
      final dropdown = find.byType(DropdownButtonFormField<int>);
      await scrollAndTap(tester, dropdown);

      // A closed DropdownButton keeps its items inside an IndexedStack whose
      // unselected children are off-stage, so the entry only becomes findable
      // once the menu route is really open. hitTestable() additionally keeps
      // the copy the requester can actually press (the menu sits above the
      // route's modal barrier), instead of guessing with `.last`.
      final menuEntry = find.text(resource.name).hitTestable();
      expect(menuEntry, findsOneWidget);
      await tester.tap(menuEntry);
      await tester.pumpAndSettle();

      // The dropdown really holds the resource id now.
      expect(
        tester.widget<DropdownButtonFormField<int>>(dropdown).initialValue,
        resource.id,
      );
    }

    Future<NewRequestPayload?> pumpPanelAndSubmit(
      WidgetTester tester, {
      required FakeLocationService service,
      required Future<GeoPoint?> Function() gps,
      bool selectPlaceFirst = false,
      String? typedPlace,
    }) async {
      NewRequestPayload? submitted;

      await tester.pumpWidget(_host(NewRequestPanel(
        resources: const <BackendResource>[_ambulance],
        locationService: service,
        showMapPreview: false,
        onReload: () {},
        onUseCurrentLocation: gps,
        onSubmit: (payload) async {
          submitted = payload;
          return true;
        },
      )));

      await tester.enterText(_descriptionField(), 'Two people trapped');

      if (selectPlaceFirst) {
        final gpsButton = find.byKey(const Key('use-current-location-button'));
        await scrollAndTap(tester, gpsButton);
      }

      if (typedPlace != null) {
        await tester.enterText(
            find.byKey(const Key('location-place-field')), typedPlace);
        await tester.pump();
      }

      // Pick the single resource through the production dropdown.
      await selectResource(tester, _ambulance);

      await scrollAndTap(tester, find.text('Submit request'));

      return submitted;
    }

    testWidgets('D. coordinates + place -> submit allowed', (tester) async {
      final service = FakeLocationService(
        reverseResult: const ResolvedPlace(
          label: 'Kolenchery, Kerala',
          latitude: 9.99,
          longitude: 76.66,
        ),
      );

      final payload = await pumpPanelAndSubmit(
        tester,
        service: service,
        gps: () async => const GeoPoint(9.99, 76.66),
        selectPlaceFirst: true,
      );

      expect(payload, isNotNull);
      expect(payload!.location, 'Kolenchery, Kerala');
      expect(payload.latitude, 9.99);
      expect(payload.longitude, 76.66);
      expect(payload.hasPreciseLocation, isTrue);
    });

    testWidgets('E. missing place -> submit rejected', (tester) async {
      final service = FakeLocationService(reverseError: 'ZERO_RESULTS');

      final payload = await pumpPanelAndSubmit(
        tester,
        service: service,
        gps: () async => const GeoPoint(9.99, 76.66),
        selectPlaceFirst: true,
      );

      expect(payload, isNull);
      expect(find.textContaining('Select or enter a place'), findsOneWidget);
    });

    testWidgets(
        'F. place typed but no coordinates -> stored without a fabricated pin',
        (tester) async {
      final service = FakeLocationService();

      final payload = await pumpPanelAndSubmit(
        tester,
        service: service,
        gps: () async => null,
        typedPlace: 'Somewhere in Thrissur',
      );

      expect(payload, isNotNull);
      expect(payload!.latitude, isNull);
      expect(payload.longitude, isNull);
      expect(payload.hasPreciseLocation, isFalse);
      // No reverse geocoding was triggered by typing text.
      expect(service.reverseGeocodeCalls, isEmpty);
    });
  });

  group('G. Socket.IO live responder location', () {
    test('live location updates never trigger reverse geocoding', () {
      final service = FakeLocationService();
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

      expect(store.locationFor(1)!.latitude, 10.12);
      expect(service.reverseGeocodeCalls, isEmpty);
      expect(service.autocompleteCalls, isEmpty);
    });
  });
}
