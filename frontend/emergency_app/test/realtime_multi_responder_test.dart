import 'package:dispatch_console_flutter/Services/live_location_store.dart';
import 'package:dispatch_console_flutter/models/eras_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// PHASE F realtime event handling tests.
///
/// The DispatchConsolePage applies Socket.IO payloads through exactly these
/// public building blocks (EmergencyRequest.fromJson / withAssignment /
/// withAllocation, participatesAsResponder, LiveLocationStore). This suite
/// drives those building blocks with real Phase E payload shapes, so the
/// event pipeline - not just the parsers - is covered.
void main() {
  group('realtime multi-responder events (Phase F)', () {
    // Phase F case 13 ------------------------------------------------------
    test('responder.assigned adds the assignment and updates the board', () {
      final board = _ResponderBoard()..seed(_requestSnapshot(assignments: [
            _assignmentJson(9),
          ]));

      board.handle('responder.assigned', <String, dynamic>{
        'requestId': 42,
        'responderId': 11,
        'assignment': _assignmentJson(11),
        'assignments': <dynamic>[_assignmentJson(9), _assignmentJson(11)],
        'request': _requestSnapshot(assignments: [
          _assignmentJson(9),
          _assignmentJson(11),
        ]),
      });

      final request = board.open.single;
      expect(request.assignments, hasLength(2));
      expect(request.isAssignedTo(11), isTrue);
      expect(request.acceptedBy?.id, 9,
          reason: 'the lead responder semantics are preserved');
    });

    // Phase F case 14 ------------------------------------------------------
    test('a duplicate responder.assigned never duplicates the assignment',
        () {
      final board = _ResponderBoard()..seed(_requestSnapshot(assignments: [
            _assignmentJson(9),
            _assignmentJson(11),
          ]));

      // Re-delivery of the same event (reconnect replay, duplicate emit).
      board.handle('responder.assigned', <String, dynamic>{
        'requestId': 42,
        'responderId': 11,
        'assignment': _assignmentJson(11),
        'assignments': <dynamic>[_assignmentJson(9), _assignmentJson(11)],
        'request': _requestSnapshot(assignments: [
          _assignmentJson(9),
          _assignmentJson(11),
        ]),
      });
      board.handle('responder.assigned', <String, dynamic>{
        'requestId': 42,
        'responderId': 11,
        'assignment': _assignmentJson(11),
        'assignments': <dynamic>[_assignmentJson(9), _assignmentJson(11)],
        'request': _requestSnapshot(assignments: [
          _assignmentJson(9),
          _assignmentJson(11),
        ]),
      });

      expect(board.open.single.assignments, hasLength(2));
      expect(board.open.single.assignments.where((a) => a.responderId == 11),
          hasLength(1));
    });

    test('responder.assigned without a snapshot merges the single row', () {
      final board = _ResponderBoard()..seed(_requestSnapshot(assignments: [
            _assignmentJson(9),
          ]));

      // Fallback path: only the assignment row is present.
      board.handle('responder.assigned', <String, dynamic>{
        'requestId': 42,
        'responderId': 11,
        'assignment': _assignmentJson(11),
      });

      expect(board.open.single.assignments, hasLength(2));
      expect(board.open.single.isAssignedTo(11), isTrue);
    });

    // Phase F case 15 ------------------------------------------------------
    test('request.updated refreshes the assignments of a known request', () {
      final board = _ResponderBoard()..seed(_requestSnapshot(assignments: [
            _assignmentJson(9),
          ]));

      board.handle('request.updated', <String, dynamic>{
        'requestId': 42,
        'status': 'PARTIALLY_ALLOCATED',
        'acceptedById': 9,
        'acceptedAt': '2026-09-26T09:05:00.000Z',
        'request': _requestSnapshot(
          status: 'PARTIALLY_ALLOCATED',
          assignments: [
            _assignmentJson(9),
            _assignmentJson(11),
            _assignmentJson(12),
          ],
        ),
      });

      final request = board.open.single;
      expect(request.assignments, hasLength(3));
      expect(request.status, RequestStatus.partiallyAllocated);
      expect(request.acceptedBy?.id, 9,
          reason: 'acceptedBy lead semantics survive request.updated');
    });

    test('a redacted request.updated keeps a still-joinable pending card and '
        'removes a no-longer-joinable one', () {
      final board = _ResponderBoard()
        ..seedPending(_requestSnapshot(id: 77, status: 'PENDING'));

      // Phase E redaction: ACCEPTED but still joinable (outstanding work).
      board.handle('request.updated', <String, dynamic>{
        'requestId': 77,
        'status': 'ACCEPTED',
        'available': true,
        'updatedAt': '2026-09-26T11:00:00.000Z',
      });
      expect(board.pending.map((r) => r.id), contains(77));

      // Fully allocated / terminal: not joinable any more.
      board.handle('request.updated', <String, dynamic>{
        'requestId': 77,
        'status': 'IN_PROGRESS',
        'available': false,
        'updatedAt': '2026-09-26T11:05:00.000Z',
      });
      expect(board.pending.map((r) => r.id), isNot(contains(77)));
    });

    // Phase F case 16 ------------------------------------------------------
    test('location updates from two responders are stored by responderId',
        () {
      final board = _ResponderBoard()..seed(_requestSnapshot());

      board.handle('responder.location.update', <String, dynamic>{
        'requestId': 42,
        'responderId': 9,
        'latitude': 10.5281,
        'longitude': 76.2151,
        'timestamp': '2026-09-26T11:00:00.000Z',
      });
      board.handle('responder.location.update', <String, dynamic>{
        'requestId': 42,
        'responderId': 11,
        'latitude': 10.5399,
        'longitude': 76.2244,
        'timestamp': '2026-09-26T11:00:01.000Z',
      });

      final points = board.store.locationsForRequest(42);
      expect(points[9]!.latitude, 10.5281);
      expect(points[11]!.latitude, 10.5399);
      expect(points[9]!.responderId, 9);
      expect(points[11]!.responderId, 11);
    });

    // Phase F case 17 ------------------------------------------------------
    test('responder.location.stop removes only that responder stream', () {
      final board = _ResponderBoard()..seed(_requestSnapshot(assignments: [
            _assignmentJson(9),
            _assignmentJson(11),
          ]));

      board.handle('responder.location.update', <String, dynamic>{
        'requestId': 42,
        'responderId': 9,
        'latitude': 10.5,
        'longitude': 76.2,
        'timestamp': '2026-09-26T11:00:00.000Z',
      });
      board.handle('responder.location.update', <String, dynamic>{
        'requestId': 42,
        'responderId': 11,
        'latitude': 10.6,
        'longitude': 76.3,
        'timestamp': '2026-09-26T11:00:01.000Z',
      });

      board.handle('responder.location.stop', <String, dynamic>{
        'requestId': 42,
        'responderId': 9,
        'timestamp': '2026-09-26T11:02:00.000Z',
      });

      final points = board.store.locationsForRequest(42);
      expect(points[9]!.isLive, isFalse);
      expect(points[11]!.isLive, isTrue,
          reason: 'one stop must never end the other responder stream');
    });

    // Phase F case 18 ------------------------------------------------------
    test('terminal cleanup removes every responder location of the request',
        () {
      final board = _ResponderBoard()..seed(_requestSnapshot(assignments: [
            _assignmentJson(9),
            _assignmentJson(11),
          ]));

      board.handle('responder.location.update', <String, dynamic>{
        'requestId': 42,
        'responderId': 9,
        'latitude': 10.5,
        'longitude': 76.2,
        'timestamp': '2026-09-26T11:00:00.000Z',
      });
      board.handle('responder.location.update', <String, dynamic>{
        'requestId': 42,
        'responderId': 11,
        'latitude': 10.6,
        'longitude': 76.3,
        'timestamp': '2026-09-26T11:00:01.000Z',
      });

      board.handle('request.updated', <String, dynamic>{
        'requestId': 42,
        'status': 'COMPLETED',
        'request': _requestSnapshot(
          status: 'COMPLETED',
          assignments: [_assignmentJson(9), _assignmentJson(11)],
        ),
      });

      expect(board.store.locationsForRequest(42), isEmpty);
      expect(board.open, isEmpty);
      expect(board.closed.map((r) => r.id), contains(42));
    });

    test('allocation.updated patches a request without losing assignments',
        () {
      final board = _ResponderBoard()..seed(_requestSnapshot(assignments: [
            _assignmentJson(9),
            _assignmentJson(11),
          ]));

      board.handle('allocation.updated', <String, dynamic>{
        'allocationId': 900,
        'requestId': 42,
        'status': 'RESERVED',
        'quantity': 2,
        'resourceId': 4,
        'responderId': 11,
        'requestStatus': 'PARTIALLY_ALLOCATED',
        'allocation': <String, dynamic>{
          'id': 900,
          'requestId': 42,
          'resourceId': 4,
          'responderId': 11,
          'responderResourceId': 7,
          'quantity': 2,
          'status': 'RESERVED',
          'resource': <String, dynamic>{'id': 4, 'name': 'Blood'},
          'responder': <String, dynamic>{'id': 11, 'name': 'Responder B'},
        },
      });

      final request = board.open.single;
      expect(request.assignments, hasLength(2),
          reason: 'assignments survive allocation patches');
      expect(request.allocations.single.responderId, 11);
      expect(request.status, RequestStatus.partiallyAllocated);
    });
  });
}

