import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dispatch_console_flutter/main.dart';

void main() {
  testWidgets('dispatch console renders', (tester) async {
    await tester.pumpWidget(const DispatchConsoleApp());

    // Let the initial frame settle.
    await tester.pump();

    expect(find.text('Dispatch Board'), findsOneWidget);

    // Advance past the longest one-shot timer (1300–1999 ms) so all
    // pending timers fire before the widget tree is disposed.
    await tester.pump(const Duration(seconds: 2));

    // Dispose the widget tree cleanly.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
  });
}
