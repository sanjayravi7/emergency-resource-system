import 'package:flutter_test/flutter_test.dart';

import 'package:dispatch_console_flutter/models/eras_models.dart';
import 'package:dispatch_console_flutter/state/request_lifecycle.dart';

Map<String, dynamic> allocation({
  int id = 1,
  String status = 'RESERVED',
  int responderId = 42,
  int quantity = 1,
}) {
  return <String, dynamic>{
    'id': id,
    'requestId': 1,
    'resourceId': 3,
    'responderId': responderId,
    'responderResourceId': 5,
    'quantity': quantity,
    'status': status,
    'resource': <String, dynamic>{'id': 3, 'name': 'Ambulance', 'type': 'Medical'},
    'responder': <String, dynamic>{'id': responderId, 'name': 'Responder One'},
  };
}

EmergencyRequest request({
  String status = 'PENDING',
  bool accepted = false,
  List<Map<String, dynamic>> allocations = const <Map<String, dynamic>>[],
}) {
  return EmergencyRequest.fromJson(<String, dynamic>{
    'id': 1,
    'emergencyType': 'Medical',
    'description': 'Test emergency',
    'location': 'Old Town',
    'priority': 'HIGH',
    'status': status,
    'createdAt': '2026-09-26T10:00:00.000Z',
    'requester': <String, dynamic>{'id': 900, 'name': 'Requester'},
    'acceptedBy': accepted
        ? <String, dynamic>{'id': 42, 'name': 'Responder One'}
        : null,
    'requiredResources': <Map<String, dynamic>>[
      <String, dynamic>{
        'resourceId': 3,
        'quantity': 1,
        'resource': <String, dynamic>{
          'id': 3,
          'name': 'Ambulance',
          'type': 'Medical',
        },
      },
    ],
    'allocations': allocations,
  });
}

