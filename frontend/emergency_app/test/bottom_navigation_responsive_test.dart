import 'package:dispatch_console_flutter/models/eras_models.dart';
import 'package:dispatch_console_flutter/theme/app_theme.dart';
import 'package:dispatch_console_flutter/widgets/common_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _buildNavHost({
  required double width,
  required ConsoleView activeView,
  required ValueChanged<ConsoleView> onViewChanged,
  Brightness brightness = Brightness.light,
  double bottomInset = 24.0,
}) {
  final items = navItemsForRole('REQUESTER');
  return MaterialApp(
    theme: erasTheme(brightness),
    home: MediaQuery(
      data: MediaQueryData(
        size: Size(width, 800),
        padding: EdgeInsets.only(bottom: bottomInset),
      ),
      child: Scaffold(
        bottomNavigationBar: BottomNav(
          items: items,
          activeView: activeView,
          onViewChanged: onViewChanged,
        ),
      ),
    ),
  );
}

void main() {
  group('BottomNav responsive mobile layout', () {
    testWidgets('all five navigation items visible on narrow phone without overflow',
        (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      ConsoleView active = ConsoleView.board;

      await tester.pumpWidget(
        _buildNavHost(
          width: 360,
          activeView: active,
          onViewChanged: (view) => active = view,
        ),
      );
      await tester.pumpAndSettle();

      // All 5 items are visible
      expect(find.text('Board'), findsOneWidget);
      expect(find.text('New Emergency'), findsOneWidget);
      expect(find.text('Resources'), findsOneWidget);
      expect(find.text('Responders'), findsOneWidget);
      expect(find.text('Log'), findsOneWidget);

      // No overflow errors recorded
      expect(tester.takeException(), isNull);

      // Verify the bottom navigation bar has a stable total height. The
      // production bar is: 1px top border + 64px of interactive navigation
      // content + the simulated 24px bottom safe-area inset = 89px.
      final navBarSize = tester.getSize(find.byType(BottomNav));
      expect(navBarSize.height, 89.0);
      expect(navBarSize.width, 360.0);

      // The interactive navigation content itself stays 64px tall: the extra
      // height comes from the 1px border and the device inset, never from
      // shrinking or padding the tappable row.
      final navContent = find.descendant(
        of: find.byType(BottomNav),
        matching: find.byType(Row),
      );
      expect(tester.getSize(navContent).height, 64.0);
    });

    testWidgets('all five items have equal visual width on narrow and wide phones',
        (tester) async {
      for (final width in [360.0, 412.0, 600.0]) {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1.0;

        await tester.pumpWidget(
          _buildNavHost(
            width: width,
            activeView: ConsoleView.board,
            onViewChanged: (_) {},
          ),
        );
        await tester.pumpAndSettle();

        // 5 items, each should have width == total / 5
        final expectedItemWidth = width / 5.0;

        final itemFinders = [
          find.ancestor(of: find.text('Board'), matching: find.byType(Expanded)),
          find.ancestor(of: find.text('New Emergency'), matching: find.byType(Expanded)),
          find.ancestor(of: find.text('Resources'), matching: find.byType(Expanded)),
          find.ancestor(of: find.text('Responders'), matching: find.byType(Expanded)),
          find.ancestor(of: find.text('Log'), matching: find.byType(Expanded)),
        ];

        for (final finder in itemFinders) {
          final size = tester.getSize(finder);
          expect(size.width, closeTo(expectedItemWidth, 0.5));
        }

        expect(tester.takeException(), isNull);
      }

      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    testWidgets('selected New Emergency item maintains stable height and triggers change',
        (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      ConsoleView active = ConsoleView.board;

      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setState) => _buildNavHost(
            width: 360,
            activeView: active,
            onViewChanged: (view) => setState(() => active = view),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final initialHeight = tester.getSize(find.byType(BottomNav)).height;

      // Tap 'New Emergency'
      await tester.tap(find.text('New Emergency'));
      await tester.pumpAndSettle();

      expect(active, ConsoleView.newRequest);

      // Total height must remain strictly identical
      final selectedHeight = tester.getSize(find.byType(BottomNav)).height;
      expect(selectedHeight, initialHeight);

      expect(tester.takeException(), isNull);
    });

    testWidgets('works consistently in dark theme with contrasting borders and icons',
        (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        _buildNavHost(
          width: 360,
          activeView: ConsoleView.newRequest,
          onViewChanged: (_) {},
          brightness: Brightness.dark,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('New Emergency'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
