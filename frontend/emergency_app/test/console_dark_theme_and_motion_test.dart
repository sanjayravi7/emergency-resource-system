import 'package:dispatch_console_flutter/models/eras_models.dart';
import 'package:dispatch_console_flutter/screens/register_screen.dart';
import 'package:dispatch_console_flutter/screens/responder_readiness_page.dart';
import 'package:dispatch_console_flutter/services/location_service.dart';
import 'package:dispatch_console_flutter/services/socket_service.dart';
import 'package:dispatch_console_flutter/theme/app_theme.dart';
import 'package:dispatch_console_flutter/widgets/allocation_dialog.dart';
import 'package:dispatch_console_flutter/widgets/board_panel.dart';
import 'package:dispatch_console_flutter/widgets/common_widgets.dart';
import 'package:dispatch_console_flutter/widgets/location_permission_banner.dart';
import 'package:dispatch_console_flutter/widgets/log_panel.dart';
import 'package:dispatch_console_flutter/widgets/new_request_panel.dart';
import 'package:dispatch_console_flutter/widgets/operational_status.dart';
import 'package:dispatch_console_flutter/widgets/request_detail_dialog.dart';
import 'package:dispatch_console_flutter/widgets/resource_panels.dart';
import 'package:dispatch_console_flutter/widgets/responder_assignment_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeLocationService implements LocationService {
  @override
  bool get isAvailable => true;

  @override
  Future<ResolvedPlace> reverseGeocode(
    double latitude,
    double longitude,
  ) async {
    return ResolvedPlace(
      label: 'Kochi, Kerala',
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
    return const <PlacePrediction>[];
  }

  @override
  Future<ResolvedPlace> resolvePrediction(PlacePrediction prediction) async {
    return ResolvedPlace(
      label: prediction.primaryText,
      latitude: 9.9816,
      longitude: 76.2999,
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
    return const <NearbyPlace>[];
  }
}

class _FakeReadinessGateway implements ResponderReadinessGateway {
  @override
  Future<Map<String, dynamic>> getHelpTypes() async {
    return <String, dynamic>{
      'categories': <Map<String, String>>[
        <String, String>{'value': 'MEDICAL', 'label': 'Medical'},
      ],
      'selected': <String>['MEDICAL'],
    };
  }

  @override
  Future<List<dynamic>> getResources() async {
    return <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 1,
        'name': 'Oxygen Cylinder',
        'type': 'OXYGEN',
        'totalQuantity': 10,
        'availableQuantity': 8,
        'unit': 'cylinder',
        'isActive': true,
        'lowStockThreshold': 2,
      },
    ];
  }

  @override
  Future<List<dynamic>> getInventory() async => <dynamic>[];

  @override
  Future<void> updateHelpTypes(Iterable<String> values) async {}

  @override
  Future<void> createInventory(Map<String, dynamic> data) async {}

  @override
  Future<void> updateInventory(int id, Map<String, dynamic> data) async {}

  @override
  Future<void> setAvailable() async {}

  @override
  Future<void> heartbeat() async {}
}

Widget _disableAnimationsBuilder(BuildContext context, Widget? child) {
  return MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: true),
    child: child!,
  );
}

Future<bool> _noopAllocate({
  required int requestId,
  required int resourceId,
  required int responderResourceId,
  required int quantity,
}) async {
  return true;
}

Widget _themed(
  Widget child, {
  Brightness brightness = Brightness.dark,
  bool reducedMotion = false,
}) {
  final mode = brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light;
  return MaterialApp(
    theme: erasTheme(Brightness.light),
    darkTheme: erasTheme(Brightness.dark),
    themeMode: mode,
    builder: reducedMotion ? _disableAnimationsBuilder : null,
    home: Scaffold(body: child),
  );
}

