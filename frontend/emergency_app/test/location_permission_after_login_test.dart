import 'package:dispatch_console_flutter/screens/dispatch_console_page.dart';
import 'package:dispatch_console_flutter/services/api_service.dart';
import 'package:dispatch_console_flutter/services/location_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const grantedPermission = LocationPermissionResult(
  status: LocationPermissionStatus.granted,
  message: 'Location permission granted.',
);

const deniedPermission = LocationPermissionResult(
  status: LocationPermissionStatus.denied,
  message: 'Location permission was not granted.',
);

void main() {
  setUp(() {
    // A null token keeps SocketService disconnected. HTTP load failures are
    // non-fatal by design and do not affect permission-state rendering.
    ApiService.token = null;
    ApiService.currentRole = 'REQUESTER';
    ApiService.currentUserId = 17;
    ApiService.currentUserName = 'Location Test Requester';
  });

  tearDown(() {
    ApiService.token = null;
    ApiService.currentRole = null;
    ApiService.currentUserId = null;
    ApiService.currentUserName = null;
  });

  Future<void> disposePage(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pump();
  }

  testWidgets('granted permission enables state without showing the banner',
      (tester) async {
    var requestCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: DispatchConsolePage(
          checkLocationPermission: () async => grantedPermission,
          requestLocationPermission: () async {
            requestCalls++;
            return grantedPermission;
          },
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const Key('location-permission-disabled-banner')),
      findsNothing,
    );
    expect(requestCalls, 0);
    await disposePage(tester);
  });

  testWidgets('denied permission does not block the dashboard and shows banner',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DispatchConsolePage(
          checkLocationPermission: () async => deniedPermission,
          requestLocationPermission: () async => deniedPermission,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Dispatch Board'), findsOneWidget);
    expect(find.text('Location access is disabled.'), findsOneWidget);
    expect(find.byKey(const Key('enable-location-button')), findsOneWidget);
    await disposePage(tester);
  });

  testWidgets('ENABLE LOCATION retries and removes banner after a grant',
      (tester) async {
    var requestCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: DispatchConsolePage(
          checkLocationPermission: () async => deniedPermission,
          requestLocationPermission: () async {
            requestCalls++;
            return requestCalls == 1 ? deniedPermission : grantedPermission;
          },
        ),
      ),
    );
    await tester.pump();

    expect(requestCalls, 1); // automatic post-login request
    await tester.tap(find.byKey(const Key('enable-location-button')));
    await tester.pump();

    expect(requestCalls, 2);
    expect(
      find.byKey(const Key('location-permission-disabled-banner')),
      findsNothing,
    );
    await disposePage(tester);
  });
}
