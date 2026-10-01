// TEMPORARY diagnostic test used to identify the widgets responsible for the
// RenderFlex overflows. Deleted once the real fixes land.
import 'package:dispatch_console_flutter/screens/dispatch_console_page.dart';
import 'package:dispatch_console_flutter/screens/register_screen.dart';
import 'package:dispatch_console_flutter/services/api_service.dart';
import 'package:dispatch_console_flutter/services/location_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const grantedPermission = LocationPermissionResult(
  status: LocationPermissionStatus.granted,
  message: 'Location permission granted.',
);

void _installReporter(String tag) {
  FlutterError.onError = (details) {
    final text = details.toString();
    if (text.contains('overflowed')) {
      debugPrint('>>>>> DIAG[$tag] BEGIN');
      debugPrint(text, wrapWidth: 200);
      debugPrint('>>>>> DIAG[$tag] END');
    }
  };
}

void main() {
  testWidgets('DIAG register 360x800', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    _installReporter('register');
    await tester.pumpWidget(const MaterialApp(home: RegisterScreen()));
    await tester.pump();
    FlutterError.onError = FlutterError.dumpErrorToConsole;

    tester.takeException();
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
  });

  testWidgets('DIAG console 800x600', (tester) async {
    ApiService.token = null;
    ApiService.currentRole = 'REQUESTER';
    ApiService.currentUserId = 17;
    ApiService.currentUserName = 'Location Test Requester';

    _installReporter('console');
    await tester.pumpWidget(
      MaterialApp(
        home: DispatchConsolePage(
          checkLocationPermission: () async => grantedPermission,
          requestLocationPermission: () async => grantedPermission,
        ),
      ),
    );
    await tester.pump();
    FlutterError.onError = FlutterError.dumpErrorToConsole;

    tester.takeException();
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();

    ApiService.currentRole = null;
    ApiService.currentUserId = null;
    ApiService.currentUserName = null;
  });
}