/// Mirror of the DispatchConsolePage responder-side realtime pipeline,
/// reduced to the public building blocks so the event contract is testable.
class _ResponderBoard {
  final List<EmergencyRequest> open = <EmergencyRequest>[];
  final List<EmergencyRequest> pending = <EmergencyRequest>[];
  final List<EmergencyRequest> closed = <EmergencyRequest>[];
  final LiveLocationStore store = LiveLocationStore();

  static const int currentUserId = 9;

  void seed(EmergencyRequest request) => open.add(request);
  void seedPending(EmergencyRequest request) => pending.add(request);

  void handle(String name, Map<String, dynamic> payload) {
    switch (name) {
      case 'responder.assigned':
        final rawRequest = payload['request'];
        if (rawRequest is Map) {
          _apply(EmergencyRequest.fromJson(
            Map<String, dynamic>.from(rawRequest),
          ));
          return;
        }
        final rawAssignment = payload['assignment'];
        final requestId = payload['requestId'];
        if (rawAssignment is Map && requestId is int) {
          final assignment = ResponderAssignmentLine.fromJson(
            Map<String, dynamic>.from(rawAssignment),
          );
          _patch(requestId, (request) => request.withAssignment(assignment));
        }
        return;

      case 'request.created':
      case 'request.updated':
        final rawRequest = payload['request'];
        if (rawRequest is Map) {
          _apply(EmergencyRequest.fromJson(
            Map<String, dynamic>.from(rawRequest),
          ));
          return;
        }
        // Redacted invalidation: only remove when no longer joinable.
        if (payload['available'] != true) {
          final requestId = payload['requestId'];
          pending.removeWhere((request) => request.id == requestId);
        }
        return;

      case 'allocation.updated':
        final rawAllocation = payload['allocation'];
        if (rawAllocation is! Map) return;
        final allocation = AllocationLine.fromJson(
          Map<String, dynamic>.from(rawAllocation),
        );
        final requestStatus = payload['requestStatus']?.toString();
        _patch(
          allocation.requestId,
          (request) => request.withAllocation(
            allocation,
            backendRequestStatus: requestStatus,
          ),
        );
        return;

      case 'responder.location.update':
        store.applyUpdate(LiveResponderLocation.fromJson(payload));
        return;

      case 'responder.location.stop':
        final requestId = payload['requestId'];
        final responderId = payload['responderId'];
        if (requestId is int) {
          store.stopSharing(requestId,
              responderId: responderId is int ? responderId : null);
        }
        return;
    }
  }

