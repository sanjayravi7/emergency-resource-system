import 'package:dispatch_console_flutter/models/eras_models.dart';
import 'package:dispatch_console_flutter/services/location_service.dart';
import 'package:dispatch_console_flutter/widgets/board_panel.dart';
import 'package:dispatch_console_flutter/widgets/location_permission_banner.dart';
import 'package:dispatch_console_flutter/widgets/new_request_panel.dart';
import 'package:dispatch_console_flutter/widgets/request_detail_dialog.dart';
import 'package:dispatch_console_flutter/widgets/responder_assignment_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

EmergencyRequest requestFixture({
  int id = 41,
  RequestStatus status = RequestStatus.pending,
  String statusRaw = 'PENDING',
  List<RequiredResourceLine> requiredResources = const [],
}) {
  return EmergencyRequest(
    id: id,
    emergencyType: 'Fire',
    description: 'Smoke near the east stairwell',
    location: 'Central Library',
    priority: 'CRITICAL',
    status: status,
    statusRaw: statusRaw,
    createdAt: DateTime.utc(2026, 9, 30, 10),
    updatedAt: DateTime.utc(2026, 9, 30, 10, 5),
    latitude: 9.9911,
    longitude: 76.6622,
    requester: const UserSummary(
      id: 8,
      name: 'Asha Requester',
      email: 'asha@example.com',
    ),
    requiredResources: requiredResources,
    allocations: const [],
  );
}

Widget boardHarness({
  required String role,
  required EmergencyRequest request,
  void Function(EmergencyRequest)? onEdit,
  void Function(EmergencyRequest)? onCancel,
  void Function(EmergencyRequest)? onAssign,
}) {
  return MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: BoardPanel(
          title: 'REQUESTS',
          hint: '',
          requests: [request],
          role: role,
          currentUserId: 12,
          emptyMessage: 'Empty',
          onViewRequest: (_) {},
          onEditRequest: onEdit,
          onCancelRequest: onCancel,
          onAssignRequest: onAssign,
          isMobile: true,
        ),
      ),
    ),
  );
}

class _FakeLocationService implements LocationService {
  @override
  bool get isAvailable => false;

  @override
  Future<List<PlacePrediction>> autocomplete(
    String query, {
    GeoPoint? bias,
    double biasRadiusMeters = 30000,
  }) async =>
      const [];

  @override
  Future<ResolvedPlace> resolvePrediction(PlacePrediction prediction) =>
      throw const LocationServiceException('Unavailable in test');

  @override
  Future<ResolvedPlace> reverseGeocode(double latitude, double longitude) =>
      throw const LocationServiceException('Unavailable in test');

  @override
  Future<List<NearbyPlace>> searchNearbyPlaces({
    required double latitude,
    required double longitude,
    required NearbyPlaceCategory category,
    double radiusMeters = kNearbySearchRadiusMeters,
    int maxResults = kNearbySearchMaxResultCount,
  }) async =>
      const [];
}

