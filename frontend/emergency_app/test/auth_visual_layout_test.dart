/// Geometry contract for the reference authentication design.
///
/// The reference composition is authored on a 1648x926 canvas:
///   - branding at x:55 y:40,
///   - hero + network illustration + flow strip + status cards in a 780px
///     story column (x:55..835),
///   - 400px login card starting at x:865 (centre-right),
///   - 302px "Why ERAS?" column starting at x:1291,
///   - trust card bottom-right, flush with the 40px page margin.
///
/// These tests pin those coordinates (with small tolerances for font
/// metrics) so the presentation cannot drift from the reference layout.
/// They complement - never replace - the behavioural auth tests.
library;

import 'package:dispatch_console_flutter/screens/login_screen.dart';
import 'package:dispatch_console_flutter/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pumpLogin(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: erasTheme(Brightness.light),
      home: const LoginScreen(),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('desktop composition matches the reference geometry',
      (tester) async {
    await _pumpLogin(tester, const Size(1648, 926));
    expect(tester.takeException(), isNull);

    Rect rect(Finder finder) => tester.getRect(finder);

    // Branding sits at the reference origin (x: 55, y: 40).
    final brand = rect(find.byKey(const ValueKey('eras-brand-shield')));
    expect(brand.left, closeTo(55, 2));
    expect(brand.top, closeTo(40, 2));

    // The network illustration spans the story column (x:55..835).
    final network = rect(find.byKey(const ValueKey('auth-network')));
    expect(network.left, closeTo(55, 6));
    expect(network.width, closeTo(780, 12));

    // Status cards sit at the bottom of the story column.
    final status = rect(find.byKey(const ValueKey('auth-status-cards')));
    expect(status.left, closeTo(55, 6));
    expect(status.right, lessThanOrEqualTo(836));
    expect(status.bottom, closeTo(886, 4));

    // The flow strip is centred under the illustration.
    final flow = rect(find.byKey(const ValueKey('auth-flow')));
    expect(flow.center.dx, closeTo(445, 26));

    // Login card is centre-right: 400px wide, right after the story column.
    final login = rect(find.byKey(const ValueKey('auth-login-card')));
    expect(login.width, closeTo(400, 4));
    expect(login.left, closeTo(865, 8));
    expect((login.top + login.bottom) / 2, closeTo(511, 24));

    // "Why ERAS?" column sits immediately right of the login card.
    final why = rect(find.byKey(const ValueKey('auth-why-eras')));
    expect(why.left, closeTo(1291, 8));
    expect(why.width, closeTo(302, 6));
    expect(why.top, greaterThan(120));
    expect(why.top, lessThan(180));

    // Trust card is bottom-right, flush with the page margin.
    final trust = rect(find.byKey(const ValueKey('auth-trust-card')));
    expect(trust.right, closeTo(1593, 6));
    expect(trust.bottom, closeTo(886, 4));
    expect(trust.top, greaterThan(why.bottom));

    // Heading: first two lines navy, "Right Time." teal.
    Color? colorOf(String text) =>
        tester.widget<Text>(find.text(text)).style?.color;
    expect(colorOf('Right Resource.'), const Color(0xFF10213B));
    expect(colorOf('Right Place.'), const Color(0xFF10213B));
    expect(colorOf('Right Time.'), const Color(0xFF12B99D));
  });

  testWidgets('phone brings the login card directly below the brand',
      (tester) async {
    await _pumpLogin(tester, const Size(390, 844));
    expect(tester.takeException(), isNull);

    // The large marketing hero is retained on tablet/desktop, but not placed
    // above the sign-in form on a phone where it pushes the card too far down.
    expect(find.text('Right Resource.'), findsNothing);

    double top(Finder finder) => tester.getRect(finder).top;
    final order = <Finder>[
      find.byKey(const ValueKey('eras-brand-shield')),
      find.byKey(const ValueKey('auth-login-card')),
      find.byKey(const ValueKey('auth-why-eras')),
      find.byKey(const ValueKey('auth-trust-card')),
      find.byKey(const ValueKey('auth-status-cards')),
    ];
    for (var i = 1; i < order.length; i++) {
      expect(top(order[i]), greaterThan(top(order[i - 1])));
    }

    final login = tester.getRect(find.byKey(const ValueKey('auth-login-card')));
    expect(login.top, lessThan(130));
    expect(login.left, greaterThanOrEqualTo(16));
    expect(login.right, lessThanOrEqualTo(390));
  });

  testWidgets('tablet keeps the full hierarchy and stays overflow-free',
      (tester) async {
    await _pumpLogin(tester, const Size(834, 1112));
    expect(tester.takeException(), isNull);

    double top(Finder finder) => tester.getRect(finder).top;
    final order = <Finder>[
      find.byKey(const ValueKey('eras-brand-shield')),
      find.text('Right Resource.'),
      find.byKey(const ValueKey('auth-network')),
      find.byKey(const ValueKey('auth-flow')),
      find.byKey(const ValueKey('auth-login-card')),
      find.byKey(const ValueKey('auth-why-eras')),
      find.byKey(const ValueKey('auth-trust-card')),
      find.byKey(const ValueKey('auth-status-cards')),
    ];
    for (var i = 1; i < order.length; i++) {
      expect(top(order[i]), greaterThan(top(order[i - 1])));
    }
  });
}
