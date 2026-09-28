import 'package:dispatch_console_flutter/models/eras_models.dart';
import 'package:dispatch_console_flutter/services/location_service.dart';
import 'package:dispatch_console_flutter/widgets/new_request_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Minimal no-op location service: the submission tests type a place label
/// directly, so no Google-backed call must ever happen.
class _StaticLocationService implements LocationService {
  @override
  bool get isAvailable => false;

  @override
  Future<ResolvedPlace> reverseGeocode(double latitude, double longitude) {
    throw UnimplementedError();
  }

  @override
  Future<List<PlacePrediction>> autocomplete(
    String query, {
    GeoPoint? bias,
    double biasRadiusMeters = 30000,
  }) async =>
      const <PlacePrediction>[];

  @override
  Future<ResolvedPlace> resolvePrediction(PlacePrediction prediction) {
    throw UnimplementedError();
  }

  @override
  Future<List<NearbyPlace>> searchNearbyPlaces({
    required double latitude,
    required double longitude,
    required NearbyPlaceCategory category,
    double radiusMeters = kNearbySearchRadiusMeters,
    int maxResults = kNearbySearchMaxResultCount,
  }) async =>
      const <NearbyPlace>[];
}

/// A requester must ALWAYS be able to submit an emergency request, no matter
/// how many responders are online or available. These tests lock in the
/// requester-side half of that contract:
///
///   * a SERVICE resource with ZERO available responders stays selectable and
///     submittable (the request simply queues as PENDING server-side),
///   * responder counts never cap the requested quantity of a capability,
///   * an empty catalog shows an informational hint instead of a misleading
///     "no active resources" availability rejection,
///   * the explanatory PostgreSQL paragraph under Submit request is gone,
///   * CONSUMABLE inventory rules still apply (out of stock stays blocked).
void main() {
  // A reusable SERVICE capability. Zero responders are available for it -
  // exactly the state that used to block the requester UI.
  const unstaffedAmbulance = BackendResource(
    id: 7,
    name: 'Ambulance',
    type: 'AMBULANCE',
    mode: 'SERVICE',
    totalQuantity: 0,
    availableQuantity: 0,
    isActive: true,
    lowStockThreshold: 1,
    availableResponders: 0,
  );

  const outOfStockBlood = BackendResource(
    id: 8,
    name: 'Blood Bag',
    type: 'BLOOD',
    mode: 'CONSUMABLE',
    totalQuantity: 10,
    availableQuantity: 0,
    isActive: true,
    lowStockThreshold: 1,
    unit: 'bags',
  );

  Widget host(Widget child) => MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: child)),
      );

  void useDesktopSizedSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Future<void> scrollIntoViewAndTap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.tap(finder);
    await tester.pump();
  }

  /// Pumps the requester form, types a text-only place, optionally picks the
  /// resource from the dropdown, then presses Submit. Returns the payload
  /// handed to onSubmit (null when validation rejected the form).
  Future<NewRequestPayload?> pumpAndSubmit(
    WidgetTester tester, {
    required List<BackendResource> resources,
    bool pickResource = true,
    void Function()? beforeSubmit,
  }) async {
    NewRequestPayload? submitted;

    useDesktopSizedSurface(tester);

    await tester.pumpWidget(host(NewRequestPanel(
      resources: resources,
      locationService: _StaticLocationService(),
      showMapPreview: false,
      onReload: () {},
      onUseCurrentLocation: () async => null,
      onSubmit: (payload) async {
        submitted = payload;
        return true;
      },
    )));

    // Text-only place: the form accepts it without a fabricated pin.
    await tester.enterText(
      find.byKey(const Key('location-place-field')),
      'Somewhere in Thrissur',
    );
    await tester.pump();

    if (pickResource) {
      await scrollIntoViewAndTap(
        tester,
        find.byType(DropdownButtonFormField<int>),
      );
      final menuItem = find.text('Ambulance').hitTestable();
      expect(menuItem, findsOneWidget);
      await tester.tap(menuItem);
      await tester.pumpAndSettle();

      expect(find.text('No resources selected yet.'), findsNothing);
      expect(find.text('REQUIRED'), findsOneWidget);
    }

    if (beforeSubmit != null) beforeSubmit();

    await scrollIntoViewAndTap(tester, find.text('Submit request'));
    return submitted;
  }

  testWidgets('zero available responders never block a SERVICE resource',
      (tester) async {
    expect(unstaffedAmbulance.hasNoRespondersOnline, isTrue);
    expect(unstaffedAmbulance.isOutOfStock, isFalse);
    expect(unstaffedAmbulance.isSelectable, isTrue);

    final payload = await pumpAndSubmit(
      tester,
      resources: const <BackendResource>[unstaffedAmbulance],
    );

    // The emergency is submitted with the capability intact; the backend
    // persists it as PENDING until a compatible responder is available.
    expect(payload, isNotNull);
    expect(payload!.requiredResources, hasLength(1));
    expect(payload.requiredResources.single['resourceId'], 7);
    expect(payload.requiredResources.single['quantity'], 1);
    expect(payload.emergencyType, isNotEmpty);
    expect(payload.location, 'Somewhere in Thrissur');
  });

  testWidgets(
      'the requester is told the request queues instead of being blocked',
      (tester) async {
    final payload = await pumpAndSubmit(
      tester,
      resources: const <BackendResource>[unstaffedAmbulance],
      // The queue notice is asserted while the form is still filled; a
      // successful submit intentionally clears the form.
      beforeSubmit: () {
        expect(
          find.textContaining('no responders online right now'),
          findsOneWidget,
        );
        expect(
          find.textContaining('stays PENDING until a compatible responder'),
          findsOneWidget,
        );
        // The old blocking message is gone.
        expect(
          find.textContaining('No responders are currently available'),
          findsNothing,
        );
      },
    );

    expect(payload, isNotNull);
  });

  testWidgets('the explanatory PostgreSQL paragraph is removed',
      (tester) async {
    await pumpAndSubmit(
      tester,
      resources: const <BackendResource>[unstaffedAmbulance],
    );

    expect(
      find.textContaining('stored in PostgreSQL as an EmergencyRequest'),
      findsNothing,
    );
    expect(find.textContaining('RequestResource row'), findsNothing);
  });

  testWidgets(
      'an empty catalog shows an informational hint, not an availability rejection',
      (tester) async {
    await pumpAndSubmit(
      tester,
      resources: const <BackendResource>[],
      pickResource: false,
    );

    // The old red "No active resources found in the database." text is gone.
    expect(
      find.textContaining('No active resources found in the database'),
      findsNothing,
    );
    // The informational hint explains the catalog gap without rejecting the
    // emergency as "unavailable".
    expect(
      find.textContaining('An administrator can add or restore resources'),
      findsOneWidget,
    );

    // Validation still explains the real constraint honestly: an emergency
    // must name at least one catalog resource.
    expect(
      find.textContaining('An administrator must add or restore'),
      findsOneWidget,
    );
  });

  testWidgets('a CONSUMABLE resource without inventory stays blocked',
      (tester) async {
    // Inventory is a real spendable-quantity constraint (enforced by the
    // backend too), unlike responder availability.
    expect(outOfStockBlood.isOutOfStock, isTrue);
    expect(outOfStockBlood.isSelectable, isFalse);

    useDesktopSizedSurface(tester);
    await tester.pumpWidget(host(NewRequestPanel(
      resources: const <BackendResource>[outOfStockBlood],
      locationService: _StaticLocationService(),
      showMapPreview: false,
      onReload: () {},
      onUseCurrentLocation: () async => null,
      onSubmit: (payload) async => true,
    )));

    await tester.enterText(
      find.byKey(const Key('location-place-field')),
      'Somewhere in Kochi',
    );
    await tester.pump();

    await scrollIntoViewAndTap(
      tester,
      find.byType(DropdownButtonFormField<int>),
    );

    // The out-of-stock inventory item is offered but not selectable.
    final item = tester.widget<DropdownMenuItem<int>>(
      find.byType(DropdownMenuItem<int>).first,
    );
    expect(item.enabled, isFalse);

    await tester.pumpAndSettle();
  });

  testWidgets('the availability label separates inventory from staffing',
      (tester) async {
    expect(
      unstaffedAmbulance.availabilityLabel,
      'No responders online yet',
    );
    expect(outOfStockBlood.availabilityLabel, 'Out of stock');

    const staffedAmbulance = BackendResource(
      id: 7,
      name: 'Ambulance',
      type: 'AMBULANCE',
      mode: 'SERVICE',
      totalQuantity: 0,
      availableQuantity: 0,
      isActive: true,
      lowStockThreshold: 1,
      availableResponders: 3,
    );
    expect(staffedAmbulance.availabilityLabel, '3 responders available');
    expect(staffedAmbulance.hasNoRespondersOnline, isFalse);
  });
}
