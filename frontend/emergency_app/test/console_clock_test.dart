/// The console timer must be a true 24-hour `HH:MM:SS` value: zero padded to
/// two digits, no AM/PM marker, hours 00-23 - and it must not force the whole
/// dispatch console to rebuild once per second.
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
    test('renders zero padded 24-hour HH:MM:SS', () {
      expect(formatErasClock(DateTime(2026, 10, 2, 0, 2, 7)), '00:02:07');
      expect(formatErasClock(DateTime(2026, 10, 2, 8, 45, 3)), '08:45:03');
      expect(formatErasClock(DateTime(2026, 10, 2, 13, 5, 59)), '13:05:59');
      expect(formatErasClock(DateTime(2026, 10, 2, 19, 32, 41)), '19:32:41');
      expect(formatErasClock(DateTime(2026, 10, 2, 23, 59, 59)), '23:59:59');
    });

    test('never contains an AM/PM marker or a 12-hour rollover', () {
      for (var hour = 0; hour < 24; hour++) {
        final label = formatErasClock(DateTime(2026, 10, 2, hour, 0, 0));
        expect(label, '${hour.toString().padLeft(2, '0')}:00:00');
        expect(label.toUpperCase(), isNot(contains('AM')));
        expect(label.toUpperCase(), isNot(contains('PM')));
      }
      // Noon and midnight are distinct values, never confused with each other.
      expect(formatErasClock(DateTime(2026, 10, 2, 12, 30)), '12:30:00');
      expect(formatErasClock(DateTime(2026, 10, 2, 0, 30)), '00:30:00');
    });

    test('is always exactly 8 characters', () {
      for (var minute = 0; minute < 60; minute++) {
        expect(
          formatErasClock(DateTime(2026, 10, 2, 7, minute, 9)).length,
          8,
        );
      }
    });
  });

  group('ErasClock widget', () {
    testWidgets('shows the injected time and ticks to the next second',
        (tester) async {
      var now = DateTime(2026, 10, 2, 9, 5, 58);

      await tester.pumpWidget(_host(ErasClock(now: () => now)));
      await tester.pump();

      expect(find.text('09:05:58'), findsOneWidget);

      now = DateTime(2026, 10, 2, 9, 5, 59);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('09:05:59'), findsOneWidget);

      // Crossing midnight keeps the 24-hour zero padding (00:MM:SS).
      now = DateTime(2026, 10, 3, 0, 0, 0);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('00:00:00'), findsOneWidget);

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

        final text = tester.widget<Text>(find.text('21:07:06'));
        expect(
          text.style?.color,
          ErasPalette.forBrightness(brightness).textDim,
        );
      }
    });
  });

  group('console surfaces', () {
    testWidgets('Rail renders the 24-hour clock text it is given',
        (tester) async {
      await tester.pumpWidget(
        _host(
          SizedBox(
            height: 420,
            child: Rail(
              items: navItemsForRole('REQUESTER'),
              activeView: ConsoleView.board,
              onViewChanged: (_) {},
              clock: '07:04:09',
              roleLabel: 'Asha · REQUESTER',
              onRefresh: _noop,
              onLogout: _noop,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('07:04:09'), findsOneWidget);
      expect(find.text('7:04 AM'), findsNothing);
    });

    testWidgets('MobileAppBar renders the 24-hour clock text it is given',
        (tester) async {
      await tester.pumpWidget(
        _host(
          const Scaffold(
            appBar: MobileAppBar(
              clock: '00:01:02',
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

      expect(find.text('00:01:02'), findsOneWidget);
      expect(find.text('12:01:02 AM'), findsNothing);
    });
  });
}
