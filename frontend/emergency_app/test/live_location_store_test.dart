import 'package:dispatch_console_flutter/Services/live_location_store.dart';
import 'package:dispatch_console_flutter/models/eras_models.dart';
import 'package:flutter_test/flutter_test.dart';

LiveResponderLocation _location(
  int requestId, {
  int responderId = 9,
  double latitude = 10.5,
  double longitude = 76.2,
}) {
  return LiveResponderLocation(
    requestId: requestId,
    responderId: responderId,
    latitude: latitude,
    longitude: longitude,
    updatedAt: DateTime.utc(2026, 9, 26, 10),
  );
}

EmergencyRequest _request(
  int id,
  String status, {
  List<Map<String, dynamic>> assignments = const [],
  Map<String, dynamic>? acceptedBy,
  List<Map<String, dynamic>> allocations = const [],
}) {
  return EmergencyRequest.fromJson(<String, dynamic>{
    'id': id,
    'emergencyType': 'Medical',
    'description': 'Test request',
    'location': 'Thrissur, Kerala',
    'priority': 'HIGH',
    'status': status,
    'createdAt': '2026-09-26T09:00:00.000Z',
    'updatedAt': '2026-09-26T10:00:00.000Z',
    'requiredResources': <dynamic>[],
    'allocations': allocations,
    'assignments': assignments,
    'acceptedBy': acceptedBy ??
        <String, dynamic>{
          'id': 9,
          'name': 'Responder',
          'latitude': 10.4,
          'longitude': 76.1,
          'lastActiveAt': '2026-09-26T09:59:00.000Z',
        },
  });
}

Map<String, dynamic> _assignment(
  int responderId, {
  String status = 'ACTIVE',
  double? latitude,
  double? longitude,
}) {
  return <String, dynamic>{
    'id': responderId,
    'requestId': 0,
    'responderId': responderId,
    'status': status,
    'acceptedAt': '2026-09-26T09:30:00.000Z',
    if (latitude != null)
      'responder': <String, dynamic>{
        'id': responderId,
        'name': 'Responder $responderId',
        'latitude': latitude,
        'longitude': longitude,
        'lastActiveAt': '2026-09-26T09:58:00.000Z',
      },
  };
}