EmergencyRequest _sampleRequest() {
  return EmergencyRequest.fromJson(<String, dynamic>{
    'id': 42,
    'emergencyType': 'Medical',
    'description': 'Cardiac emergency at ward 3',
    'location': 'General Hospital, Kochi',
    'priority': 'CRITICAL',
    'status': 'IN_PROGRESS',
    'createdAt': '2026-04-15T10:00:00.000Z',
    'latitude': 9.9816,
    'longitude': 76.2999,
    'requester': <String, dynamic>{
      'id': 10,
      'name': 'Asha Nair',
      'email': 'asha@example.com',
      'phone': '+919999999999',
    },
    'acceptedBy': <String, dynamic>{
      'id': 20,
      'name': 'Responder Rahul',
      'responderStatus': 'BUSY',
    },
    'requiredResources': <Map<String, dynamic>>[
      <String, dynamic>{
        'resourceId': 1,
        'quantity': 2,
        'resource': <String, dynamic>{
          'id': 1,
          'name': 'Oxygen Cylinder',
          'type': 'OXYGEN',
          'unit': 'cylinder',
        },
      },
    ],
    'allocations': <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 7,
        'requestId': 42,
        'resourceId': 1,
        'responderId': 20,
        'quantity': 2,
        'status': 'DISPATCHED',
        'resource': <String, dynamic>{
          'id': 1,
          'name': 'Oxygen Cylinder',
          'type': 'OXYGEN',
        },
        'responder': <String, dynamic>{
          'id': 20,
          'name': 'Responder Rahul',
        },
      },
    ],
  });
}

BackendResource _sampleResource() {
  return BackendResource.fromJson(<String, dynamic>{
    'id': 1,
    'name': 'Oxygen Cylinder',
    'type': 'OXYGEN',
    'totalQuantity': 10,
    'availableQuantity': 8,
    'unit': 'cylinder',
    'location': 'Central Depot',
    'isActive': true,
    'lowStockThreshold': 2,
  });
}