void main() {
  group('RequestLifecycle (derived from backend status only)', () {
    test('a fresh request is at PENDING', () {
      expect(
        RequestLifecycle.reachedStage(request()),
        LifecycleStage.pending,
      );
    });

    test('an accepted request is at ACCEPTED', () {
      expect(
        RequestLifecycle.reachedStage(
          request(status: 'ACCEPTED', accepted: true),
        ),
        LifecycleStage.accepted,
      );
    });

    test('a reserved allocation is ALLOCATED', () {
      expect(
        RequestLifecycle.reachedStage(
          request(
            status: 'IN_PROGRESS',
            accepted: true,
            allocations: <Map<String, dynamic>>[allocation()],
          ),
        ),
        LifecycleStage.allocated,
      );
    });

    test('a dispatched allocation is DISPATCHED', () {
      expect(
        RequestLifecycle.reachedStage(
          request(
            status: 'IN_PROGRESS',
            accepted: true,
            allocations: <Map<String, dynamic>>[
              allocation(status: 'DISPATCHED'),
            ],
          ),
        ),
        LifecycleStage.dispatched,
      );
    });

    test('a delivered allocation on an open request is DELIVERED', () {
      expect(
        RequestLifecycle.reachedStage(
          request(
            status: 'PARTIALLY_ALLOCATED',
            accepted: true,
            allocations: <Map<String, dynamic>>[
              allocation(status: 'DELIVERED'),
              allocation(id: 2, status: 'RESERVED'),
            ],
          ),
        ),
        LifecycleStage.delivered,
      );
    });

    test('COMPLETED comes from the backend request status', () {
      expect(
        RequestLifecycle.reachedStage(
          request(
            status: 'COMPLETED',
            accepted: true,
            allocations: <Map<String, dynamic>>[
              allocation(status: 'DELIVERED'),
            ],
          ),
        ),
        LifecycleStage.completed,
      );
    });

    test('the timeline marks exactly one current stage', () {
      final steps = RequestLifecycle.stepsFor(
        request(
          status: 'IN_PROGRESS',
          accepted: true,
          allocations: <Map<String, dynamic>>[allocation(status: 'DISPATCHED')],
        ),
      );

      expect(
        steps.map((step) => step.label).toList(),
        <String>[
          'PENDING',
          'ACCEPTED',
          'ALLOCATED',
          'DISPATCHED',
          'DELIVERED',
          'COMPLETED',
        ],
      );
      expect(steps.where((step) => step.isCurrent).length, 1);
      expect(
        steps.firstWhere((step) => step.isCurrent).stage,
        LifecycleStage.dispatched,
      );
      expect(steps.where((step) => step.isDone).length, 3);
    });

    test('a cancelled request ends on a CANCELLED marker', () {
      final steps = RequestLifecycle.stepsFor(
        request(status: 'CANCELLED', accepted: true),
      );

      expect(steps.last.stage, LifecycleStage.cancelled);
      expect(steps.last.state, LifecycleStageState.cancelled);
      expect(
        steps.map((step) => step.stage).contains(LifecycleStage.completed),
        isFalse,
      );
    });

    test('actions are derived from the allocation status', () {
      final reserved = AllocationLine.fromJson(allocation());
      final dispatched =
          AllocationLine.fromJson(allocation(status: 'DISPATCHED'));
      final delivered =
          AllocationLine.fromJson(allocation(status: 'DELIVERED'));

      expect(RequestLifecycle.responderActionFor(reserved), 'Confirm & Dispatch');
      expect(RequestLifecycle.responderActionFor(dispatched), 'Mark Delivered');
      expect(RequestLifecycle.responderActionFor(delivered), isNull);

      expect(RequestLifecycle.requesterActionFor(reserved), isNull);
      expect(RequestLifecycle.requesterActionFor(dispatched), 'Confirm Received');
      expect(RequestLifecycle.requesterActionFor(delivered), isNull);
    });
  });

  group('EmergencyRequest.withAllocation (targeted update)', () {
    test('replaces one allocation without touching the others', () {
      final original = request(
        status: 'IN_PROGRESS',
        accepted: true,
        allocations: <Map<String, dynamic>>[
          allocation(id: 1, status: 'RESERVED'),
          allocation(id: 2, status: 'RESERVED'),
        ],
      );

      final updated = original.withAllocation(
        AllocationLine.fromJson(allocation(id: 2, status: 'DISPATCHED')),
      );

      expect(updated.allocations.length, 2);
      expect(
        updated.allocations.firstWhere((a) => a.id == 1).status,
        'RESERVED',
      );
      expect(
        updated.allocations.firstWhere((a) => a.id == 2).status,
        'DISPATCHED',
      );
      // The original snapshot is untouched.
      expect(
        original.allocations.firstWhere((a) => a.id == 2).status,
        'RESERVED',
      );
    });

    test('a realtime snapshot keeps the richer REST contact details', () {
      final fromRest = EmergencyRequest.fromJson(<String, dynamic>{
        'id': 1,
        'emergencyType': 'Medical',
        'description': 'Test emergency',
        'location': 'Old Town',
        'priority': 'HIGH',
        'status': 'ACCEPTED',
        'createdAt': '2026-09-26T10:00:00.000Z',
        'requester': <String, dynamic>{
          'id': 900,
          'name': 'Requester',
          'email': 'requester@test.com',
          'phone': '9876543210',
        },
        'acceptedBy': <String, dynamic>{
          'id': 42,
          'name': 'Responder One',
          'phone': '9000000000',
        },
        'requiredResources': const <Map<String, dynamic>>[],
        'allocations': const <Map<String, dynamic>>[],
      });

      final fromSocket = request(status: 'IN_PROGRESS', accepted: true)
          .withDetailsFrom(fromRest);

      expect(fromSocket.statusRaw, 'IN_PROGRESS');
      expect(fromSocket.requester!.email, 'requester@test.com');
      expect(fromSocket.acceptedBy!.phone, '9000000000');
    });

    test('an unassigned snapshot is never back-filled with the old responder',
        () {
      final accepted = request(status: 'ACCEPTED', accepted: true);
      final unassigned =
          request(status: 'PENDING').withDetailsFrom(accepted);

      expect(unassigned.acceptedBy, isNull);
    });

    test('appends an allocation that was not known yet', () {
      final original = request(status: 'ACCEPTED', accepted: true);

      final updated = original.withAllocation(
        AllocationLine.fromJson(allocation(id: 9)),
      );

      expect(updated.allocations.length, 1);
      expect(updated.allocations.single.id, 9);
    });
  });
}