void main() {
  group('LiveLocationStore (multi-responder, Phase F)', () {
    test('updates only the matching request and preserves other markers', () {
      final store = LiveLocationStore();
      addTearDown(store.dispose);

      store.applyUpdate(_location(11));
      store.applyUpdate(_location(12, latitude: 11.5));
      store.applyUpdate(_location(11, latitude: 10.75));

      expect(store.locationsForRequest(11).keys, hasLength(1));
      expect(store.locationFor(11, 9)!.latitude, 10.75);
      expect(store.locationFor(12, 9)!.latitude, 11.5);
      expect(store.locationFor(11, 9)!.isLive, isTrue);
    });

    // Phase F case 8: responder A and B can coexist on one request. -------
    test('responders A and B coexist on the same request', () {
      final store = LiveLocationStore();
      addTearDown(store.dispose);

      store.applyUpdate(_location(21, responderId: 1, latitude: 10.1));
      store.applyUpdate(_location(21, responderId: 2, latitude: 10.2));

      final points = store.locationsForRequest(21);
      expect(points.keys, <int>{1, 2});
      expect(points[1]!.latitude, 10.1);
      expect(points[2]!.latitude, 10.2);
    });

    // Phase F case 9: updating A does not change B. -----------------------
    test('updating responder A leaves responder B untouched', () {
      final store = LiveLocationStore();
      addTearDown(store.dispose);

      store.applyUpdate(_location(21, responderId: 1, latitude: 10.1));
      store.applyUpdate(_location(21, responderId: 2, latitude: 10.2));
      store.applyUpdate(_location(21, responderId: 1, latitude: 10.9));

      final points = store.locationsForRequest(21);
      expect(points[1]!.latitude, 10.9);
      expect(points[2]!.latitude, 10.2);
    });

    // Phase F case 10: removing A keeps B. --------------------------------
    test('one responder stopping keeps the other responder live', () {
      final store = LiveLocationStore();
      addTearDown(store.dispose);

      store.beginRemoteSharing(requestId: 21, responderId: 1);
      store.beginRemoteSharing(requestId: 21, responderId: 2);
      store.applyUpdate(_location(21, responderId: 1, latitude: 10.1));
      store.applyUpdate(_location(21, responderId: 2, latitude: 10.2));

      // responder.location.stop for responder 1 only.
      store.stopSharing(21, responderId: 1);

      expect(store.locationFor(21, 1)!.isLive, isFalse);
      expect(store.locationFor(21, 1)!.latitude, 10.1);
      expect(store.locationFor(21, 2)!.isLive, isTrue,
          reason: 'another responder stopping must not end this stream');
      expect(store.isResponderActivelySharing(21, 1), isFalse);
      expect(store.isResponderActivelySharing(21, 2), isTrue);
    });

    test('remove() fully drops only one responder point', () {
      final store = LiveLocationStore();
      addTearDown(store.dispose);

      store.applyUpdate(_location(22, responderId: 1));
      store.applyUpdate(_location(22, responderId: 2));

      store.remove(22, 1);

      expect(store.locationFor(22, 1), isNull);
      expect(store.locationFor(22, 2), isNotNull);
    });

    test('location stop retains the coordinate as last-known', () {
      final store = LiveLocationStore();
      addTearDown(store.dispose);

      store.applyUpdate(_location(31, responderId: 9));
      store.stopSharing(31, responderId: 9);

      expect(store.isActivelySharing(31), isFalse);
      expect(store.locationFor(31, 9), isNotNull);
      expect(store.locationFor(31, 9)!.isLive, isFalse);
      expect(store.locationFor(31, 9)!.updatedAt,
          DateTime.utc(2026, 9, 26, 10));
    });

    test('local sharing is tracked per responder identity', () {
      final store = LiveLocationStore();
      addTearDown(store.dispose);

      store.beginLocalSharing(41, responderId: 7);
      store.applyUpdate(_location(41, responderId: 7));

      expect(store.localSharingRequestId, 41);
      expect(store.localSharingResponderId, 7);

      // A remote stop for a DIFFERENT responder must not end local sharing.
      store.stopSharing(41, responderId: 8);
      expect(store.localSharingRequestId, 41);

      store.endLocalSharing();
      expect(store.localSharingRequestId, isNull);
      expect(store.locationFor(41, 7)!.isLive, isFalse);
    });

    test('disconnect stops local sharing and marks every point stale', () {
      final store = LiveLocationStore();
      addTearDown(store.dispose);

      store.beginLocalSharing(51, responderId: 9);
      store.applyUpdate(_location(51, responderId: 9));
      store.applyUpdate(_location(52, responderId: 9));
      store.markConnectionLost();

      expect(store.localSharingRequestId, isNull);
      expect(store.activelySharingRequestIds, isEmpty);
      expect(
        store.locationsByRequest.values
            .expand((points) => points.values)
            .every((point) => !point.isLive),
        isTrue,
      );
    });

    test('completed and cancelled reconciliation removes tracking state', () {
      final store = LiveLocationStore();
      addTearDown(store.dispose);

      store.beginLocalSharing(61, responderId: 9);
      store.applyUpdate(_location(61, responderId: 9));
      store.applyUpdate(_location(62, responderId: 9));

      store.reconcile(<EmergencyRequest>[
        _request(61, 'COMPLETED'),
        _request(62, 'CANCELLED'),
      ]);

      expect(store.locationsByRequest, isEmpty);
      expect(store.activelySharingRequestIds, isEmpty);
      expect(store.localSharingRequestId, isNull);
    });

    test('REST reconciliation never overwrites an active live coordinate', () {
      final store = LiveLocationStore();
      addTearDown(store.dispose);
      store.applyUpdate(_location(71, responderId: 9, latitude: 12.345));

      store.reconcile(<EmergencyRequest>[_request(71, 'IN_PROGRESS')]);

      expect(store.locationFor(71, 9)!.latitude, 12.345);
      expect(store.locationFor(71, 9)!.isLive, isTrue);
    });

    // Phase F case 12: reconcile handles multiple responders. -------------
    test('reconcile merges persisted points for multiple assigned responders',
        () {
      final store = LiveLocationStore();
      addTearDown(store.dispose);

      store.applyUpdate(_location(
        81,
        responderId: 2,
        latitude: 10.9,
        longitude: 76.9,
      ));

      store.reconcile(<EmergencyRequest>[
        _request(
          81,
          'IN_PROGRESS',
          assignments: <Map<String, dynamic>>[
            _assignment(1, latitude: 10.1, longitude: 76.1),
            _assignment(2, latitude: 10.2, longitude: 76.2),
            _assignment(3, status: 'ENDED', latitude: 10.3, longitude: 76.3),
          ],
        ),
      ]);

      final points = store.locationsForRequest(81);
      // Assignment 1 has no live point: persisted last-known point merged.
      expect(points[1]!.latitude, 10.1);
      expect(points[1]!.isLive, isFalse);
      // Assignment 2 is live from the socket: the persisted point loses.
      expect(points[2]!.latitude, 10.9);
      expect(points[2]!.isLive, isTrue);
      // ENDED assignment: the responder no longer participates, so even a
      // persisted coordinate must not be tracked.
      expect(points.containsKey(3), isFalse);
    });

    test('reconcile drops points of responders who left the request', () {
      final store = LiveLocationStore();
      addTearDown(store.dispose);

      store.applyUpdate(_location(91, responderId: 4));
      store.applyUpdate(_location(91, responderId: 5));

      store.reconcile(<EmergencyRequest>[
        _request(
          91,
          'IN_PROGRESS',
          assignments: <Map<String, dynamic>>[_assignment(5)],
        ),
      ]);

      final points = store.locationsForRequest(91);
      expect(points.containsKey(4), isFalse,
          reason: 'no ACTIVE assignment, no allocation, not the lead');
      expect(points.containsKey(5), isTrue);
    });

    // Phase F case 11: clearRequest removes all responders. ---------------
    test('clearRequest removes every responder location of the request', () {
      final store = LiveLocationStore();
      addTearDown(store.dispose);

      store.applyUpdate(_location(95, responderId: 1));
      store.applyUpdate(_location(95, responderId: 2));
      store.applyUpdate(_location(96, responderId: 1));

      store.clearRequest(95);

      expect(store.locationsForRequest(95), isEmpty);
      expect(store.locationFor(96, 1), isNotNull,
          reason: 'other requests keep their points');
    });
  });
}