void main() {
  test('ErasPalette exposes distinct tokens and lerps smoothly', () {
    expect(ErasPalette.darkPalette.dark, isTrue);
    expect(ErasPalette.light.dark, isFalse);
    expect(ErasPalette.darkPalette.bg, const Color(0xFF071321));
    expect(ErasPalette.darkPalette.surface, const Color(0xFF102035));
    expect(ErasPalette.darkPalette.inputFill, const Color(0xFF0B1A2E));
    expect(ErasPalette.light.surface, AppColors.surface);

    final mid = ErasPalette.light.lerp(ErasPalette.darkPalette, 0.5);
    expect(
      mid.surface,
      Color.lerp(AppColors.surface, const Color(0xFF102035), 0.5),
    );
  });

  testWidgets('authenticated shell renders dark surfaces', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    ThemeController.mode.value = ThemeMode.dark;
    addTearDown(() => ThemeController.mode.value = ThemeMode.light);

    await tester.pumpWidget(
      ValueListenableBuilder<ThemeMode>(
        valueListenable: ThemeController.mode,
        builder: (_, mode, __) => MaterialApp(
          theme: erasTheme(Brightness.light),
          darkTheme: erasTheme(Brightness.dark),
          themeMode: mode,
          home: Scaffold(
            body: Row(
              children: [
                Rail(
                  items: navItemsForRole('ADMIN'),
                  activeView: ConsoleView.board,
                  onViewChanged: (_) {},
                  clock: '12:00:00',
                  roleLabel: 'Admin · ADMIN',
                  onRefresh: () {},
                  onLogout: () {},
                ),
                const Expanded(
                  child: Column(
                    children: [
                      DesktopTopBar(
                        title: 'Dispatch Board',
                        subtitle: 'Live request state from PostgreSQL',
                        pending: 2,
                        active: 1,
                        completed: 4,
                        loading: false,
                        connectionStatus: RealtimeConnectionStatus.connected,
                      ),
                      Panel(
                        title: 'ALL ACTIVE REQUESTS',
                        hint: 'Sorted by time received',
                        child: EmptyState('No active requests.'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final panelFinder = find.descendant(
      of: find.byType(Panel),
      matching: find.byType(AnimatedContainer),
    );
    final panelContainer = tester.widget<AnimatedContainer>(panelFinder.first);
    final panelDeco = panelContainer.decoration! as BoxDecoration;
    expect(panelDeco.color, ErasPalette.darkPalette.surface);
    expect(panelDeco.color, isNot(Colors.white));

    final titleText = tester.widget<Text>(find.text('Dispatch Board'));
    expect(titleText.style?.color, ErasPalette.darkPalette.text);

    // Toggling the sidebar theme icon switches smoothly to light mode.
    await tester.tap(find.byTooltip('Switch to light mode'));
    await tester.pumpAndSettle();
    expect(ThemeController.mode.value, ThemeMode.light);

    final lightContainer = tester.widget<AnimatedContainer>(panelFinder.first);
    final lightDeco = lightContainer.decoration! as BoxDecoration;
    expect(lightDeco.color, AppColors.surface);
  });

  testWidgets('console panels render cleanly in dark mode', (tester) async {
    final request = _sampleRequest();
    final resource = _sampleResource();

    await tester.pumpWidget(
      _themed(
        SingleChildScrollView(
          child: Column(
            children: [
              BoardPanel(
                title: 'ALL ACTIVE REQUESTS',
                hint: 'Sorted by time received',
                requests: <EmergencyRequest>[request],
                role: 'ADMIN',
                emptyMessage: 'None',
                onViewRequest: (_) {},
              ),
              NewRequestPanel(
                resources: <BackendResource>[resource],
                onSubmit: (_) async => true,
                onReload: () {},
                onUseCurrentLocation: () async => null,
                locationService: _FakeLocationService(),
                showMapPreview: false,
              ),
              ResourceCatalogPanel(
                resources: <BackendResource>[resource],
                isAdmin: true,
                onCreate: () {},
              ),
              LogPanel(
                logEntries: <EmergencyRequest>[request],
                onViewRequest: (_) {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('ALL ACTIVE REQUESTS'), findsOneWidget);
    expect(find.text('NEW EMERGENCY'), findsOneWidget);
    expect(find.text('RESOURCE CATALOG'), findsOneWidget);
    expect(find.text('CLOSED / AFTER-ACTION LOG'), findsOneWidget);

    // Verify input fields in NewRequestPanel use the dark input fill.
    final searchField = tester.widget<TextField>(
      find.byKey(const Key('location-search-field')),
    );
    expect(
      searchField.decoration?.fillColor,
      ErasPalette.darkPalette.inputFill,
    );
  });

  testWidgets('dialogs and readiness use dark palette', (tester) async {
    final request = _sampleRequest();
    final resource = _sampleResource();

    await tester.pumpWidget(
      _themed(
        SingleChildScrollView(
          child: Column(
            children: [
              LocationPermissionBanner(onEnableLocation: () async {}),
              const ResponderAvailabilityBanner(
                responder: null,
                unfinishedAllocations: 1,
              ),
              RequestDetailDialog(request: request),
              ResourceEditorDialog(resource: resource),
              ResponderAssignmentDialog(
                request: request,
                responders: const <BackendResponder>[],
              ),
              AllocationDialog(
                requestId: request.id,
                requestProvider: (_) => request,
                inventoryProvider: () => const <BackendResponderResource>[],
                onAllocate: _noopAllocate,
                onCancelAllocation: (_) async => true,
                onDispatchAllocation: (_) async {},
                onMarkDelivered: (_) async {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final detailDialog = tester.widget<Dialog>(
      find.byKey(const Key('request-detail-dialog')),
    );
    expect(detailDialog.backgroundColor, ErasPalette.darkPalette.surface);

    // ResponderReadinessPage in dark mode
    await tester.pumpWidget(
      _themed(ResponderReadinessPage(gateway: _FakeReadinessGateway())),
    );
    await tester.pumpAndSettle();
    expect(find.text('WHAT CAN YOU HELP WITH?'), findsOneWidget);

    // RegisterScreen role cards in dark mode
    await tester.pumpWidget(_themed(const RegisterScreen()));
    await tester.pumpAndSettle();
    final roleFinder = find.ancestor(
      of: find.byKey(const ValueKey<String>('role-card-REQUESTER')),
      matching: find.byType(Material),
    );
    final roleMaterial = tester.widget<Material>(roleFinder.first);
    expect(roleMaterial.color, ErasPalette.darkPalette.surface2);
  });

  testWidgets('RefreshSpinButton respects reduced motion', (tester) async {
    var tapped = 0;
    await tester.pumpWidget(
      _themed(RefreshSpinButton(onPressed: () => tapped++)),
    );

    AnimatedRotation rotation() =>
        tester.widget<AnimatedRotation>(find.byType(AnimatedRotation));

    expect(rotation().turns, 0);
    await tester.tap(find.byType(RefreshSpinButton));
    await tester.pumpAndSettle();
    expect(tapped, 1);
    expect(rotation().turns, 1);

    // Under reduced motion, tapping invokes callback without advancing turns.
    await tester.pumpWidget(
      _themed(
        RefreshSpinButton(onPressed: () => tapped++),
        reducedMotion: true,
      ),
    );
    final beforeTurns = rotation().turns;
    await tester.tap(find.byType(RefreshSpinButton));
    await tester.pump();
    expect(tapped, 2);
    expect(rotation().turns, beforeTurns);
  });
}
