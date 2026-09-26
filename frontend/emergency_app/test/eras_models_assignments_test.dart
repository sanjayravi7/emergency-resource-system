import 'package:dispatch_console_flutter/models/eras_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// Phase F model contract tests. Every payload shape below is exactly what
/// the Phase B–E backend emits; nothing is invented client-side.
void main() {
  group('EmergencyRequest.assignments (Phase F)', () {
    // Phase F case 1 -------------------------------------------------------
    test('an old payload without assignments parses to an empty list', () {
      final request = EmergencyRequest.fromJson(<String, dynamic>{
        'id': 42,
        'emergencyType': 'Medical',
        'location': 'Thrissur, Kerala',
        'priority': 'HIGH',
        'status': 'ACCEPTED',
        'createdAt': '2026-09-26T09:00:00.000Z',
        'requiredResources': <dynamic>[],
        'allocations': <dynamic>[],
        'acceptedBy': <String, dynamic>{'id': 9, 'name': 'Lead Responder'},
        'acceptedAt': '2026-09-26T09:05:00.000Z',
      });

      expect(request.assignments, isEmpty);
      expect(request.activeAssignments, isEmpty);
      // Legacy lead still recognized (pair has no assignment row).
      expect(request.isLegacyAcceptedBy(9), isTrue);
      expect(request.participatesAsResponder(9), isTrue);
      expect(request.acceptedBy?.id, 9);
      expect(request.acceptedAt, DateTime.parse('2026-09-26T09:05:00Z'));
    });

    // Phase F case 2 -------------------------------------------------------
    test('an explicitly empty assignments array parses', () {
      final request = EmergencyRequest.fromJson(<String, dynamic>{
        'id': 43,
        'emergencyType': 'Fire',
        'location': 'Kochi, Kerala',
        'priority': 'CRITICAL',
        'status': 'PENDING',
        'createdAt': '2026-09-26T09:00:00.000Z',
        'requiredResources': <dynamic>[],
        'allocations': <dynamic>[],
        'assignments': <dynamic>[],
      });

      expect(request.assignments, isEmpty);
      expect(request.isAssignedTo(9), isFalse);
    });

    // Phase F case 3 -------------------------------------------------------
    test('multiple assignments parse with full state', () {
      final request = _multiResponderRequest();

      expect(request.assignments, hasLength(3));
      expect(request.assignments.map((a) => a.responderId), <int>[9, 11, 12]);
      expect(request.assignments.first.status, 'ACTIVE');
      expect(request.assignments.last.status, 'ENDED');
      expect(request.assignments.first.acceptedAt,
          DateTime.parse('2026-09-26T09:05:00Z'));
      expect(request.assignments.last.endedAt,
          DateTime.parse('2026-09-26T10:40:00Z'));
      expect(request.assignments.first.responder?.name, 'Responder A');
    });

    // Phase F case 4 -------------------------------------------------------
    test('isAssignedTo(A) is true only through the ACTIVE assignment', () {
      final request = _multiResponderRequest();

      expect(request.isAssignedTo(9), isTrue);
      expect(request.isAssignedTo(11), isTrue);
    });

    // Phase F case 5 -------------------------------------------------------
    test('isAssignedTo(B) works and unrelated ids are not assigned', () {
      final request = _multiResponderRequest();

      expect(request.isAssignedTo(11), isTrue);
      expect(request.isAssignedTo(999), isFalse);
      expect(request.isAssignedTo(12), isFalse,
          reason: 'responder 12 only has an ENDED assignment');
    });

    // Phase F case 6 -------------------------------------------------------
    test('an ENDED assignment is never active work', () {
      final request = _multiResponderRequest();

      expect(request.assignments
          .firstWhere((a) => a.responderId == 12)
          .isEnded, isTrue);
      expect(request.isAssignedTo(12), isFalse);
      expect(request.participatesAsResponder(12), isFalse);
      expect(
        request.activeAssignments.any((a) => a.responderId == 12),
        isFalse,
      );
    });

    // Phase F case 7 -------------------------------------------------------
    test('acceptedBy remains the lead responder alongside assignments', () {
      final request = _multiResponderRequest();

      expect(request.acceptedBy?.id, 9);
      expect(request.acceptedBy?.name, 'Responder A');
      expect(request.acceptedAt, DateTime.parse('2026-09-26T09:05:00Z'));
      // The lead also holds an ACTIVE assignment row (normal Phase C flow).
      expect(request.isAssignedTo(9), isTrue);
      // Additional responders are exposed without touching the lead fields.
      expect(request.additionalActiveAssignments.map((a) => a.responderId),
          <int>[11]);
    });

    test('the lead without an assignment row stays a legacy participant', () {
      final request = EmergencyRequest.fromJson(<String, dynamic>{
        'id': 45,
        'emergencyType': 'Flood',
        'location': 'Aluva, Kerala',
        'priority': 'HIGH',
        'status': 'ACCEPTED',
        'createdAt': '2026-09-26T09:00:00.000Z',
        'requiredResources': <dynamic>[],
        'allocations': <dynamic>[],
        // Other responders have rows; the lead pair has none: the backend
        // legacy fallback still authorizes the lead (pair-scoped rule).
        'assignments': <dynamic>[
          <String, dynamic>{
            'id': 2,
            'requestId': 45,
            'responderId': 11,
            'status': 'ACTIVE',
            'acceptedAt': '2026-09-26T09:20:00.000Z',
          },
        ],
        'acceptedBy': <String, dynamic>{'id': 9, 'name': 'Legacy Lead'},
      });

      expect(request.isLegacyAcceptedBy(9), isTrue);
      expect(request.participatesAsResponder(9), isTrue);
      // Once the lead pair has its own row, the table alone decides.
      final withLeadRow = request.withAssignment(ResponderAssignmentLine(
        id: 3,
        requestId: 45,
        responderId: 9,
        status: 'ENDED',
        endedAt: DateTime.parse('2026-09-26T10:00:00Z'),
      ));
      expect(withLeadRow.isLegacyAcceptedBy(9), isFalse);
      expect(withLeadRow.participatesAsResponder(9), isFalse);
    });

    test('an allocation-only responder participates without an assignment',
        () {
      final request = EmergencyRequest.fromJson(<String, dynamic>{
        'id': 46,
        'emergencyType': 'Medical',
        'location': 'Thrissur, Kerala',
        'priority': 'HIGH',
        'status': 'IN_PROGRESS',
        'createdAt': '2026-09-26T09:00:00.000Z',
        'requiredResources': <dynamic>[],
        'allocations': <dynamic>[
          <String, dynamic>{
            'id': 900,
            'requestId': 46,
            'resourceId': 4,
            'responderId': 11,
            'responderResourceId': 7,
            'quantity': 2,
            'status': 'RESERVED',
            'resource': <String, dynamic>{'id': 4, 'name': 'Blood'},
            'responder': <String, dynamic>{'id': 11, 'name': 'Responder B'},
          },
          <String, dynamic>{
            'id': 901,
            'requestId': 46,
            'resourceId': 4,
            'responderId': 12,
            'responderResourceId': 8,
            'quantity': 1,
            'status': 'CANCELLED',
            'resource': <String, dynamic>{'id': 4, 'name': 'Blood'},
            'responder': <String, dynamic>{'id': 12, 'name': 'Responder C'},
          },
        ],
        'assignments': <dynamic>[],
      });

      // RESERVED allocation owner participates (allocation-only flow).
      expect(request.ownsUnfinishedAllocation(11), isTrue);
      expect(request.participatesAsResponder(11), isTrue);
      expect(request.isAssignedTo(11), isFalse,
          reason: 'participation without assignment stays distinguishable');
      // CANCELLED allocation is not unfinished work.
      expect(request.ownsUnfinishedAllocation(12), isFalse);
      expect(request.participatesAsResponder(12), isFalse);
    });

    test('withAssignment replaces the same responder without duplicating', () {
      final request = _multiResponderRequest();

      final updated = request.withAssignment(ResponderAssignmentLine(
        id: 99,
        requestId: request.id,
        responderId: 11,
        status: 'ACTIVE',
        acceptedAt: DateTime.parse('2026-09-26T09:30:00Z'),
        responder: UserSummary(id: 11, name: 'Responder B Updated'),
      ));

      expect(updated.assignments, hasLength(3));
      expect(
        updated.assignments.where((a) => a.responderId == 11),
        hasLength(1),
      );
      expect(
        updated.assignments
            .firstWhere((a) => a.responderId == 11)
            .responder
            ?.name,
        'Responder B Updated',
      );
      // Untouched rows survive.
      expect(updated.isAssignedTo(9), isTrue);
      // withAllocation preserves assignments through allocation events.
      final withAllocation = updated.withAllocation(
        AllocationLine.fromJson(<String, dynamic>{
          'id': 950,
          'requestId': request.id,
          'resourceId': 4,
          'responderId': 11,
          'responderResourceId': 7,
          'quantity': 1,
          'status': 'RESERVED',
          'resource': <String, dynamic>{'id': 4, 'name': 'Blood'},
        }),
      );
      expect(withAllocation.assignments, hasLength(3));
    });
  });
}

