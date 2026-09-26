import 'package:flutter/material.dart';

import '../Services/socket_service.dart';
import '../models/eras_models.dart';
import '../theme/app_theme.dart';
import 'common_widgets.dart';

/// A presentation of the persisted request/allocation states. It intentionally
/// has no mutable lifecycle state of its own: every highlighted step is read
/// directly from the latest backend request snapshot.
class OperationalTimeline extends StatelessWidget {
  const OperationalTimeline({
    super.key,
    required this.request,
    this.compact = false,
  });

  final EmergencyRequest request;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (request.status == RequestStatus.cancelled) {
      return const _TerminalNotice(
        icon: Icons.cancel_outlined,
        label: 'CANCELLED',
        color: AppColors.textFaint,
      );
    }

    final allocations = request.allocations
        .where((allocation) => allocation.status != 'CANCELLED')
        .toList(growable: false);
    final accepted = request.acceptedBy != null ||
        request.status != RequestStatus.pending;
    final allocated = allocations.isNotEmpty;
    final dispatched = allocations.any(
      (allocation) =>
          allocation.status == 'DISPATCHED' || allocation.status == 'DELIVERED',
    );
    final delivered =
        allocations.any((allocation) => allocation.status == 'DELIVERED');
    final completed = request.status == RequestStatus.completed;
    final states = <(String, bool)>[
      ('PENDING', true),
      ('ACCEPTED', accepted),
      ('ALLOCATED', allocated),
      ('DISPATCHED', dispatched),
      ('DELIVERED', delivered),
      ('COMPLETED', completed),
    ];

    return Semantics(
      label: 'Operational request timeline',
      child: Wrap(
        key: ValueKey<String>('request-timeline-${request.id}'),
        spacing: compact ? 3 : 4,
        runSpacing: 5,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          for (var index = 0; index < states.length; index++) ...[
            _TimelineStep(
              label: states[index].$1,
              reached: states[index].$2,
              compact: compact,
            ),
            if (index != states.length - 1)
              Icon(
                Icons.arrow_forward_rounded,
                size: compact ? 10 : 12,
                color: states[index + 1].$2
                    ? AppColors.teal
                    : AppColors.textFaint,
              ),
          ],
        ],
      ),
    );
  }
}

class _TimelineStep extends StatelessWidget {
  const _TimelineStep({
    required this.label,
    required this.reached,
    required this.compact,
  });

  final String label;
  final bool reached;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 5 : 7,
        vertical: compact ? 2 : 3,
      ),
      decoration: BoxDecoration(
        color: reached ? AppColors.tealDim : AppColors.surface2,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: reached
              ? AppColors.teal.withValues(alpha: .35)
              : AppColors.border,
        ),
      ),
      child: Text(
        label,
        style: monoStyle(
          size: compact ? 8 : 9,
          color: reached ? AppColors.teal : AppColors.textFaint,
          weight: reached ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
    );
  }
}

class _TerminalNotice extends StatelessWidget {
  const _TerminalNotice({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 5),
          Text(label,
              style: monoStyle(size: 10, color: color, weight: FontWeight.w700)),
        ],
      );
}

/// One backend Allocation row: resource, quantity, responder and current
/// status remain visible together instead of being inferred from request text.
class AllocationOperationalRow extends StatelessWidget {
  const AllocationOperationalRow({
    super.key,
    required this.allocation,
    this.compact = false,
  });

  final AllocationLine allocation;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final content = Wrap(
      spacing: compact ? 5 : 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          allocation.resourceName,
          style: TextStyle(
            fontSize: compact ? 10.5 : 12,
            fontWeight: FontWeight.w600,
            color: AppColors.text,
          ),
        ),
        Text(
          'Quantity ${allocation.quantity}',
          style: TextStyle(
            fontSize: compact ? 9.5 : 11,
            color: AppColors.textDim,
          ),
        ),
        Text(
          'Responder: ${allocation.responderName ?? 'unassigned'}',
          style: TextStyle(
            fontSize: compact ? 9.5 : 11,
            color: AppColors.textDim,
          ),
        ),
        AllocationStatusBadge(status: allocation.status),
      ],
    );

    if (compact) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: content,
      );
    }

    return Container(
      key: ValueKey<String>('allocation-${allocation.id}'),
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 5),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.surface2,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(6),
      ),
      child: content,
    );
  }
}

