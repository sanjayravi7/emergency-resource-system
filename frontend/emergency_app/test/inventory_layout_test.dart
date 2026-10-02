/// Resource Inventory layout (responder readiness screen).
///
/// The reported bug: on narrow Android viewports the "Total quantity" and
/// "Available quantity" fields collided with each other and with the trailing
/// availability chip, and the "No responder inventory assigned" caption was
/// clipped. The fix keeps both fields but lays them out responsively.
///
/// Locked down here:
///   * no overflow at phone width (and the two fields stack vertically),
///   * side-by-side on wide surfaces,
///   * both fields are always present and still labeled,
///   * the trailing chip is only rendered when there is room for it,
///   * the same rules for SERVICE resources (which have no quantities).
library;

import 'package:dispatch_console_flutter/screens/responder_readiness_page.dart';
import 'package:dispatch_console_flutter/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeGateway implements ResponderReadinessGateway {
  _FakeGateway({this.inventory = const <dynamic>[]});

  final List<dynamic> inventory;

  @override
  Future<Map<String, dynamic>> getHelpTypes() async => <String, dynamic>{
        'categories': <Map<String, String>>[
          <String, String>{'value': 'MEDICAL', 'label': 'Medical'},
        ],
        'selected': <String>['MEDICAL'],
      };

  @override
  Future<List<dynamic>> getResources() async => <dynamic>[
        <String, dynamic>{
          'id': 1,
          'name': 'Oxygen Cylinder',
          'type': 'OXYGEN',
          'mode': 'CONSUMABLE',
          'unit': 'cylinder',
          'isActive': true,
        },
        <String, dynamic>{
          'id': 2,
          'name': 'Ambulance',
          'type': 'VEHICLE',
          'mode': 'SERVICE',
          'unit': 'vehicle',
          'isActive': true,
        },
      ];

  @override
  Future<List<dynamic>> getInventory() async => inventory;

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

Widget _host(_FakeGateway gateway) => MaterialApp(
      theme: erasTheme(Brightness.light),
      home: ResponderReadinessPage(gateway: gateway),
    );

/// The readiness screen is a ListView, so off-screen rows are not built yet.
/// Drive the real scrollable until [target] is on screen (exactly like a user
/// scrolling the inventory section into view).
Future<void> _reveal(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    120.0,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

void _sizeTo(WidgetTester tester, double width, double height) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('narrow phone width stacks the quantity fields with no overflow',
      (tester) async {
    _sizeTo(tester, 360, 900);

    await tester.pumpWidget(_host(_FakeGateway()));
    await tester.pumpAndSettle();

    final total = find.byKey(const ValueKey('total-quantity-1'));
    final available = find.byKey(const ValueKey('available-quantity-1'));
    await _reveal(tester, total);

    expect(total, findsOneWidget);
    expect(available, findsOneWidget);
    expect(tester.takeException(), isNull);

    // Stacked: the two fields start at the same left edge and the available
    // field sits strictly below the total field.
    final totalRect = tester.getRect(total);
    final availableRect = tester.getRect(available);
    expect(availableRect.left, moreOrLessEquals(totalRect.left, epsilon: 1));
    expect(
      availableRect.top,
      greaterThanOrEqualTo(totalRect.bottom),
      reason: 'the fields must stack, never overlap',
    );

    // The caption is still shown, and the trailing chip is not rendered here,
    // which is what removes the reported collision.
    expect(find.text('No responder inventory assigned'), findsOneWidget);
    expect(find.text('0 cylinder'), findsNothing);
  });

  testWidgets('wide widths place the quantity fields side by side',
      (tester) async {
    _sizeTo(tester, 1000, 900);

    await tester.pumpWidget(_host(_FakeGateway()));
    await tester.pumpAndSettle();

    final total = find.byKey(const ValueKey('total-quantity-1'));
    await _reveal(tester, total);

    expect(tester.takeException(), isNull);

    final totalRect = tester.getRect(total);
    final availableRect =
        tester.getRect(find.byKey(const ValueKey('available-quantity-1')));

    expect(
      availableRect.left,
      greaterThan(totalRect.right - 1),
      reason: 'wide layout keeps the fields on one row',
    );
    expect(
      (availableRect.top - totalRect.top).abs(),
      lessThanOrEqualTo(1),
    );

    // With room to spare the summary chip is rendered next to the caption -
    // and it must not overlap it.
    final chip = find.text('0 cylinder');
    expect(chip, findsOneWidget);
    final captionRect =
        tester.getRect(find.text('No responder inventory assigned'));
    expect(
      tester.getRect(chip).left,
      greaterThanOrEqualTo(captionRect.right - 1),
      reason: 'the summary chip keeps clear of the caption',
    );
  });

  testWidgets('a stored inventory row renders the availability summary',
      (tester) async {
    _sizeTo(tester, 1000, 900);

    await tester.pumpWidget(_host(_FakeGateway(inventory: <dynamic>[
      <String, dynamic>{
        'id': 7,
        'responderId': 9,
        'resourceId': 1,
        'totalQuantity': 12,
        'availableQuantity': 5,
        'unit': 'cylinder',
        'status': 'AVAILABLE',
        'isEnabled': true,
      },
    ])));
    await tester.pumpAndSettle();
    await _reveal(tester, find.textContaining('5 / 12 cylinder'));

    expect(find.textContaining('5 / 12 cylinder'), findsOneWidget);
    expect(find.text('No responder inventory assigned'), findsNothing);
  });

  testWidgets('a SERVICE resource has no quantity fields at all',
      (tester) async {
    _sizeTo(tester, 360, 900);

    await tester.pumpWidget(_host(_FakeGateway()));
    await tester.pumpAndSettle();
    await _reveal(tester, find.textContaining('Reusable resource'));

    expect(find.textContaining('Reusable resource'), findsOneWidget);
    expect(find.byKey(const ValueKey('total-quantity-2')), findsNothing);
    expect(find.byKey(const ValueKey('available-quantity-2')), findsNothing);
  });

  testWidgets('resizing from phone to desktop keeps both fields usable',
      (tester) async {
    _sizeTo(tester, 360, 900);

    await tester.pumpWidget(_host(_FakeGateway()));
    await tester.pumpAndSettle();
    await _reveal(tester, find.byKey(const ValueKey('total-quantity-1')));
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(1100, 900);
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('total-quantity-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('available-quantity-1')), findsOneWidget);
  });
}
