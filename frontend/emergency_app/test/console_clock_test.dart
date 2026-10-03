/// The console timer displays `h:MM AM/PM`, checks the time once per second,
/// and only rebuilds the clock label when its displayed minute changes.
library;

import 'package:dispatch_console_flutter/models/eras_models.dart';
import 'package:dispatch_console_flutter/services/socket_service.dart';
import 'package:dispatch_console_flutter/theme/app_theme.dart';
import 'package:dispatch_console_flutter/widgets/common_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child, {Brightness brightness = Brightness.light}) =>
    MaterialApp(
      theme: erasTheme(brightness),
      home: Scaffold(body: Center(child: child)),
    );

void _noop() {}

void main() {
  group('formatErasClock', () {
    test('formats midnight as 12-hour AM time', () {
      expect(formatErasClock(DateTime(2026, 10, 2, 0, 5)), '12:05 AM');
    });

    test('formats morning without a leading zero on the hour', () {
      expect(formatErasClock(DateTime(2026, 10, 2, 1, 7)), '1:07 AM');
      expect(formatErasClock(DateTime(2026, 10, 2, 10, 12)), '10:12 AM');
    });

    test('formats noon as 12 PM', () {
      expect(formatErasClock(DateTime(2026, 10, 2, 12)), '12:00 PM');
    });

    test('formats afternoon as PM time', () {
      expect(formatErasClock(DateTime(2026, 10, 2, 13, 12)), '1:12 PM');
    });

    test('formats evening as PM time', () {
      expect(formatErasClock(DateTime(2026, 10, 2, 22, 12)), '10:12 PM');
    });

    test('formats 11:59 PM and never displays seconds', () {
      expect(formatErasClock(DateTime(2026, 10, 2, 23, 59, 59)), '11:59 PM');
    });

    test('every hour is represented as a valid 12-hour label', () {
      for (var hour = 0; hour < 24; hour++) {
        final label = formatErasClock(DateTime(2026, 10, 2, hour, 0, 45));
        expect(label, matches(RegExp(r'^(?:[1-9]|1[0-2]):00 (?:AM|PM)$')));
      }
    });
  });

  group('ErasClock widget', () {
    testWidgets('samples every second but displays only hours and minutes',
        (tester) async {
      var now = DateTime(2026, 10, 2, 9, 5, 58);

      await tester.pumpWidget(_host(ErasClock(now: () => now)));
      await tester.pump();

      expect(find.text('9:05 AM'), findsOneWidget);
      expect(find.text('9:05:58'), findsNothing);

      // A second passes internally, but the rendered value contains no seconds.
      now = DateTime(2026, 10, 2, 9, 5, 59);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('9:05 AM'), findsOneWidget);

      // The next one-second tick observes the minute change and updates
      // the label.
      now = DateTime(2026, 10, 2, 9, 6, 0);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('9:06 AM'), findsOneWidget);

      // The periodic timer must not outlive the widget.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
      expect(tester.takeException(), isNull);
    });

    testWidgets('uses the palette clock color in both themes', (tester) async {
      final fixed = DateTime(2026, 10, 2, 21, 7, 6);

      for (final brightness in Brightness.values) {
        await tester.pumpWidget(
          _host(ErasClock(now: () => fixed), brightness: brightness),
        );
        // AnimatedTheme lerps between palettes, so the first frame after the
        // switch still reports the PREVIOUS palette. Let the transition play
        // out before reading the colour.
        await tester.pump(const Duration(milliseconds: 400));

        final text = tester.widget<Text>(find.text('9:07 PM'));
        expect(
          text.style?.color,
          ErasPalette.forBrightness(brightness).textDim,
        );
      }
    });
  });

  group('console surfaces', () {
    testWidgets('Rail renders the 12-hour clock text it is given',
        (tester) async {
      await tester.pumpWidget(
        _host(
          SizedBox(
            height: 420,
            child: Rail(
              items: navItemsForRole('REQUESTER'),
              activeView: ConsoleView.board,
              onViewChanged: (_) {},
              clock: '7:04 AM',
              roleLabel: 'Asha · REQUESTER',
              onRefresh: _noop,
              onLogout: _noop,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('7:04 AM'), findsOneWidget);
    });

    testWidgets('MobileAppBar renders the 12-hour clock text it is given',
        (tester) async {
      await tester.pumpWidget(
        _host(
          const Scaffold(
            appBar: MobileAppBar(
              clock: '12:01 AM',
              pending: 1,
              active: 2,
              completed: 3,
              title: 'Dispatch Board',
              onRefresh: _noop,
              onLogout: _noop,
              connectionStatus: RealtimeConnectionStatus.offline,
            ),
            body: SizedBox.shrink(),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('12:01 AM'), findsOneWidget);
    });
  });
}