class AllocationStatusBadge extends StatelessWidget {
  const AllocationStatusBadge({super.key, required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final normalized = status.toUpperCase();
    final color = switch (normalized) {
      'RESERVED' => AppColors.amber,
      'DISPATCHED' => AppColors.blue,
      'DELIVERED' => AppColors.teal,
      _ => AppColors.textFaint,
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        normalized == 'DELIVERED' ? 'Delivered' : normalized,
        style: monoStyle(size: 9.5, color: color, weight: FontWeight.w700),
      ),
    );
  }
}

class LocationSharingSummary extends StatelessWidget {
  const LocationSharingSummary({
    super.key,
    required this.isActive,
    required this.location,
    required this.connectionStatus,
    this.compact = false,
    this.responderLabel,
  });

  final bool isActive;
  final LiveResponderLocation? location;
  final RealtimeConnectionStatus connectionStatus;
  final bool compact;

  /// Optional multi-responder disambiguation, e.g. the responder's name:
  /// "LOCATION SHARING ACTIVE · Responder B". Never fabricated client-side -
  /// derived from assignment/allocation responder identities.
  final String? responderLabel;

  @override
  Widget build(BuildContext context) {
    final color = isActive ? AppColors.teal : AppColors.textFaint;
    final suffix = (responderLabel ?? '').isEmpty ? '' : ' · $responderLabel';
    final title = isActive
        ? location == null
            ? 'LOCATION SHARING ACTIVE · WAITING FOR GPS$suffix'
            : 'LOCATION SHARING ACTIVE$suffix'
        : 'LAST-KNOWN RESPONDER LOCATION$suffix';
    final detail = location == null
        ? null
        : '${location!.latitude.toStringAsFixed(5)}, '
            '${location!.longitude.toStringAsFixed(5)} · '
            'updated ${formatDateTime(location!.updatedAt)}';

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 0 : 9,
        vertical: compact ? 2 : 8,
      ),
      decoration: compact
          ? null
          : BoxDecoration(
              color: color.withValues(alpha: .08),
              border: Border.all(color: color.withValues(alpha: .25)),
              borderRadius: BorderRadius.circular(6),
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isActive ? Icons.location_on : Icons.history_rounded,
                size: compact ? 11 : 14,
                color: color,
              ),
              const SizedBox(width: 4),
              Text(
                title,
                style: monoStyle(
                  size: compact ? 8.5 : 9.5,
                  color: color,
                  weight: FontWeight.w700,
                ),
              ),
            ],
          ),
          if (detail != null)
            Text(
              detail,
              style: TextStyle(
                fontSize: compact ? 9 : 10.5,
                color: AppColors.textDim,
              ),
            ),
          if (!compact)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: ConnectionStatusIndicator(
                status: connectionStatus,
                compact: true,
              ),
            ),
        ],
      ),
    );
  }
}

class ResponderAvailabilityBanner extends StatelessWidget {
  const ResponderAvailabilityBanner({
    super.key,
    required this.responder,
    required this.unfinishedAllocations,
  });

  final BackendResponder? responder;
  final int unfinishedAllocations;

  @override
  Widget build(BuildContext context) {
    final status = responder?.status.toUpperCase() ?? 'SYNCING';
    final isBusy = status == 'BUSY';
    final isAvailable = status == 'AVAILABLE';
    final color = isBusy
        ? AppColors.amber
        : isAvailable
            ? AppColors.teal
            : AppColors.textFaint;
    final detail = unfinishedAllocations == 0
        ? 'No unfinished work'
        : '$unfinishedAllocations unfinished allocation${unfinishedAllocations == 1 ? '' : 's'}';

    return Container(
      key: const ValueKey<String>('responder-availability-banner'),
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .10),
        border: Border.all(color: color.withValues(alpha: .35)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            isBusy ? Icons.work_history_rounded : Icons.check_circle_outline,
            color: color,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  status,
                  style: monoStyle(
                    size: 12,
                    color: color,
                    weight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  style: const TextStyle(fontSize: 12, color: AppColors.textDim),
                ),
                if (isBusy)
                  const Text(
                    'Finish or cancel remaining work to become available',
                    style: TextStyle(
                      fontSize: 10.5,
                      color: AppColors.textFaint,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
