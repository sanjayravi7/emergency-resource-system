import '../models/eras_models.dart';

/// Operational stages shown to the requester.
///
/// This is NOT a second lifecycle model: every stage below is read from the
/// status values PostgreSQL already returned (the request status and the
/// allocation statuses). Nothing here advances, guesses or stores state - it
/// only describes what the backend has already committed.
enum LifecycleStage {
  pending,
  accepted,
  allocated,
  dispatched,
  delivered,
  completed,
  cancelled,
}

enum LifecycleStageState { done, current, upcoming, cancelled }

class LifecycleStep {
  const LifecycleStep(this.stage, this.state);

  final LifecycleStage stage;
  final LifecycleStageState state;

  bool get isDone => state == LifecycleStageState.done;
  bool get isCurrent => state == LifecycleStageState.current;

  String get label => switch (stage) {
        LifecycleStage.pending => 'PENDING',
        LifecycleStage.accepted => 'ACCEPTED',
        LifecycleStage.allocated => 'ALLOCATED',
        LifecycleStage.dispatched => 'DISPATCHED',
        LifecycleStage.delivered => 'DELIVERED',
        LifecycleStage.completed => 'COMPLETED',
        LifecycleStage.cancelled => 'CANCELLED',
      };
}

class RequestLifecycle {
  const RequestLifecycle._();

  static const List<LifecycleStage> orderedStages = <LifecycleStage>[
    LifecycleStage.pending,
    LifecycleStage.accepted,
    LifecycleStage.allocated,
    LifecycleStage.dispatched,
    LifecycleStage.delivered,
    LifecycleStage.completed,
  ];

  static bool isCancelled(EmergencyRequest request) =>
      request.status == RequestStatus.cancelled;

  /// Highest stage the backend data proves has been reached.
  static LifecycleStage reachedStage(EmergencyRequest request) {
    if (request.status == RequestStatus.cancelled) {
      return LifecycleStage.cancelled;
    }
    if (request.status == RequestStatus.completed) {
      return LifecycleStage.completed;
    }

    final active = request.allocations
        .where((allocation) => allocation.isActive)
        .toList(growable: false);

    if (active.any((allocation) => allocation.isDelivered)) {
      return LifecycleStage.delivered;
    }
    if (active.any((allocation) => allocation.isDispatched)) {
      return LifecycleStage.dispatched;
    }
    if (active.isNotEmpty) {
      return LifecycleStage.allocated;
    }
    if (request.acceptedBy != null ||
        request.status == RequestStatus.accepted ||
        request.status == RequestStatus.inProgress ||
        request.status == RequestStatus.partiallyAllocated) {
      return LifecycleStage.accepted;
    }
    return LifecycleStage.pending;
  }

  /// PENDING -> ACCEPTED -> ALLOCATED -> DISPATCHED -> DELIVERED -> COMPLETED
  static List<LifecycleStep> stepsFor(EmergencyRequest request) {
    final reached = reachedStage(request);

    if (reached == LifecycleStage.cancelled) {
      // A cancelled request keeps the stages it really reached and ends on a
      // terminal CANCELLED marker instead of a fake completion.
      final progressed = _stagesReachedBeforeCancellation(request);
      final steps = <LifecycleStep>[];
      for (final stage in orderedStages) {
        if (stage == LifecycleStage.completed) continue;
        steps.add(
          LifecycleStep(
            stage,
            progressed.contains(stage)
                ? LifecycleStageState.done
                : LifecycleStageState.upcoming,
          ),
        );
      }
      steps.add(
        const LifecycleStep(
          LifecycleStage.cancelled,
          LifecycleStageState.cancelled,
        ),
      );
      return steps;
    }

    final reachedIndex = orderedStages.indexOf(reached);
    return <LifecycleStep>[
      for (var i = 0; i < orderedStages.length; i++)
        LifecycleStep(
          orderedStages[i],
          i < reachedIndex
              ? LifecycleStageState.done
              : i == reachedIndex
                  ? LifecycleStageState.current
                  : LifecycleStageState.upcoming,
        ),
    ];
  }

  static Set<LifecycleStage> _stagesReachedBeforeCancellation(
    EmergencyRequest request,
  ) {
    final reached = <LifecycleStage>{LifecycleStage.pending};
    if (request.acceptedBy != null) reached.add(LifecycleStage.accepted);

    for (final allocation in request.allocations) {
      if (allocation.isDelivered) {
        reached.addAll(<LifecycleStage>[
          LifecycleStage.accepted,
          LifecycleStage.allocated,
          LifecycleStage.dispatched,
          LifecycleStage.delivered,
        ]);
      } else if (allocation.isDispatched) {
        reached.addAll(<LifecycleStage>[
          LifecycleStage.accepted,
          LifecycleStage.allocated,
          LifecycleStage.dispatched,
        ]);
      } else if (allocation.isReserved) {
        reached.addAll(<LifecycleStage>[
          LifecycleStage.accepted,
          LifecycleStage.allocated,
        ]);
      }
    }
    return reached;
  }

  /// What the requester can do with this allocation right now, derived from
  /// the backend allocation status only.
  static String? requesterActionFor(AllocationLine allocation) {
    if (allocation.isDispatched) return 'Confirm Received';
    return null;
  }

  /// What the assigned responder can do with this allocation right now.
  static String? responderActionFor(AllocationLine allocation) {
    if (allocation.isReserved) return 'Confirm & Dispatch';
    if (allocation.isDispatched) return 'Mark Delivered';
    return null;
  }
}
