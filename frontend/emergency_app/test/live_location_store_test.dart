import 'package:dispatch_console_flutter/Services/live_location_store.dart';
import 'package:dispatch_console_flutter/models/eras_models.dart';
import 'package:flutter_test/flutter_test.dart';

LiveResponderLocation _location(
  int requestId, {
  double latitude = 10.5,
  double longitude = 76.2,
}) {
  return LiveResponderLocation(
    requestId: requestId,
    responderId: 9,
    latitude: latitude,
    longitude: longitude,
    updatedAt: DateTime.utc(2026, 9, 26, 10),
  );
}

EmergencyRequest _request(int id, String status) {
  return EmergencyRequest.fromJson(<String, dynamic>{
    'id': id,
    'emergencyType': 'Medical',
    'description': 'Test request',
    'location': 'Old Town',
    'priority': 'HIGH',
    'status': status,
    'createdAt': '2026-09-26T09:00:00.000Z',
    'updatedAt': '2026-09-26T10:00:00.000Z',
    'requiredResources': <dynamic>[],
    'allocations': <dynamic>[],
    'acceptedBy': <String, dynamic>{
      'id': 9,
      'name': 'Responder',
      'latitude': 10.4,
      'longitude': 76.1,
      'lastActiveAt': '2026-09-26T09:59:00.000Z',
    },
  });
}

void main() {
  group('LiveLocationStore', () {
    test('updates only the matching request and preserves other markers', () {
      final store = LiveLocationStore();
      addTearDown(store.dispose);

      store.applyUpdate(_location(11));
      store.applyUpdate(_location(12, latitude: 11.5));
      store.applyUpdate(_location(11, latitude: 10.75));

      expect(store.locations, hasLength(2));
      expect(store.locationFor(11)!.latitude, 10.75);
      expect(store.locationFor(12)!.latitude, 11.5);
      expect(store.locationFor(11)!.isLive, isTrue);
    });

    test('location stop retains the coordinate as last-known', () {
      final store = LiveLocationStore();
      addTearDown(store.dispose);

      store.applyUpdate(_location(21));
      store.stopSharing(21);

      expect(store.isActivelySharing(21), isFalse);
      expect(store.locationFor(21), isNotNull);
      expect(store.locationFor(21)!.isLive, isFalse);
      expect(store.locationFor(21)!.updatedAt,
          DateTime.utc(2026, 9, 26, 10));
    });

    test('disconnect stops local sharing and marks every point stale', () {
      final store = LiveLocationStore();
      addTearDown(store.dispose);

      store.beginLocalSharing(31);
      store.applyUpdate(_location(31));
      store.applyUpdate(_location(32));
      store.markConnectionLost();

      expect(store.localSharingRequestId, isNull);
      expect(store.activelySharingRequestIds, isEmpty);
      expect(store.locations.values.every((point) => !point.isLive), isTrue);
    });

    test('completed and cancelled reconciliation removes tracking state', () {
      final store = LiveLocationStore();
      addTearDown(store.dispose);

      store.beginLocalSharing(41);
      store.applyUpdate(_location(41));
      store.applyUpdate(_location(42));

      store.reconcile(<EmergencyRequest>[
        _request(41, 'COMPLETED'),
        _request(42, 'CANCELLED'),
      ]);

      expect(store.locations, isEmpty);
      expect(store.activelySharingRequestIds, isEmpty);
      expect(store.localSharingRequestId, isNull);
    });

    test('REST reconciliation never overwrites an active live coordinate', () {
      final store = LiveLocationStore();
      addTearDown(store.dispose);
      store.applyUpdate(_location(51, latitude: 12.345));

      store.reconcile(<EmergencyRequest>[_request(51, 'IN_PROGRESS')]);

      expect(store.locationFor(51)!.latitude, 12.345);
      expect(store.locationFor(51)!.isLive, isTrue);
    });
  });
}
