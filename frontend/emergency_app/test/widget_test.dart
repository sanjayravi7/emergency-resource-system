import 'package:flutter_test/flutter_test.dart';
import 'package:dispatch_console_flutter/main.dart';

void main() {
  testWidgets('dispatch console renders', (tester) async {
    await tester.pumpWidget(const DispatchConsoleApp());

    expect(find.text('Dispatch Board'), findsOneWidget);
  });
}
