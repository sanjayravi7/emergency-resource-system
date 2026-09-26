import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dispatch_console_flutter/Services/api_service.dart';
import 'package:dispatch_console_flutter/Services/socket_service.dart';
import 'package:dispatch_console_flutter/models/eras_models.dart';
import 'package:dispatch_console_flutter/widgets/connection_status.dart';
import 'package:dispatch_console_flutter/widgets/responder_status_panel.dart';

Widget wrap(Widget child) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  group('Connection state', () {
    test('labels are the three user facing states only', () {
      expect(
        const SocketConnectionState(status: RealtimeStatus.connected).label,
        'CONNECTED',
      );
      expect(
        const SocketConnectionState(status: RealtimeStatus.reconnecting).label,
        'RECONNECTING',
      );
      expect(SocketConnectionState.offline.label, 'OFFLINE');
    });

    test('only CONNECTED is a non degraded state', () {
      expect(
        const SocketConnectionState(status: RealtimeStatus.connected)
            .isDegraded,
        isFalse,
      );
      expect(
        const SocketConnectionState(status: RealtimeStatus.reconnecting)
            .isDegraded,
        isTrue,
      );
      expect(SocketConnectionState.offline.isDegraded, isTrue);
    });

    test('a signed out app never opens a socket and stays OFFLINE', () {
      ApiService.token = null;

      // Calling connect repeatedly without a session must be a safe no-op:
      // no socket, no duplicated listeners, no state change.
      SocketService.instance.connect();
      SocketService.instance.connect();

      expect(SocketService.instance.isConnected, isFalse);
      expect(SocketService.instance.status, RealtimeStatus.offline);
    });

    test('event and connection streams support several listeners', () async {
      final events = <RealtimeEvent>[];
      final first = SocketService.instance.events.listen(events.add);
      final second = SocketService.instance.events.listen(events.add);

      // Broadcast streams: a rebuilt page can subscribe again without the
      // "Stream has already been listened to" failure.
      expect(SocketService.instance.events.isBroadcast, isTrue);
      expect(SocketService.instance.connectionStates.isBroadcast, isTrue);

      await first.cancel();
      await second.cancel();
    });
  });

  group('Connection indicator widgets', () {
    testWidgets('pill renders the three states', (tester) async {
      for (final entry in <RealtimeStatus, String>{
        RealtimeStatus.connected: 'CONNECTED',
        RealtimeStatus.reconnecting: 'RECONNECTING',
        RealtimeStatus.offline: 'OFFLINE',
      }.entries) {
        await tester.pumpWidget(
          wrap(
            ConnectionStatusPill(
              state: SocketConnectionState(status: entry.key),
            ),
          ),
        );
        await tester.pump();

        expect(find.text(entry.value), findsOneWidget);
      }
    });

    testWidgets('the notice only appears while realtime is degraded',
        (tester) async {
      await tester.pumpWidget(
        wrap(
          const ConnectionNotice(
            state: SocketConnectionState(status: RealtimeStatus.connected),
          ),
        ),
      );
      await tester.pump();
      expect(find.textContaining('refreshes from the database'), findsNothing);

      await tester.pumpWidget(
        wrap(
          const ConnectionNotice(
            state: SocketConnectionState(status: RealtimeStatus.reconnecting),
          ),
        ),
      );
      await tester.pump();
      expect(
        find.textContaining('Reconnecting to live updates'),
        findsOneWidget,
      );

      await tester.pumpWidget(
        wrap(const ConnectionNotice(state: SocketConnectionState.offline)),
      );
      await tester.pump();
      expect(
        find.textContaining('Live updates are offline'),
        findsOneWidget,
      );
    });
  });

  group('Responder availability (backend state only)', () {
    test('parses the workload payload from the backend', () {
      final availability = ResponderAvailability.fromJson(<String, dynamic>{
        'responderId': 42,
        'responderStatus': 'BUSY',
        'reservedAllocations': 1,
        'dispatchedAllocations': 1,
        'unfinishedAllocations': 2,
        'activeRequests': 1,
      });

      expect(availability.isBusy, isTrue);
      expect(availability.hasUnfinishedWork, isTrue);
      expect(availability.workloadLabel, '2 unfinished allocations');
    });

    test('an idle responder reports no unfinished work', () {
      final availability = ResponderAvailability.fromJson(<String, dynamic>{
        'responderId': 42,
        'responderStatus': 'AVAILABLE',
        'reservedAllocations': 0,
        'dispatchedAllocations': 0,
        'unfinishedAllocations': 0,
        'activeRequests': 0,
      });

      expect(availability.isAvailable, isTrue);
      expect(availability.workloadLabel, 'No unfinished work');
    });

    test('a status only broadcast is not treated as workload detail', () {
      final statusOnly = <String, dynamic>{
        'responderId': 7,
        'responderStatus': 'BUSY',
        'currentResponderStatus': 'BUSY',
        'timestamp': '2026-09-26T10:00:00.000Z',
      };

      expect(ResponderAvailability.hasWorkloadDetail(statusOnly), isFalse);
      expect(
        ResponderAvailability.hasWorkloadDetail(<String, dynamic>{
          ...statusOnly,
          'unfinishedAllocations': 2,
        }),
        isTrue,
      );
    });

    test('a status only update keeps the known counts', () {
      const availability = ResponderAvailability(
        responderId: 42,
        responderStatus: 'BUSY',
        reservedAllocations: 1,
        dispatchedAllocations: 1,
        unfinishedAllocations: 2,
        activeRequests: 1,
      );

      final updated = availability.copyWithStatus('AVAILABLE');

      expect(updated.responderStatus, 'AVAILABLE');
      expect(updated.unfinishedAllocations, 2);
    });

    testWidgets('the availability card shows the backend status and reason',
        (tester) async {
      await tester.pumpWidget(
        wrap(
          const ResponderAvailabilityCard(
            availability: ResponderAvailability(
              responderId: 42,
              responderStatus: 'BUSY',
              reservedAllocations: 1,
              dispatchedAllocations: 1,
              unfinishedAllocations: 2,
              activeRequests: 1,
            ),
            connection:
                SocketConnectionState(status: RealtimeStatus.connected),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('BUSY'), findsOneWidget);
      expect(find.text('2 unfinished allocations'), findsOneWidget);
      expect(find.text('CONNECTED'), findsOneWidget);
    });
  });
}
