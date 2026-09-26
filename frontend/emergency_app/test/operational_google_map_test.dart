import 'package:dispatch_console_flutter/Services/live_location_store.dart';
import 'package:dispatch_console_flutter/models/eras_models.dart';
import 'package:dispatch_console_flutter/widgets/operational_google_map.dart';
import 'package:flutter_test/flutter_test.dart';

EmergencyRequest _request(
  int id, {
  String status = 'IN_PROGRESS',
  double? latitude = 10.527642,
  double? longitude = 76.214435,
  int responderId = 9,
}) {
  return EmergencyRequest.fromJson(<String, dynamic>{
    'id': id,
    'emergencyType': 'Medical',
    'description': 'Map marker test',
    'location': 'Thrissur, Kerala',
    'priority': 'HIGH',
    'status': status,
    'createdAt': '2026-09-26T09:00:00.000Z',
    'updatedAt': '2026-09-26T10:00:00.000Z',
    'latitude': latitude,
    'longitude': longitude,
    'requiredResources': <dynamic>[],
    'allocations': <dynamic>[],
    if (status != 'PENDING')
      'acceptedBy': <String, dynamic>{
        'id': responderId,
        'name': 'Responder $responderId',
        'latitude': 10.520000,
        'longitude': 76.210000,
        'lastActiveAt': '2026-09-26T09:59:00.000Z',
      },
  });
}

LiveResponderLocation _live(
  int requestId, {
  int responderId = 9,
  double latitude = 10.530000,
  double longitude = 76.220000,
  bool isLive = true,
}) {
  return LiveResponderLocation(
    requestId: requestId,
    responderId: responderId,
    latitude: latitude,
    longitude: longitude,
    updatedAt: DateTime.utc(2026, 9, 26, 10),
    isLive: isLive,
  );
}

void main() {
  const builder = OperationalMapMarkerBuilder();

  test('creates a request marker only from real request coordinates', () {
    final snapshots = builder.buildSnapshots(
      requests: <EmergencyRequest>[
        _request(101),
        _request(102, latitude: null, longitude: null),
      ],
      liveLocations: const <int, LiveResponderLocation>{},
    );

    expect(snapshots.map((marker) => marker.id), contains('request-101'));
    expect(
      snapshots.map((marker) => marker.id),
      isNot(contains('request-102')),
    );

    final marker = snapshots.singleWhere((item) => item.id == 'request-101');
    expect(marker.kind, OperationalMapMarkerKind.activeRequest);
    expect(marker.position.latitude, 10.527642);
    expect(marker.position.longitude, 76.214435);
    expect(marker.title, 'DB-101 · EMERGENCY');
    expect(marker.snippet, contains('Thrissur, Kerala'));
    expect(marker.snippet, contains('10.527642, 76.214435'));
  });

  test('distinguishes pending request markers from active emergencies', () {
    final snapshots = builder.buildSnapshots(
      requests: <EmergencyRequest>[_request(111, status: 'PENDING')],
      liveLocations: const <int, LiveResponderLocation>{},
    );

    expect(snapshots.single.kind, OperationalMapMarkerKind.pendingRequest);
    expect(snapshots.single.title, 'DB-111 · PENDING REQUEST');
  });

  test('creates a LIVE responder marker from Socket.IO location state', () {
    final snapshots = builder.buildSnapshots(
      requests: <EmergencyRequest>[_request(201)],
      liveLocations: <int, LiveResponderLocation>{201: _live(201)},
    );

    final marker = snapshots.singleWhere(
      (item) => item.id == 'responder-201-9',
    );
    expect(marker.kind, OperationalMapMarkerKind.liveResponder);
    expect(marker.position.latitude, 10.530000);
    expect(marker.position.longitude, 76.220000);
    expect(marker.title, contains('LIVE responder'));
  });

  test('responder location update moves the same stable marker id', () {
    final first = builder.buildSnapshots(
      requests: <EmergencyRequest>[_request(301)],
      liveLocations: <int, LiveResponderLocation>{301: _live(301)},
    );
    final second = builder.buildSnapshots(
      requests: <EmergencyRequest>[_request(301)],
      liveLocations: <int, LiveResponderLocation>{
        301: _live(301, latitude: 10.540000, longitude: 76.230000),
      },
    );

    final firstMarker = first.singleWhere(
      (item) => item.id == 'responder-301-9',
    );
    final secondMarker = second.singleWhere(
      (item) => item.id == 'responder-301-9',
    );

    expect(secondMarker.id, firstMarker.id);
    expect(secondMarker.position.latitude, 10.540000);
    expect(secondMarker.position.longitude, 76.230000);
  });

  test(
    'live to last-known transition keeps the marker but changes its state',
    () {
      final snapshots = builder.buildSnapshots(
        requests: <EmergencyRequest>[_request(401)],
        liveLocations: <int, LiveResponderLocation>{
          401: _live(401).asNotLive(),
        },
      );

      final marker = snapshots.singleWhere(
        (item) => item.id == 'responder-401-9',
      );
      expect(marker.kind, OperationalMapMarkerKind.lastKnownResponder);
      expect(marker.title, contains('LAST KNOWN'));
    },
  );

  test('completed and cancelled requests remove active map tracking', () {
    final snapshots = builder.buildSnapshots(
      requests: <EmergencyRequest>[
        _request(501, status: 'COMPLETED'),
        _request(502, status: 'CANCELLED'),
      ],
      liveLocations: <int, LiveResponderLocation>{
        501: _live(501),
        502: _live(502),
      },
    );

    expect(snapshots, isEmpty);
  });

  test('multiple request locations stay isolated by request id', () {
    final store = LiveLocationStore();
    addTearDown(store.dispose);

    store.applyUpdate(_live(601, latitude: 10.527642, longitude: 76.214435));
    store.applyUpdate(_live(602, latitude: 9.931233, longitude: 76.267303));
    store.applyUpdate(_live(601, latitude: 10.528000, longitude: 76.215000));

    final snapshots = builder.buildSnapshots(
      requests: <EmergencyRequest>[
        _request(601, latitude: 10.527642, longitude: 76.214435),
        _request(602, latitude: 9.931233, longitude: 76.267303),
      ],
      liveLocations: store.locations,
    );

    final responderA = snapshots.singleWhere(
      (item) => item.id == 'responder-601-9',
    );
    final responderB = snapshots.singleWhere(
      (item) => item.id == 'responder-602-9',
    );

    expect(responderA.position.latitude, 10.528000);
    expect(responderA.position.longitude, 76.215000);
    expect(responderB.position.latitude, 9.931233);
    expect(responderB.position.longitude, 76.267303);
    expect(
      snapshots.map((item) => item.id).toSet(),
      hasLength(snapshots.length),
    );
  });
}
