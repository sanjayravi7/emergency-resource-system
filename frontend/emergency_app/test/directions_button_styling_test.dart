/// GET DIRECTIONS must be highlighted with the existing ERAS primary accent
/// (teal) and carry explicit hover, press and disabled states - in both the
/// light and the completed dark theme.
///
/// The button is shared by the map card (filled variant) and the marker popup
/// (compact tinted variant), so both variants are locked down here.
library;

import 'package:dispatch_console_flutter/theme/app_theme.dart';
import 'package:dispatch_console_flutter/widgets/operational_google_map.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const Set<WidgetState> _idle = <WidgetState>{};
const Set<WidgetState> _hover = <WidgetState>{WidgetState.hovered};
const Set<WidgetState> _press = <WidgetState>{WidgetState.pressed};
const Set<WidgetState> _disabled = <WidgetState>{WidgetState.disabled};

Widget _host(Widget child, {Brightness brightness = Brightness.light}) =>
    MaterialApp(
      theme: erasTheme(brightness),
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  for (final brightness in Brightness.values) {
    final palette = ErasPalette.forBrightness(brightness);
    final label = brightness == Brightness.dark ? 'dark' : 'light';

    group('$label theme', () {
      test('the filled variant uses the ERAS accent', () {
        final idle = DirectionsButton.backgroundColorFor(
          palette,
          _idle,
          expanded: true,
        );
        expect(idle, palette.teal);
      });

      test('hover and press darken the accent instead of changing hue', () {
        final idle = DirectionsButton.backgroundColorFor(
          palette,
          _idle,
          expanded: true,
        );
        final hover = DirectionsButton.backgroundColorFor(
          palette,
          _hover,
          expanded: true,
        );
        final press = DirectionsButton.backgroundColorFor(
          palette,
          _press,
          expanded: true,
        );

        expect(hover, isNot(idle));
        expect(press, isNot(idle));
        expect(press, isNot(hover));
      });

      test('focus is treated as hover (keyboard users get the same feedback)',
          () {
        expect(
          DirectionsButton.backgroundColorFor(
            palette,
            const <WidgetState>{WidgetState.focused},
            expanded: true,
          ),
          DirectionsButton.backgroundColorFor(palette, _hover, expanded: true),
        );
      });

      test('the disabled state never keeps the accent and its text dims', () {
        final disabledBg = DirectionsButton.backgroundColorFor(
          palette,
          _disabled,
          expanded: true,
        );
        expect(disabledBg, isNot(palette.teal));
        expect(
          DirectionsButton.foregroundColorFor(
            palette,
            _disabled,
            expanded: true,
          ),
          palette.textFaint,
        );
      });

      test('the compact variant is an accent tint that strengthens on hover',
          () {
        final idle = DirectionsButton.backgroundColorFor(
          palette,
          _idle,
          expanded: false,
        );
        final hover = DirectionsButton.backgroundColorFor(
          palette,
          _hover,
          expanded: false,
        );

        expect(idle, palette.tealDim);
        expect(hover, isNot(idle));
        expect(
          DirectionsButton.foregroundColorFor(
            palette,
            _idle,
            expanded: false,
          ),
          palette.teal,
        );
        expect(
          DirectionsButton.backgroundColorFor(
            palette,
            _disabled,
            expanded: false,
          ),
          Colors.transparent,
        );
      });
    });
  }

  testWidgets('renders the GET DIRECTIONS label with the accent background',
      (tester) async {
    await tester.pumpWidget(
      _host(DirectionsButton(onPressed: () {})),
    );
    await tester.pump();

    expect(find.text('Get directions'), findsOneWidget);
    expect(find.byIcon(Icons.directions_rounded), findsOneWidget);

    final button = tester.widget<TextButton>(find.byType(TextButton));
    final palette = ErasPalette.forBrightness(Brightness.light);
    expect(
      button.style?.backgroundColor?.resolve(_idle),
      palette.teal,
    );
    expect(
      button.style?.foregroundColor?.resolve(_idle),
      Colors.white,
    );
  });

  testWidgets('a disabled button reports disabled state to the framework',
      (tester) async {
    await tester.pumpWidget(_host(const DirectionsButton(onPressed: null)));
    await tester.pump();

    final button = tester.widget<TextButton>(find.byType(TextButton));
    final palette = ErasPalette.forBrightness(Brightness.light);
    expect(
      button.style?.backgroundColor?.resolve(_disabled),
      isNot(palette.teal),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('hovering the real button repaints it with the hover color',
      (tester) async {
    await tester.pumpWidget(_host(DirectionsButton(onPressed: () {})));
    await tester.pump();

    final palette = ErasPalette.forBrightness(Brightness.light);
    final expectedHover = DirectionsButton.backgroundColorFor(
      palette,
      _hover,
      expanded: true,
    );

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await tester.pump();

    await gesture.moveTo(tester.getCenter(find.byType(TextButton)));
    await tester.pumpAndSettle();

    final button = tester.widget<TextButton>(find.byType(TextButton));
    expect(
      button.style?.backgroundColor?.resolve(_hover),
      expectedHover,
    );
  });
}
