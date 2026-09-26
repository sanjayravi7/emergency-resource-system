import 'package:flutter/material.dart';

import '../models/eras_models.dart';
import '../state/request_lifecycle.dart';
import '../theme/app_theme.dart';

/// PENDING -> ACCEPTED -> ALLOCATED -> DISPATCHED -> DELIVERED -> COMPLETED
///
/// Every step is derived from the backend request/allocation statuses by
/// [RequestLifecycle]; this widget only paints them.
class RequestTimeline extends StatelessWidget {
  const RequestTimeline({super.key, required this.request, this.dense = false});

  final EmergencyRequest request;
  final bool dense;

  Color _colorFor(LifecycleStep step) => switch (step.state) {
        LifecycleStageState.done => AppColors.teal,
        LifecycleStageState.current => AppColors.blue,
        LifecycleStageState.cancelled => AppColors.red,
        LifecycleStageState.upcoming => AppColors.textFaint,
      };

  @override
  Widget build(BuildContext context) {
    final steps = RequestLifecycle.stepsFor(request);

    return Wrap(
      spacing: 4,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        for (var i = 0; i < steps.length; i++) ...<Widget>[
          if (i > 0)
            Icon(
              Icons.chevron_right_rounded,
              size: dense ? 12 : 14,
              color: AppColors.textFaint,
            ),
          _StageChip(
            label: steps[i].label,
            color: _colorFor(steps[i]),
            state: steps[i].state,
            dense: dense,
          ),
        ],
      ],
    );
  }
}

class _StageChip extends StatelessWidget {
  const _StageChip({
    required this.label,
    required this.color,
    required this.state,
    required this.dense,
  });

  final String label;
  final Color color;
  final LifecycleStageState state;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final filled = state == LifecycleStageState.current ||
        state == LifecycleStageState.cancelled;

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 6 : 8,
        vertical: dense ? 2 : 3,
      ),
      decoration: BoxDecoration(
        color: filled ? color.withValues(alpha: .12) : Colors.transparent,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: state == LifecycleStageState.upcoming
              ? AppColors.border
              : color.withValues(alpha: .55),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (state == LifecycleStageState.done) ...[
            Icon(Icons.check_rounded, size: dense ? 9 : 10, color: color),
            const SizedBox(width: 3),
          ],
          Text(
            label,
            style: monoStyle(
              size: dense ? 9 : 10,
              color: color,
              weight: state == LifecycleStageState.upcoming
                  ? FontWeight.w400
                  : FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Per-allocation operational detail: resource, quantity, responder and the
/// current backend status, plus the single action that is valid right now.
///
///  - DISPATCHED  -> the requester sees "Confirm Received"
///  - DELIVERED   -> the requester sees a "Delivered" marker
class AllocationProgressList extends StatelessWidget {
  const AllocationProgressList({
    super.key,
    required this.request,
    this.onConfirmReceipt,
    this.onDispatch,
    this.onMarkDelivered,
    this.currentUserId,
    this.isResponderView = false,
  });

  final EmergencyRequest request;
  final void Function(AllocationLine allocation)? onConfirmReceipt;
  final void Function(AllocationLine allocation)? onDispatch;
  final void Function(AllocationLine allocation)? onMarkDelivered;
  final int? currentUserId;
  final bool isResponderView;

  Color _statusColor(AllocationLine allocation) {
    if (allocation.isDelivered) return AppColors.teal;
    if (allocation.isDispatched) return AppColors.blue;
    if (allocation.isReserved) return AppColors.amber;
    return AppColors.textFaint;
  }

  @override
  Widget build(BuildContext context) {
    final allocations = request.allocations
        .where((allocation) => allocation.isActive)
        .toList(growable: false);

    if (allocations.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 4),
        child: Text(
          'No resources allocated yet.',
          style: TextStyle(fontSize: 12, color: AppColors.textFaint),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: allocations.map((allocation) {
        final color = _statusColor(allocation);
        final mine = currentUserId != null &&
            allocation.responderId == currentUserId;

        final actions = <Widget>[];

        if (!isResponderView &&
            allocation.isDispatched &&
            onConfirmReceipt != null) {
          actions.add(
            FilledButton(
              onPressed: () => onConfirmReceipt!(allocation),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.teal,
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                minimumSize: const Size(0, 30),
              ),
              child:
                  const Text('Confirm Received', style: TextStyle(fontSize: 11.5)),
            ),
          );
        }

        if (isResponderView && mine && allocation.isReserved &&
            onDispatch != null) {
          actions.add(
            OutlinedButton(
              onPressed: () => onDispatch!(allocation),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.blue,
                side: const BorderSide(color: AppColors.blue),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                minimumSize: const Size(0, 30),
              ),
              child: const Text('Confirm & Dispatch',
                  style: TextStyle(fontSize: 11.5)),
            ),
          );
        }

        if (isResponderView && mine && allocation.isDispatched &&
            onMarkDelivered != null) {
          actions.add(
            FilledButton(
              onPressed: () => onMarkDelivered!(allocation),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.teal,
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                minimumSize: const Size(0, 30),
              ),
              child:
                  const Text('Mark Delivered', style: TextStyle(fontSize: 11.5)),
            ),
          );
        }

        if (allocation.isDelivered) {
          actions.add(
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.tealDim,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.task_alt_rounded,
                      size: 12, color: AppColors.teal),
                  const SizedBox(width: 4),
                  Text(
                    'Delivered',
                    style: monoStyle(
                      size: 10.5,
                      color: AppColors.teal,
                      weight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        return Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.surface2,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${allocation.resourceName} × ${allocation.quantity}',
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: AppColors.text,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: .12),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      allocation.status,
                      style: monoStyle(
                        size: 10,
                        color: color,
                        weight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                'Responder: ${allocation.responderName ?? 'assigned responder'}',
                style: const TextStyle(fontSize: 11.5, color: AppColors.textDim),
              ),
              if (actions.isNotEmpty) ...[
                const SizedBox(height: 7),
                Wrap(spacing: 6, runSpacing: 6, children: actions),
              ],
            ],
          ),
        );
      }).toList(),
    );
  }
}