  void _apply(EmergencyRequest request) {
    open.removeWhere((row) => row.id == request.id);
    pending.removeWhere((row) => row.id == request.id);
    closed.removeWhere((row) => row.id == request.id);

    final mine = request.participatesAsResponder(currentUserId);
    if (request.isOpen && mine) {
      open.add(request);
    } else if (request.status == RequestStatus.pending) {
      pending.add(request);
    } else if (!request.isOpen && mine) {
      closed.add(request);
    }

    if (!request.isOpen) {
      store.removeRequest(request.id);
    } else {
      store.reconcile(open);
    }
  }

  void _patch(
    int requestId,
    EmergencyRequest Function(EmergencyRequest) update,
  ) {
    final index = open.indexWhere((row) => row.id == requestId);
    if (index >= 0) open[index] = update(open[index]);
  }
}

Map<String, dynamic> _assignmentJson(int responderId) =>
    <String, dynamic>{
      'id': responderId,
      'requestId': 42,
      'responderId': responderId,
      'status': 'ACTIVE',
      'acceptedAt': '2026-09-26T09:0${responderId % 10}:00.000Z',
      'responder': <String, dynamic>{
        'id': responderId,
        'name': 'Responder $responderId',
        'responderStatus': 'BUSY',
      },
    };

Map<String, dynamic> _requestJson({
  int id = 42,
  String status = 'ACCEPTED',
  List<Map<String, dynamic>> assignments = const [],
}) {
  return <String, dynamic>{
    'id': id,
    'emergencyType': 'Medical',
    'location': 'Thrissur, Kerala',
    'priority': 'HIGH',
    'status': status,
    'createdAt': '2026-09-26T09:00:00.000Z',
    'acceptedAt': '2026-09-26T09:05:00.000Z',
    'requiredResources': <dynamic>[],
    'allocations': <dynamic>[],
    'acceptedBy': <String, dynamic>{'id': 9, 'name': 'Responder 9'},
    'assignments': assignments,
  };
}

EmergencyRequest _requestSnapshot({
  int id = 42,
  String status = 'ACCEPTED',
  List<Map<String, dynamic>> assignments = const [],
}) {
  return EmergencyRequest.fromJson(
    _requestJson(id: id, status: status, assignments: assignments),
  );
}

