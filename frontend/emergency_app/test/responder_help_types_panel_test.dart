import 'package:dispatch_console_flutter/models/eras_models.dart';
import 'package:dispatch_console_flutter/widgets/resource_panels.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget host(Widget child) => MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: SingleChildScrollView(child: child),
        ),
      );

  testWidgets('13. MY HELP TYPES panel renders saved backend categories',
      (tester) async {
    final helpTypes = <ResponderHelpType>[
      const ResponderHelpType(category: 'FIRE', label: 'Fire'),
      const ResponderHelpType(category: 'MEDICAL', label: 'Medical'),
      const ResponderHelpType(category: 'RESCUE', label: 'Rescue'),
    ];

    await tester.pumpWidget(host(
      ResponderHelpTypesPanel(
        helpTypes: helpTypes,
        title: 'MY HELP TYPES',
        onEditHelpTypes: () {},
      ),
    ));
    await tester.pump();

    expect(find.text('MY HELP TYPES'), findsOneWidget);
    expect(find.text('FIRE'), findsOneWidget);
    expect(find.text('MEDICAL'), findsOneWidget);
    expect(find.text('RESCUE'), findsOneWidget);
    expect(find.text('EDIT MY HELP TYPES'), findsOneWidget);
  });

  testWidgets('14. Empty inventory does not hide help types', (tester) async {
    final helpTypes = <ResponderHelpType>[
      const ResponderHelpType(category: 'FIRE', label: 'Fire'),
    ];
    final emptyInventory = <BackendResponderResource>[];

    await tester.pumpWidget(host(
      Column(
        children: [
          ResponderHelpTypesPanel(
            helpTypes: helpTypes,
            title: 'MY HELP TYPES',
          ),
          const SizedBox(height: 18),
          ResponderResourcesPanel(
            resources: emptyInventory,
            title: 'RESOURCE INVENTORY',
          ),
        ],
      ),
    ));
    await tester.pump();

    // MY HELP TYPES shows FIRE
    expect(find.text('MY HELP TYPES'), findsOneWidget);
    expect(find.text('FIRE'), findsOneWidget);

    // RESOURCE INVENTORY shows empty state without hiding help types
    expect(find.text('RESOURCE INVENTORY'), findsOneWidget);
    expect(find.text('NO INVENTORY'), findsOneWidget);
  });

  testWidgets('19. Help-type editing action still works', (tester) async {
    var editClicked = false;

    await tester.pumpWidget(host(
      ResponderHelpTypesPanel(
        helpTypes: const <ResponderHelpType>[
          ResponderHelpType(category: 'FIRE', label: 'Fire'),
        ],
        onEditHelpTypes: () => editClicked = true,
      ),
    ));
    await tester.pump();

    await tester.tap(find.text('EDIT MY HELP TYPES'));
    await tester.pump();
    expect(editClicked, isTrue);
  });

  testWidgets(
      'Clean empty state for ResponderHelpTypesPanel when none configured',
      (tester) async {
    await tester.pumpWidget(host(
      const ResponderHelpTypesPanel(
        helpTypes: <ResponderHelpType>[],
        title: 'MY HELP TYPES',
      ),
    ));
    await tester.pump();

    expect(find.text('MY HELP TYPES'), findsOneWidget);
    expect(find.text('NO HELP TYPES CONFIGURED'), findsOneWidget);
  });
}
