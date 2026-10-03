import 'package:dispatch_console_flutter/models/eras_models.dart';
import 'package:dispatch_console_flutter/theme/app_theme.dart';
import 'package:dispatch_console_flutter/widgets/common_widgets.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Two representative navigation rows. `board` doubles as the item used to
// prove the ACTIVE state; `responders` is a plain non-active row.
const NavItem _board = NavItem(
  ConsoleView.board,
  Icons.dashboard_outlined,
  'Board',
);
const NavItem _responders = NavItem(
  ConsoleView.responders,
  Icons.groups_2_outlined,
  'Responders',
);

// A location safely inside the empty area below both rows, used to park the
// pointer so that no row is hovered.
const Offset _emptySpot = Offset(400, 500);

// Both palettes, so every contract assertion is checked in light AND dark.
const List<ErasPalette> _palettes = [
  ErasPalette.light,
  ErasPalette.darkPalette
];

/// Wraps the navigation rows in a themed app so the palette resolves the same
/// way it does inside the real dispatch console.
Widget _rail({
  required Brightness brightness,
  bool boardActive = false,
  bool respondersActive = false,
  VoidCallback? onBoardTap,
  VoidCallback? onRespondersTap,
}) {
  final mode = brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light;
  return MaterialApp(
    theme: erasTheme(Brightness.light),
    darkTheme: erasTheme(Brightness.dark),
    themeMode: mode,
    home: Scaffold(
      body: SizedBox(
        height: 600,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            NavButton(
              key: const ValueKey('nav-board'),
              item: _board,
              active: boardActive,
              onTap: onBoardTap ?? () {},
            ),
            NavButton(
              key: const ValueKey('nav-responders'),
              item: _responders,
              active: respondersActive,
              onTap: onRespondersTap ?? () {},
            ),
            const Expanded(child: SizedBox.shrink()),
          ],
        ),
      ),
    ),
  );
}

/// The single [AnimatedContainer] that paints a navigation row's background.
BoxDecoration _deco(WidgetTester tester, String key) {
  final container = tester.widget<AnimatedContainer>(
    find
        .descendant(
          of: find.byKey(ValueKey(key)),
          matching: find.byType(AnimatedContainer),
        )
        .first,
  );
  return container.decoration! as BoxDecoration;
}

BorderSide _leftIndicator(BoxDecoration decoration) =>
    (decoration.border as Border).left;

/// Creates a persistent mouse pointer parked in the empty area so that, by
/// default, no row is hovered. Callers move it with `moveTo` to hover a row.
Future<TestGesture> _beginHover(WidgetTester tester) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: _emptySpot);
  addTearDown(gesture.removePointer);
  await tester.pump();
  return gesture;
}

Future<void> _hover(
  TestGesture gesture,
  WidgetTester tester,
  String key,
) async {
  await gesture.moveTo(tester.getCenter(find.byKey(ValueKey(key))));
  await tester.pumpAndSettle();
}

