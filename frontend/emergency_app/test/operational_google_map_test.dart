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
  List<Map<String, dynamic>> assignments = const [],
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
    'assignments': assignments,
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
      liveLocations: const <int, Map<int, LiveResponderLocation>>{},
    );

    expect(snapshots.map((marker) => marker.id), contains('request-101'));
    expect(snapshots.map((marker) => marker.id), isNot(contains('request-102')));

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
      requests: <EmergencyRequest>[
        _request(111, status: 'PENDING'),
      ],
      liveLocations: const <int, Map<int, LiveResponderLocation>>{},
    );

    expect(snapshots.single.kind, OperationalMapMarkerKind.pendingRequest);
    expect(snapshots.single.title, 'DB-111 · PENDING REQUEST');
  });

  test('creates a LIVE responder marker from Socket.IO location state', () {
    final snapshots = builder.buildSnapshots(
      requests: <EmergencyRequest>[_request(201)],
      liveLocations: <int, Map<int, LiveResponderLocation>>{201: <int, LiveResponderLocation>{9: _live(201)}},
    );

    final marker = snapshots.singleWhere((item) => item.id == 'responder-201-9');
    expect(marker.kind, OperationalMapMarkerKind.liveResponder);
    expect(marker.position.latitude, 10.530000);
    expect(marker.position.longitude, 76.220000);
    expect(marker.title, contains('LIVE responder'));
  });

  test('responder location update moves the same stable marker id', () {
    final first = builder.buildSnapshots(
      requests: <EmergencyRequest>[_request(301)],
      liveLocations: <int, Map<int, LiveResponderLocation>>{301: <int, LiveResponderLocation>{9: _live(301)}},
    );
    final second = builder.buildSnapshots(
      requests: <EmergencyRequest>[_request(301)],
      liveLocations: <int, Map<int, LiveResponderLocation>>{
        301: <int, LiveResponderLocation>{
          9: _live(301, latitude: 10.540000, longitude: 76.230000),
        },
      },
    );

    final firstMarker = first.singleWhere((item) => item.id == 'responder-301-9');
    final secondMarker = second.singleWhere((item) => item.id == 'responder-301-9');

    expect(secondMarker.id, firstMarker.id);
    expect(secondMarker.position.latitude, 10.540000);
    expect(secondMarker.position.longitude, 76.230000);
  });

  test('live to last-known transition keeps the marker but changes its state', () {
    final snapshots = builder.buildSnapshots(
      requests: <EmergencyRequest>[_request(401)],
      liveLocations: <int, Map<int, LiveResponderLocation>>{
        401: <int, LiveResponderLocation>{
          9: _live(401).asNotLive(),
        },
      },
    );

    final marker = snapshots.singleWhere((item) => item.id == 'responder-401-9');
    expect(marker.kind, OperationalMapMarkerKind.lastKnownResponder);
    expect(marker.title, contains('LAST KNOWN'));
  });

  test('completed and cancelled requests remove active map tracking', () {
    final snapshots = builder.buildSnapshots(
      requests: <EmergencyRequest>[
        _request(501, status: 'COMPLETED'),
        _request(502, status: 'CANCELLED'),
      ],
      liveLocations: <int, Map<int, LiveResponderLocation>>{
        501: <int, LiveResponderLocation>{9: _live(501)},
        502: <int, LiveResponderLocation>{9: _live(502)},
      },
    );

    expect(snapshots, isEmpty);
  });

  // PHASE F: multi-responder map rendering.
  test('two responders on one request render isolated marker pairs', () {
    final snapshots = builder.buildSnapshots(
      requests: <EmergencyRequest>[
        _request(701, assignments: [
          <String, dynamic>{
            'id': 1,
            'requestId': 701,
            'responderId': 9,
            'status': 'ACTIVE',
            'acceptedAt': '2026-09-26T09:05:00.000Z',
            'responder': <String, dynamic>{
              'id': 9,
              'name': 'Asha Menon',
            },
          },
          <String, dynamic>{
            'id': 2,
            'requestId': 701,
            'responderId': 11,
            'status': 'ACTIVE',
            'acceptedAt': '2026-09-26T09:20:00.000Z',
            'responder': <String, dynamic>{
              'id': 11,
              'name': 'Rahul Pillai',
            },
          },
        ]),
      ],
      liveLocations: <int, Map<int, LiveResponderLocation>>{
        701: <int, LiveResponderLocation>{
          9: _live(701, responderId: 9, latitude: 10.531, longitude: 76.221),
          11: _live(701, responderId: 11, latitude: 10.532, longitude: 76.222),
        },
      },
    );

    // One emergency marker + one marker per responder, all ids unique.
    expect(snapshots.map((item) => item.id).toSet(), hasLength(3));
    expect(snapshots.map((item) => item.id), contains('request-701'));

    final responderA =
        snapshots.singleWhere((item) => item.id == 'responder-701-9');
    final responderB =
        snapshots.singleWhere((item) => item.id == 'responder-701-11');

    expect(responderA.title, 'LIVE responder · Asha Menon');
    expect(responderB.title, 'LIVE responder · Rahul Pillai');
    expect(responderA.position.latitude, 10.531);
    expect(responderB.position.latitude, 10.532);

    // Moving responder A must not disturb responder B's marker identity.
    final moved = builder.buildSnapshots(
      requests: <EmergencyRequest>[_request(701, assignments: const [])],
      liveLocations: <int, Map<int, LiveResponderLocation>>{
        701: <int, LiveResponderLocation>{
          9: _live(701, responderId: 9, latitude: 10.599, longitude: 76.299),
          11: _live(701, responderId: 11, latitude: 10.532, longitude: 76.222),
        },
      },
    );
    final movedA = moved.singleWhere((item) => item.id == 'responder-701-9');
    final movedB = moved.singleWhere((item) => item.id == 'responder-701-11');
    expect(movedA.position.latitude, 10.599);
    expect(movedB.position.latitude, 10.532);
  });

  test('responder names fall back assignment -> lead -> stable id label', () {
    // 9 is the legacy lead (no assignment row), 42 is nobody known.
    final snapshots = builder.buildSnapshots(
      requests: <EmergencyRequest>[
        _request(801, assignments: const []),
      ],
      liveLocations: <int, Map<int, LiveResponderLocation>>{
        801: <int, LiveResponderLocation>{
          9: _live(801, responderId: 9),
          42: _live(801, responderId: 42),
        },
      },
    );

    final lead =
        snapshots.singleWhere((item) => item.id == 'responder-801-9');
    expect(lead.title, contains('Responder 9'),
        reason: 'legacy acceptedBy name is used for the lead');

    final unknown =
        snapshots.singleWhere((item) => item.id == 'responder-801-42');
    expect(unknown.title, contains('Responder #42'),
        reason: 'unknown responders get a stable non-guessing label');
  });

  test('responder snippets list only that responder\'s allocated resources',
      () {
    final request = EmergencyRequest.fromJson(<String, dynamic>{
      'id': 901,
      'emergencyType': 'Medical',
      'location': 'Thrissur, Kerala',
      'priority': 'HIGH',
      'status': 'IN_PROGRESS',
      'createdAt': '2026-09-26T09:00:00.000Z',
      'requiredResources': <dynamic>[],
      'allocations': <dynamic>[
        <String, dynamic>{
          'id': 9001,
          'requestId': 901,
          'resourceId': 4,
          'responderId': 9,
          'responderResourceId': 7,
          'quantity': 2,
          'status': 'RESERVED',
          'resource': <String, dynamic>{'id': 4, 'name': 'Blood'},
        },
        <String, dynamic>{
          'id': 9002,
          'requestId': 901,
          'resourceId': 5,
          'responderId': 11,
          'responderResourceId': 8,
          'quantity': 1,
          'status': 'RESERVED',
          'resource': <String, dynamic>{'id': 5, 'name': 'Stretcher'},
        },
      ],
      'acceptedBy': <String, dynamic>{
        'id': 9,
        'name': 'Responder 9',
      },
    });

    final snapshots = builder.buildSnapshots(
      requests: <EmergencyRequest>[request],
      liveLocations: <int, Map<int, LiveResponderLocation>>{
        901: <int, LiveResponderLocation>{
          9: _live(901, responderId: 9),
          11: _live(901, responderId: 11),
        },
      },
    );

    final responderA =
        snapshots.singleWhere((item) => item.id == 'responder-901-9');
    final responderB =
        snapshots.singleWhere((item) => item.id == 'responder-901-11');
    expect(responderA.snippet, contains('Blood'));
    expect(responderA.snippet, isNot(contains('Stretcher')));
    expect(responderB.snippet, contains('Stretcher'));
    expect(responderB.snippet, isNot(contains('Blood')));
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
      liveLocations: store.locationsByRequest,
    );

    final responderA =
        snapshots.singleWhere((item) => item.id == 'responder-601-9');
    final responderB =
        snapshots.singleWhere((item) => item.id == 'responder-602-9');

    expect(responderA.position.latitude, 10.528000);
    expect(responderA.position.longitude, 76.215000);
    expect(responderB.position.latitude, 9.931233);
    expect(responderB.position.longitude, 76.267303);
    expect(snapshots.map((item) => item.id).toSet(), hasLength(snapshots.length));
  });
}
