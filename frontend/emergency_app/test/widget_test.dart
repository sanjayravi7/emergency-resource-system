import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dispatch_console_flutter/main.dart';

void main() {
  testWidgets('login screen renders', (tester) async {
    await tester.pumpWidget(const DispatchConsoleApp());

    // Let the initial frame settle.
    await tester.pump();

    // The app always starts on the login screen: the console is only
    // reachable with a real JWT from the backend.
    expect(find.text('ERAS'), findsOneWidget);
    expect(find.text('Emergency Resource Allocation System'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);

    // Dispose the widget tree cleanly.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
  });

  testWidgets('login requires email and password', (tester) async {
    await tester.pumpWidget(const DispatchConsoleApp());
    await tester.pump();

    await tester.tap(find.text('Sign in'));
    await tester.pump();

    expect(find.text('Please enter email and password'), findsOneWidget);

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
  });
}
