import 'package:dispatch_console_flutter/screens/responder_readiness_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeGateway implements ResponderReadinessGateway {
  _FakeGateway({
    this.resources = const <dynamic>[],
    this.inventory = const <dynamic>[],
  });

  final List<dynamic> resources;
  final List<dynamic> inventory;
  final List<String> savedHelpTypes = <String>[];
  bool available = false;
  bool heartbeatSent = false;

  @override
  Future<Map<String, dynamic>> getHelpTypes() async => <String, dynamic>{
        'categories': <Map<String, String>>[
          <String, String>{'value': 'FIRE', 'label': 'Fire'},
          <String, String>{'value': 'MEDICAL', 'label': 'Medical'},
          <String, String>{'value': 'RESCUE', 'label': 'Rescue'},
        ],
        'selected': <String>[],
      };

  @override
  Future<List<dynamic>> getResources() async => resources;
  @override
  Future<List<dynamic>> getInventory() async => inventory;

  @override
  Future<void> updateHelpTypes(Iterable<String> values) async {
    savedHelpTypes
      ..clear()
      ..addAll(values);
  }

  @override
  Future<void> setAvailable() async => available = true;
  @override
  Future<void> heartbeat() async => heartbeatSent = true;
  @override
  Future<void> createInventory(Map<String, dynamic> data) async {}
  @override
  Future<void> updateInventory(int id, Map<String, dynamic> data) async {}
}

Widget _host(_FakeGateway gateway, {VoidCallback? onSaved}) => MaterialApp(
      home: ResponderReadinessPage(gateway: gateway, onSaved: onSaved),
    );

void main() {
  testWidgets('renders backend help type selector and empty-inventory guidance',
      (tester) async {
    final gateway = _FakeGateway();
    await tester.pumpWidget(_host(gateway));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('help-type-selector')), findsOneWidget);
    expect(find.text('Fire'), findsOneWidget);
    expect(find.text('Medical'), findsOneWidget);
    expect(find.text('Rescue'), findsOneWidget);
    expect(find.textContaining('You can still choose'), findsOneWidget);
    expect(find.textContaining('No active resources'), findsNothing);
    expect(find.textContaining('Select at least one resource'), findsNothing);
  });

  testWidgets('goes available with FIRE selected and zero resources',
      (tester) async {
    final gateway = _FakeGateway();
    var saved = false;
    await tester.pumpWidget(_host(gateway, onSaved: () => saved = true));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('help-type-FIRE')));
    await tester.pump();

    // The save button sits below the fold on the default 800x600 test
    // surface. Drive the page's actual ListView until the button is
    // revealed, then settle the scroll so the tap below lands on fresh
    // coordinates instead of the stale off-screen ones.
    await tester.scrollUntilVisible(
      find.text('SAVE & GO AVAILABLE'),
      100.0,
      scrollable: find.byType(Scrollable),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('SAVE & GO AVAILABLE'));
    await tester.pumpAndSettle();

    expect(gateway.savedHelpTypes, contains('FIRE'));
    expect(gateway.available, isTrue);
    expect(gateway.heartbeatSent, isTrue);
    expect(saved, isTrue);
  });

  testWidgets('resource inventory controls still render when catalog has rows',
      (tester) async {
    final gateway = _FakeGateway(
      resources: <dynamic>[
        <String, dynamic>{
          'id': 7,
          'name': 'Oxygen',
          'type': 'OXYGEN',
          'mode': 'CONSUMABLE',
          'totalQuantity': 10,
          'availableQuantity': 10,
          'isActive': true,
          'lowStockThreshold': 1,
          'unit': 'cylinders',
        },
      ],
      inventory: <dynamic>[
        <String, dynamic>{
          'id': 9,
          'responderId': 2,
          'resourceId': 7,
          'totalQuantity': 4,
          'availableQuantity': 3,
          'status': 'AVAILABLE',
          'isEnabled': true,
          'responder': <String, dynamic>{
            'name': 'Responder',
            'email': 'r@test.com',
            'responderStatus': 'AVAILABLE',
          },
          'resource': <String, dynamic>{
            'name': 'Oxygen',
            'type': 'OXYGEN',
            'unit': 'cylinders',
          },
        },
      ],
    );

    await tester.pumpWidget(_host(gateway));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('resource-inventory')), findsOneWidget);
    expect(find.text('Oxygen'), findsOneWidget);
    expect(find.text('EDIT RESOURCE INVENTORY'), findsOneWidget);
  });
}