/// DB-42 style multi-responder snapshot: lead 9 (ACTIVE), responder 11
/// (ACTIVE), responder 12 (ENDED).
EmergencyRequest _multiResponderRequest() {
  return EmergencyRequest.fromJson(<String, dynamic>{
    'id': 42,
    'emergencyType': 'Medical',
    'description': 'Multi responder model test',
    'location': 'Thrissur, Kerala',
    'priority': 'HIGH',
    'status': 'PARTIALLY_ALLOCATED',
    'createdAt': '2026-09-26T09:00:00.000Z',
    'updatedAt': '2026-09-26T10:45:00.000Z',
    'acceptedAt': '2026-09-26T09:05:00.000Z',
    'requiredResources': <dynamic>[],
    'allocations': <dynamic>[],
    'acceptedBy': <String, dynamic>{
      'id': 9,
      'name': 'Responder A',
      'responderStatus': 'BUSY',
    },
    'assignments': <dynamic>[
      <String, dynamic>{
        'id': 1,
        'requestId': 42,
        'responderId': 9,
        'status': 'ACTIVE',
        'acceptedAt': '2026-09-26T09:05:00.000Z',
        'createdAt': '2026-09-26T09:05:00.000Z',
        'updatedAt': '2026-09-26T09:05:00.000Z',
        'responder': <String, dynamic>{
          'id': 9,
          'name': 'Responder A',
          'phone': '555-0101',
          'responderStatus': 'BUSY',
        },
      },
      <String, dynamic>{
        'id': 2,
        'requestId': 42,
        'responderId': 11,
        'status': 'ACTIVE',
        'acceptedAt': '2026-09-26T09:20:00.000Z',
        'responder': <String, dynamic>{
          'id': 11,
          'name': 'Responder B',
          'phone': '555-0102',
          'responderStatus': 'BUSY',
        },
      },
      <String, dynamic>{
        'id': 3,
        'requestId': 42,
        'responderId': 12,
        'status': 'ENDED',
        'acceptedAt': '2026-09-26T09:25:00.000Z',
        'endedAt': '2026-09-26T10:40:00.000Z',
        'responder': <String, dynamic>{
          'id': 12,
          'name': 'Responder C',
        },
      },
    ],
  });
}