void main() {
  test('ADMIN navigation includes New Emergency', () {
    expect(
      navItemsForRole('ADMIN').map((item) => item.label),
      contains('New Emergency'),
    );
  });

  testWidgets('ADMIN sees ACCEPT / ASSIGN for a PENDING request', (
    tester,
  ) async {
    await tester.pumpWidget(
      boardHarness(
        role: 'ADMIN',
        request: requestFixture(),
        onAssign: (_) {},
        onCancel: (_) {},
      ),
    );

    expect(find.text('VIEW'), findsOneWidget);
    expect(find.text('ACCEPT / ASSIGN'), findsOneWidget);
    expect(find.text('CANCEL REQUEST'), findsOneWidget);
  });

  testWidgets('assignment picker only displays backend-compatible responders', (
    tester,
  ) async {
    const inventory = BackendResponderResource(
      id: 4,
      responderId: 12,
      resourceId: 7,
      totalQuantity: 5,
      availableQuantity: 3,
      status: 'AVAILABLE',
      isEnabled: true,
      responderName: 'Fire Responder',
      responderEmail: 'fire@example.com',
      responderStatus: 'AVAILABLE',
      resourceName: 'Medical Kit',
      resourceType: 'MEDICAL',
    );
    const compatible = BackendResponder(
      id: 12,
      name: 'Fire Responder',
      email: 'fire@example.com',
      status: 'AVAILABLE',
      helpTypes: [ResponderHelpType(category: 'FIRE', label: 'Fire')],
      resources: [inventory],
      compatibleRequestIds: <int>{41},
    );
    const incompatible = BackendResponder(
      id: 13,
      name: 'Medical Only Responder',
      email: 'medical@example.com',
      status: 'AVAILABLE',
      helpTypes: [ResponderHelpType(category: 'MEDICAL', label: 'Medical')],
      compatibleRequestIds: <int>{},
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ResponderAssignmentDialog(
            request: requestFixture(),
            responders: const [compatible, incompatible],
          ),
        ),
      ),
    );

    expect(find.text('Fire Responder'), findsOneWidget);
    expect(find.text('Medical Only Responder'), findsNothing);
    expect(find.textContaining('Medical Kit'), findsOneWidget);
    expect(find.textContaining('Help types · Fire'), findsOneWidget);
  });

  testWidgets('REQUESTER sees EDIT and CANCEL REQUEST for PENDING', (
    tester,
  ) async {
    await tester.pumpWidget(
      boardHarness(
        role: 'REQUESTER',
        request: requestFixture(),
        onEdit: (_) {},
        onCancel: (_) {},
      ),
    );

    expect(find.text('EDIT'), findsOneWidget);
    expect(find.text('CANCEL REQUEST'), findsOneWidget);
  });

  testWidgets('REQUESTER does not see EDIT for COMPLETED', (tester) async {
    await tester.pumpWidget(
      boardHarness(
        role: 'REQUESTER',
        request: requestFixture(
          status: RequestStatus.completed,
          statusRaw: 'COMPLETED',
        ),
        onEdit: (_) {},
        onCancel: (_) {},
      ),
    );

    expect(find.text('EDIT'), findsNothing);
    expect(find.text('CANCEL REQUEST'), findsNothing);
    expect(find.text('VIEW'), findsOneWidget);
  });

  testWidgets('edit form loads every existing mutable value', (tester) async {
    const line = RequiredResourceLine(
      resourceId: 7,
      quantity: 3,
      resourceName: 'Medical Kit',
      resourceType: 'MEDICAL',
      unit: 'kit',
    );
    const resource = BackendResource(
      id: 7,
      name: 'Medical Kit',
      type: 'MEDICAL',
      totalQuantity: 10,
      availableQuantity: 8,
      isActive: true,
      lowStockThreshold: 1,
      unit: 'kit',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: NewRequestPanel(
              initialRequest: requestFixture(requiredResources: const [line]),
              resources: const [resource],
              locationService: _FakeLocationService(),
              showMapPreview: false,
              onUseCurrentLocation: () async => null,
              onReload: () {},
              onSubmit: (_) async => true,
            ),
          ),
        ),
      ),
    );

    final description = tester.widget<TextField>(
      find.byKey(const Key('request-description-field')),
    );
    final place = tester.widget<TextField>(
      find.byKey(const Key('location-place-field')),
    );

    expect(description.controller!.text, 'Smoke near the east stairwell');
    expect(place.controller!.text, 'Central Library');
    expect(find.text('Fire'), findsWidgets);
    expect(find.text('Critical'), findsWidgets);
    expect(find.text('Medical Kit'), findsWidgets);
    expect(find.text('9.991100, 76.662200'), findsOneWidget);
  });

  testWidgets('manual location submits null coordinates rather than 0,0', (
    tester,
  ) async {
    NewRequestPayload? submitted;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: NewRequestPanel(
              resources: const [],
              locationService: _FakeLocationService(),
              showMapPreview: false,
              onUseCurrentLocation: () async => null,
              onReload: () {},
              onSubmit: (payload) async {
                submitted = payload;
                return false;
              },
            ),
          ),
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const Key('location-place-field')),
      'Manually entered place',
    );
    await tester.ensureVisible(find.text('Submit request'));
    await tester.tap(find.text('Submit request'));
    await tester.pump();

    expect(submitted, isNotNull);
    expect(submitted!.latitude, isNull);
    expect(submitted!.longitude, isNull);
  });

  testWidgets('request detail view includes the operational request fields', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: RequestDetailDialog(request: requestFixture())),
      ),
    );

    expect(find.byKey(const Key('request-detail-dialog')), findsOneWidget);
    expect(find.text('DB-41'), findsWidgets);
    expect(find.text('Central Library'), findsOneWidget);
    expect(find.text('Asha Requester'), findsOneWidget);
    expect(find.text('Smoke near the east stairwell'), findsOneWidget);
    expect(find.text('TIMELINE'), findsOneWidget);
    expect(find.text('9.991100, 76.662200'), findsOneWidget);
  });

  testWidgets('denied location state shows a non-blocking retry action', (
    tester,
  ) async {
    var retries = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LocationPermissionBanner(
            onEnableLocation: () async {
              retries++;
            },
          ),
        ),
      ),
    );

    expect(find.text('Location access is disabled.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('enable-location-button')));
    await tester.pump();
    expect(retries, 1);
  });

  test('permission states distinguish granted, promptable and blocked', () {
    const granted = LocationPermissionResult(
      status: LocationPermissionStatus.granted,
      message: 'granted',
    );
    const denied = LocationPermissionResult(
      status: LocationPermissionStatus.denied,
      message: 'denied',
    );
    const blocked = LocationPermissionResult(
      status: LocationPermissionStatus.deniedForever,
      message: 'blocked',
    );

    expect(granted.isGranted, isTrue);
    expect(granted.canRequest, isFalse);
    expect(denied.isGranted, isFalse);
    expect(denied.canRequest, isTrue);
    expect(blocked.canRequest, isFalse);
  });
}
