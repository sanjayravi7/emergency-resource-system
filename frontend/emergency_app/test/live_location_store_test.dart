import 'package:flutter_test/flutter_test.dart';

import 'package:dispatch_console_flutter/models/eras_models.dart';
import 'package:dispatch_console_flutter/state/live_location_store.dart';

EmergencyRequest buildRequest({
  int id = 1,
  String status = 'ACCEPTED',
  Map<String, dynamic>? acceptedBy,
  List<Map<String, dynamic>> allocations = const <Map<String, dynamic>>[],
}) {
  return EmergencyRequest.fromJson(<String, dynamic>{
    'id': id,
    'emergencyType': 'Medical',
    'description': 'Test emergency',
    'location': 'Old Town',
    'priority': 'HIGH',
    'status': status,
    'createdAt': '2026-09-26T10:00:00.000Z',
    'requester': <String, dynamic>{'id': 900, 'name': 'Requester'},
    'acceptedBy': acceptedBy,
    'requiredResources': const <Map<String, dynamic>>[],
    'allocations': allocations,
  });
}

LiveResponderLocation liveAt(
  int requestId,
  double latitude,
  double longitude, {
  DateTime? at,
}) {
  return LiveResponderLocation(
    requestId: requestId,
    responderId: 42,
    latitude: latitude,
    longitude: longitude,
    updatedAt: at ?? DateTime.now(),
  );
}

void main() {
  group('LiveLocationStore', () {
    test('a location update replaces only its own request marker', () {
      final store = LiveLocationStore();

      store.applyLiveUpdate(liveAt(1, 10.5, 76.2));
      store.applyLiveUpdate(liveAt(2, 11.0, 76.9));
      store.applyLiveUpdate(liveAt(1, 10.6, 76.3));

      expect(store.length, 2);
      expect(store.locationFor(1)!.latitude, 10.6);
      expect(store.locationFor(2)!.latitude, 11.0);
      expect(store.hasLiveTracking(1), isTrue);
    });

    test('every accepted change bumps the revision used for repaints', () {
      final store = LiveLocationStore();
      final before = store.revision;

      store.applyLiveUpdate(liveAt(1, 10.5, 76.2));
      final afterUpdate = store.revision;
      expect(afterUpdate, greaterThan(before));

      // A stop for an unknown request changes nothing at all.
      store.markLastKnown(99);
      expect(store.revision, afterUpdate);
    });

    test('location.stop converts the live point into a last known point', () {
      final store = LiveLocationStore();
      store.applyLiveUpdate(liveAt(7, 10.5, 76.2));

      expect(store.markLastKnown(7), isTrue);

      final location = store.locationFor(7)!;
      expect(location.isLive, isFalse);
      expect(location.latitude, 10.5);
      expect(location.longitude, 76.2);
      expect(store.liveRequestIds, isEmpty);

      // Stopping twice is a no-op.
      expect(store.markLastKnown(7), isFalse);
    });

    test('a completed or cancelled request drops its tracking entirely', () {
      final store = LiveLocationStore();
      store.applyLiveUpdate(liveAt(3, 10.5, 76.2));

      expect(store.removeForRequest(3), isTrue);
      expect(store.locationFor(3), isNull);
      expect(store.isEmpty, isTrue);
    });

    test('REST reconciliation prunes closed requests and seeds last known',
        () {
      final store = LiveLocationStore();
      store.applyLiveUpdate(liveAt(1, 10.5, 76.2));
      store.applyLiveUpdate(liveAt(2, 11.0, 76.9));

      final open = <EmergencyRequest>[
        buildRequest(
          id: 2,
          acceptedBy: <String, dynamic>{
            'id': 42,
            'name': 'Responder',
            'latitude': 12.0,
            'longitude': 77.0,
          },
        ),
        buildRequest(
          id: 5,
          acceptedBy: <String, dynamic>{
            'id': 43,
            'name': 'Other responder',
            'latitude': 9.5,
            'longitude': 75.5,
          },
        ),
      ];

      store.syncWithOpenRequests(open);

      // Request 1 is no longer open: its marker is gone.
      expect(store.locationFor(1), isNull);
      // Request 2 is still tracked live, so the throttled REST coordinate does
      // not overwrite the live one.
      expect(store.locationFor(2)!.isLive, isTrue);
      expect(store.locationFor(2)!.latitude, 11.0);
      // Request 5 gains a last known marker from the persisted coordinate.
      expect(store.locationFor(5)!.isLive, isFalse);
      expect(store.locationFor(5)!.latitude, 9.5);
    });

    test('a closed request is never seeded with a marker', () {
      final store = LiveLocationStore();

      store.syncWithOpenRequests(<EmergencyRequest>[
        buildRequest(
          id: 8,
          status: 'COMPLETED',
          acceptedBy: <String, dynamic>{
            'id': 42,
            'name': 'Responder',
            'latitude': 10.0,
            'longitude': 76.0,
          },
        ),
      ]);

      expect(store.isEmpty, isTrue);
    });

    test('live points that stop arriving expire into last known points', () {
      final store = LiveLocationStore(staleAfter: const Duration(seconds: 30));
      final start = DateTime(2026, 9, 26, 10);

      store.applyLiveUpdate(liveAt(4, 10.5, 76.2, at: start));

      expect(store.expireStale(start.add(const Duration(seconds: 10))), isFalse);
      expect(store.locationFor(4)!.isLive, isTrue);

      expect(store.expireStale(start.add(const Duration(seconds: 31))), isTrue);
      expect(store.locationFor(4)!.isLive, isFalse);
    });

    test('losing the realtime transport downgrades every live point', () {
      final store = LiveLocationStore();
      store.applyLiveUpdate(liveAt(1, 10.5, 76.2));
      store.applyLiveUpdate(liveAt(2, 11.5, 76.4));

      expect(store.markAllLastKnown(), isTrue);
      expect(store.liveRequestIds, isEmpty);
      expect(store.length, 2, reason: 'last known points stay on the map');
      expect(store.markAllLastKnown(), isFalse);
    });

    test('logout clears everything', () {
      final store = LiveLocationStore();
      store.applyLiveUpdate(liveAt(1, 10.5, 76.2));

      store.clear();

      expect(store.isEmpty, isTrue);
    });
  });
}
