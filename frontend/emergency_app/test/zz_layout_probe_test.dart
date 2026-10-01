/// TEMPORARY diagnostic probe - removed before merge.
///
/// Dumps the geometry of the register screen at 360x800 so the CI report
/// shows exactly where the role card sits one frame in and after the
/// entrance animation settles.
library;

import 'package:dispatch_console_flutter/screens/register_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('probe register layout at 360x800', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: RegisterScreen()));
    await tester.pump();

    final buffer = StringBuffer();
    void rect(String name, Finder finder) {
      buffer.writeln('$name: ${tester.getRect(finder.first)}');
    }

    rect('brand-shield', find.byKey(const ValueKey('eras-brand-shield')));
    rect('underline', find.byKey(const ValueKey('auth-tabs-underline')));
    rect('create-account', find.text('CREATE ACCOUNT'));
    rect('how-question', find.text('How would you like to use ERAS?'));
    rect('req-card@pump1', find.byKey(const ValueKey('role-card-REQUESTER')));

    await tester.pump(const Duration(seconds: 3));
    rect('req-card@settled',
        find.byKey(const ValueKey('role-card-REQUESTER')));

    fail(buffer.toString());
  });
}