void main() {
  // ── Explicit theme-aware navigation-state contract ────────────────────────

  test('contract: ACTIVE is a strong selection in both themes', () {
    for (final palette in _palettes) {
      final active = NavButtonStyle.resolve(
        palette: palette,
        active: true,
        hovered: false,
      );
      expect(active.background, palette.tealDim);
      expect(active.leftIndicator, palette.teal);
      expect(active.foreground, palette.teal);
      expect(active.fontWeight, FontWeight.w600);
      expect(active.background.a, 1.0);

      // ACTIVE + HOVER must be the ACTIVE styling: a hovered active row never
      // gains a second (hover) layer.
      final activeHovered = NavButtonStyle.resolve(
        palette: palette,
        active: true,
        hovered: true,
      );
      expect(activeHovered.background, active.background);
      expect(activeHovered.leftIndicator, active.leftIndicator);
      expect(activeHovered.foreground, active.foreground);
      expect(activeHovered.fontWeight, active.fontWeight);
    }
  });

  test('contract: HOVER is subtle and never looks active', () {
    for (final palette in _palettes) {
      final hover = NavButtonStyle.resolve(
        palette: palette,
        active: false,
        hovered: true,
      );
      final active = NavButtonStyle.resolve(
        palette: palette,
        active: true,
        hovered: false,
      );
      final normal = NavButtonStyle.resolve(
        palette: palette,
        active: false,
        hovered: false,
      );

      // Subtle tint: present, low alpha, and clearly weaker than the opaque
      // ACTIVE mint background.
      expect(hover.background, isNot(Colors.transparent));
      expect(hover.background.a, lessThan(0.2));
      expect(hover.background, isNot(active.background));

      // Never active-looking: no left indicator and not the teal accent text.
      expect(hover.leftIndicator, Colors.transparent);
      expect(hover.foreground, isNot(palette.teal));
      expect(hover.fontWeight, isNot(FontWeight.w600));

      // A small emphasis over the NORMAL state.
      expect(hover.foreground, isNot(normal.foreground));
    }
  });

  test('contract: NORMAL is neutral', () {
    for (final palette in _palettes) {
      final normal = NavButtonStyle.resolve(
        palette: palette,
        active: false,
        hovered: false,
      );
      expect(normal.background, Colors.transparent);
      expect(normal.leftIndicator, Colors.transparent);
      expect(normal.foreground, palette.textDim);
      expect(normal.fontWeight, FontWeight.w400);
    }
  });

  test('contract: hover tint is theme-aware but semantically identical', () {
    final lightHover = NavButtonStyle.resolve(
      palette: ErasPalette.light,
      active: false,
      hovered: true,
    );
    final darkHover = NavButtonStyle.resolve(
      palette: ErasPalette.darkPalette,
      active: false,
      hovered: true,
    );

    // Same semantic (a faint teal wash), theme-aware strength.
    final lightTint = ErasPalette.light.teal.withValues(alpha: 0.08);
    final darkTint = ErasPalette.darkPalette.teal.withValues(alpha: 0.12);
    expect(lightHover.background, lightTint);
    expect(darkHover.background, darkTint);
    expect(lightHover.background, isNot(darkHover.background));

    // Both themes keep the same "never active" guarantees.
    expect(lightHover.leftIndicator, Colors.transparent);
    expect(darkHover.leftIndicator, Colors.transparent);
  });

  // ── Widget behaviour ──────────────────────────────────────────────────────

  testWidgets('1. light inactive item is transparent when not hovered',
      (tester) async {
    await tester.pumpWidget(_rail(brightness: Brightness.light));
    await tester.pumpAndSettle();

    final decoration = _deco(tester, 'nav-board');
    expect(decoration.color, Colors.transparent);
    expect(_leftIndicator(decoration).color, Colors.transparent);
  });

  testWidgets('2. light inactive item gets a subtle hover background',
      (tester) async {
    await tester.pumpWidget(_rail(brightness: Brightness.light));
    await tester.pumpAndSettle();
    expect(_deco(tester, 'nav-board').color, Colors.transparent);

    final gesture = await _beginHover(tester);
    await _hover(gesture, tester, 'nav-board');

    final decoration = _deco(tester, 'nav-board');
    final expected = NavButtonStyle.resolve(
      palette: ErasPalette.light,
      active: false,
      hovered: true,
    );
    expect(decoration.color, expected.background);
    expect(decoration.color, isNot(Colors.transparent));
    expect(decoration.color!.a, lessThan(0.2));
  });

  testWidgets('3. light hovered inactive item has no active left indicator',
      (tester) async {
    await tester.pumpWidget(_rail(brightness: Brightness.light));
    await tester.pumpAndSettle();

    final gesture = await _beginHover(tester);
    await _hover(gesture, tester, 'nav-responders');

    final indicator = _leftIndicator(_deco(tester, 'nav-responders'));
    expect(indicator.color, Colors.transparent);
    // The indicator geometry is preserved; only its colour changes.
    expect(indicator.width, 3);
  });

  testWidgets('4. active item shows the active background and teal indicator',
      (tester) async {
    await tester.pumpWidget(
      _rail(brightness: Brightness.light, boardActive: true),
    );
    await tester.pumpAndSettle();

    final decoration = _deco(tester, 'nav-board');
    expect(decoration.color, ErasPalette.light.tealDim);
    final indicator = _leftIndicator(decoration);
    expect(indicator.color, ErasPalette.light.teal);
    expect(indicator.width, 3);
  });

  testWidgets('5. hovering the active item keeps it active (no second layer)',
      (tester) async {
    await tester.pumpWidget(
      _rail(brightness: Brightness.light, boardActive: true),
    );
    await tester.pumpAndSettle();

    final gesture = await _beginHover(tester);
    await _hover(gesture, tester, 'nav-board');

    final decoration = _deco(tester, 'nav-board');
    // Still the opaque active mint, NOT the subtle hover tint.
    expect(decoration.color, ErasPalette.light.tealDim);
    final hoverTint = ErasPalette.light.teal.withValues(alpha: 0.08);
    expect(decoration.color, isNot(hoverTint));
    // Still the teal indicator.
    final indicator = _leftIndicator(decoration);
    expect(indicator.color, ErasPalette.light.teal);
    expect(indicator.width, 3);
  });

  testWidgets('6. hover exit returns to the normal inactive state',
      (tester) async {
    await tester.pumpWidget(_rail(brightness: Brightness.light));
    await tester.pumpAndSettle();

    final gesture = await _beginHover(tester);
    await _hover(gesture, tester, 'nav-board');
    expect(_deco(tester, 'nav-board').color, isNot(Colors.transparent));

    // Pointer leaves the row.
    await gesture.moveTo(_emptySpot);
    await tester.pumpAndSettle();

    final decoration = _deco(tester, 'nav-board');
    expect(decoration.color, Colors.transparent);
    expect(_leftIndicator(decoration).color, Colors.transparent);
  });

  testWidgets('7. hovering one item leaves the other unhovered',
      (tester) async {
    await tester.pumpWidget(_rail(brightness: Brightness.light));
    await tester.pumpAndSettle();

    final gesture = await _beginHover(tester);
    await _hover(gesture, tester, 'nav-responders');

    expect(_deco(tester, 'nav-responders').color, isNot(Colors.transparent));
    expect(_deco(tester, 'nav-board').color, Colors.transparent);
    final boardLeft = _leftIndicator(_deco(tester, 'nav-board'));
    expect(boardLeft.color, Colors.transparent);
  });

  testWidgets('8. switching light <-> dark yields theme-aware nav colors',
      (tester) async {
    await tester.pumpWidget(
      _rail(brightness: Brightness.light, boardActive: true),
    );
    await tester.pumpAndSettle();

    // Light: active board uses the light mint + light teal indicator.
    expect(_deco(tester, 'nav-board').color, ErasPalette.light.tealDim);
    final lightActiveLeft = _leftIndicator(_deco(tester, 'nav-board'));
    expect(lightActiveLeft.color, ErasPalette.light.teal);

    // Light: hovered non-active row uses the light subtle tint.
    final gesture = await _beginHover(tester);
    await _hover(gesture, tester, 'nav-responders');
    final lightHover = _deco(tester, 'nav-responders').color;
    final lightHoverTint = ErasPalette.light.teal.withValues(alpha: 0.08);
    expect(lightHover, lightHoverTint);
    final lightHoverLeft = _leftIndicator(_deco(tester, 'nav-responders'));
    expect(lightHoverLeft.color, Colors.transparent);

    // Switch to dark and re-render.
    await tester.pumpWidget(
      _rail(brightness: Brightness.dark, boardActive: true),
    );
    await tester.pumpAndSettle();

    // Dark: active board uses the dark mint + dark teal indicator.
    expect(_deco(tester, 'nav-board').color, ErasPalette.darkPalette.tealDim);
    final darkActiveLeft = _leftIndicator(_deco(tester, 'nav-board'));
    expect(darkActiveLeft.color, ErasPalette.darkPalette.teal);

    // Dark: re-hover the same row; it now uses the dark subtle tint.
    await gesture.moveTo(_emptySpot);
    await tester.pump();
    await _hover(gesture, tester, 'nav-responders');
    final darkHover = _deco(tester, 'nav-responders').color;
    final darkHoverTint = ErasPalette.darkPalette.teal.withValues(alpha: 0.12);
    expect(darkHover, darkHoverTint);
    expect(lightHover, isNot(darkHover));
  });

  testWidgets('9. hover does not change row geometry', (tester) async {
    await tester.pumpWidget(_rail(brightness: Brightness.light));
    await tester.pumpAndSettle();

    final board = find.byKey(const ValueKey('nav-board'));
    final sizeBefore = tester.getSize(board);
    expect(_leftIndicator(_deco(tester, 'nav-board')).width, 3);

    final gesture = await _beginHover(tester);
    await _hover(gesture, tester, 'nav-board');

    expect(tester.getSize(board), sizeBefore);
    expect(_leftIndicator(_deco(tester, 'nav-board')).width, 3);
  });

  testWidgets('10. navigation callbacks still fire', (tester) async {
    var boardTaps = 0;
    var responderTaps = 0;
    await tester.pumpWidget(
      _rail(
        brightness: Brightness.light,
        onBoardTap: () => boardTaps++,
        onRespondersTap: () => responderTaps++,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('nav-board')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('nav-responders')));
    await tester.pumpAndSettle();

    expect(boardTaps, 1);
    expect(responderTaps, 1);
  });

  // ── Integration: active state comes only from the navigation state ─────---

  testWidgets('Rail marks only the active view as selected (never hover)',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: erasTheme(Brightness.light),
        home: Scaffold(
          body: Rail(
            items: navItemsForRole('ADMIN'),
            activeView: ConsoleView.board,
            onViewChanged: (_) {},
            clock: '12:00:00',
            roleLabel: 'Admin · ADMIN',
            onRefresh: () {},
            onLogout: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Sidebar width is preserved.
    expect(tester.getSize(find.byType(Rail)).width, 208);

    BoxDecoration decoFor(String label) {
      final container = tester.widget<AnimatedContainer>(
        find
            .descendant(
              of: find.ancestor(
                of: find.text(label),
                matching: find.byType(NavButton),
              ),
              matching: find.byType(AnimatedContainer),
            )
            .first,
      );
      return container.decoration! as BoxDecoration;
    }

    // The active view (Board) is the only selected row.
    expect(decoFor('Board').color, ErasPalette.light.tealDim);
    final boardLeft = (decoFor('Board').border as Border).left;
    expect(boardLeft.color, ErasPalette.light.teal);

    // Every other row is neutral: no selection and no hover treatment.
    for (final label in ['New Emergency', 'Resources', 'Responders', 'Log']) {
      expect(decoFor(label).color, Colors.transparent, reason: label);
      final left = (decoFor(label).border as Border).left;
      expect(left.color, Colors.transparent, reason: label);
    }
  });
}
