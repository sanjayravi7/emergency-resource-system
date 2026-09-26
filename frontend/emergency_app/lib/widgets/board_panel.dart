import 'package:flutter/material.dart';

import '../models/eras_models.dart';
import '../theme/app_theme.dart';
import 'common_widgets.dart';
import 'request_timeline.dart';

/// Dispatch board. Everything shown here comes from PostgreSQL through the
/// API - there is no local simulation of state anywhere.
class BoardPanel extends StatelessWidget {
  const BoardPanel({
    super.key,
    required this.title,
    required this.hint,
    required this.requests,
    required this.role,
    required this.emptyMessage,
    this.emptyTitle,
    this.emptyIcon,
    this.currentUserId,
    this.onAccept,
    this.onAllocate,
    this.onCancelRequest,
    this.onDispatchAllocation,
    this.onMarkDelivered,
    this.onConfirmReceipt,
    this.liveLocations = const <int, LiveResponderLocation>{},
    this.isMobile = false,
    this.detailed = false,
  });

  final String title;
  final String hint;
  final List<EmergencyRequest> requests;
  final String? role;
  final int? currentUserId;
  final String emptyMessage;
  final String? emptyTitle;
  final IconData? emptyIcon;
  final void Function(EmergencyRequest request)? onAccept;
  final void Function(EmergencyRequest request)? onAllocate;
  final void Function(EmergencyRequest request)? onCancelRequest;
  final void Function(AllocationLine allocation)? onDispatchAllocation;
  final void Function(AllocationLine allocation)? onMarkDelivered;
  final void Function(AllocationLine allocation)? onConfirmReceipt;
  final Map<int, LiveResponderLocation> liveLocations;
  final bool isMobile;

  /// Operational layout: one card per request with the lifecycle timeline and
  /// the per-allocation detail. Used for the requester board and for the
  /// responder's own active emergency.
  final bool detailed;

  bool _canAccept(EmergencyRequest request) =>
      role == 'RESPONDER' &&
      request.status == RequestStatus.pending &&
      onAccept != null;

  bool _canAllocate(EmergencyRequest request) =>
      role == 'RESPONDER' &&
      onAllocate != null &&
      request.acceptedBy != null &&
      request.acceptedBy!.id == currentUserId &&
      request.isOpen &&
      !request.isFullyAllocated;

  bool _canCancel(EmergencyRequest request) =>
      role == 'REQUESTER' &&
      onCancelRequest != null &&
      request.canBeCancelledByRequester;

  List<AllocationLine> _dispatchable(EmergencyRequest request) => request.allocations
      .where((allocation) =>
          role == 'RESPONDER' &&
          allocation.responderId == currentUserId &&
          allocation.isReserved)
      .toList(growable: false);

  // Responder-side delivery fallback: the responder may complete their own
  // DISPATCHED allocation when the requester never confirms receipt.
  List<AllocationLine> _deliverable(EmergencyRequest request) => request.allocations
      .where((allocation) =>
          role == 'RESPONDER' &&
          allocation.responderId == currentUserId &&
          allocation.isDispatched)
      .toList(growable: false);

  List<AllocationLine> _receivable(EmergencyRequest request) => request.allocations
      .where((allocation) =>
          role == 'REQUESTER' && allocation.isDispatched)
      .toList(growable: false);

  String? _allocationStateText(EmergencyRequest request, int resourceId) {
    final statuses = request.allocations
        .where((allocation) => allocation.resourceId == resourceId)
        .map((allocation) => allocation.status)
        .toSet()
        .join(' / ');
    return statuses.isEmpty ? null : statuses;
  }

  @override
  Widget build(BuildContext context) {
    return Panel(
      title: title,
      hint: isMobile ? '' : hint,
      child: requests.isEmpty
          ? EmptyState(emptyMessage, title: emptyTitle, icon: emptyIcon)
          : (isMobile || detailed)
              ? Column(
                  children: requests
                      .map((request) => _RequestCard(
                            request: request,
                            actions: _actions(request),
                            liveLocation: liveLocations[request.id],
                            showTimeline: detailed,
                            currentUserId: currentUserId,
                            isResponderView: role == 'RESPONDER',
                            onConfirmReceipt: onConfirmReceipt,
                            onDispatchAllocation: onDispatchAllocation,
                            onMarkDelivered: onMarkDelivered,
                          ))
                      .toList(),
                )
              : _table(),
    );
  }

  List<Widget> _actions(EmergencyRequest request) {
    final actions = <Widget>[];

    if (_canAccept(request)) {
      actions.add(
        FilledButton(
          onPressed: () => onAccept!(request),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.teal,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          child: const Text('Accept', style: TextStyle(fontSize: 12)),
        ),
      );
    }

    if (_canAllocate(request)) {
      actions.add(
        OutlinedButton(
          onPressed: () => onAllocate!(request),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.blue,
            side: const BorderSide(color: AppColors.blue),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          child: const Text('Allocate', style: TextStyle(fontSize: 12)),
        ),
      );
    }

    // In the detailed (card) layout the per-allocation actions live inside
    // AllocationProgressList, next to the allocation they act on.
    if (!detailed && onDispatchAllocation != null) {
      for (final allocation in _dispatchable(request)) {
        actions.add(
          OutlinedButton(
            onPressed: () => onDispatchAllocation!(allocation),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.blue,
              side: const BorderSide(color: AppColors.blue),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            child: Text('Dispatch ${allocation.resourceName}',
                style: const TextStyle(fontSize: 12)),
          ),
        );
      }
    }

    if (!detailed && onMarkDelivered != null) {
      for (final allocation in _deliverable(request)) {
        actions.add(
          FilledButton(
            onPressed: () => onMarkDelivered!(allocation),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.teal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            child: Text('Mark Delivered · ${allocation.resourceName}',
                style: const TextStyle(fontSize: 12)),
          ),
        );
      }
    }

    if (!detailed && onConfirmReceipt != null) {
      for (final allocation in _receivable(request)) {
        actions.add(
          FilledButton(
            onPressed: () => onConfirmReceipt!(allocation),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.teal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            child: Text('Confirm received ${allocation.resourceName}',
                style: const TextStyle(fontSize: 12)),
          ),
        );
      }
    }

    if (_canCancel(request)) {
      actions.add(
        OutlinedButton(
          onPressed: () => onCancelRequest!(request),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.red,
            side: const BorderSide(color: AppColors.red),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          child: const Text('Cancel', style: TextStyle(fontSize: 12)),
        ),
      );
    }

    return actions;
  }

  Widget _table() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        headingTextStyle: tableHeadStyle(),
        dataTextStyle: const TextStyle(fontSize: 13, color: AppColors.text),
        // Content-driven rows kept in the compact 68-88px band; only rows with
        // several required resources are allowed to grow a little more.
        headingRowHeight: 40,
        dataRowMinHeight: 64,
        dataRowMaxHeight: 104,
        columnSpacing: 22,
        horizontalMargin: 16,
        columns: const [
          DataColumn(label: Text('REQUEST ID')),
          DataColumn(label: Text('REQUESTER')),
          DataColumn(label: Text('EMERGENCY')),
          DataColumn(label: Text('LOCATION')),
          DataColumn(label: Text('PRIORITY')),
          DataColumn(label: Text('REQUIRED RESOURCES')),
          DataColumn(label: Text('CREATED')),
          DataColumn(label: Text('STATUS')),
          DataColumn(label: Text('RESPONDER')),
          DataColumn(label: Text('ACTION')),
        ],
        rows: requests.map((request) {
          final requester = request.requester;

          return DataRow(
            cells: [
              DataCell(Text(
                request.displayId,
                style: monoStyle(size: 12.5, color: AppColors.textDim),
              )),
              DataCell(
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      requester?.name ?? 'Unknown requester',
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: AppColors.text,
                      ),
                    ),
                    if ((requester?.email ?? '').isNotEmpty)
                      Text(
                        requester!.email!,
                        style: const TextStyle(
                            fontSize: 11, color: AppColors.textFaint),
                      ),
                    if ((requester?.phone ?? '').isNotEmpty)
                      Text(
                        requester!.phone!,
                        style: const TextStyle(
                            fontSize: 11, color: AppColors.textFaint),
                      ),
                  ],
                ),
              ),
              DataCell(
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      request.emergencyType,
                      style: const TextStyle(
                          fontSize: 12.5, fontWeight: FontWeight.w600),
                    ),
                    if (request.description.isNotEmpty)
                      SizedBox(
                        width: 190,
                        child: Text(
                          request.description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 11, color: AppColors.textFaint),
                        ),
                      ),
                  ],
                ),
              ),
              DataCell(Text(request.location)),
              DataCell(PriorityPill(priority: request.priority)),
              DataCell(
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: request.requiredResources.isEmpty
                      ? [
                          const Text('-',
                              style: TextStyle(color: AppColors.textFaint)),
                        ]
                      : request.requiredResources.map((line) {
                          final allocated =
                              request.allocatedFor(line.resourceId);

                          return ResourceChip(
                            name: line.resourceName,
                            type: line.resourceType,
                            quantity: line.quantity,
                            trailingText: allocated > 0
                                ? '$allocated allocated · ${_allocationStateText(request, line.resourceId) ?? ''}'
                                : _allocationStateText(request, line.resourceId),
                          );
                        }).toList(),
                ),
              ),
              DataCell(
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      formatDateTime(request.createdAt),
                      style: monoStyle(size: 12, color: AppColors.textDim),
                    ),
                    Text(
                      formatRelative(request.createdAt),
                      style: const TextStyle(
                          fontSize: 10.5, color: AppColors.textFaint),
                    ),
                  ],
                ),
              ),
              DataCell(StatusPill(status: request.status)),
              DataCell(
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      request.acceptedBy?.name ?? 'unassigned',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: request.acceptedBy == null
                            ? AppColors.textFaint
                            : AppColors.text,
                      ),
                    ),
                    if (request.acceptedAt != null)
                      Text(
                        'at ${formatDateTime(request.acceptedAt)}',
                        style: const TextStyle(
                            fontSize: 10.5, color: AppColors.textFaint),
                      ),
                    if ((request.acceptedBy?.phone ?? '').isNotEmpty)
                      Text(
                        request.acceptedBy!.phone!,
                        style: const TextStyle(
                            fontSize: 10.5, color: AppColors.textFaint),
                      ),
                    if (liveLocations[request.id] != null)
                      Text(
                        '${liveLocations[request.id]!.isLive ? 'LIVE' : 'LAST'} · ${liveLocations[request.id]!.latitude.toStringAsFixed(5)}, ${liveLocations[request.id]!.longitude.toStringAsFixed(5)}',
                        style: TextStyle(
                          fontSize: 10.5,
                          color: liveLocations[request.id]!.isLive
                              ? AppColors.teal
                              : AppColors.textFaint,
                        ),
                      ),
                  ],
                ),
              ),
              DataCell(
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: _actions(request).isEmpty
                      ? [
                          const Text('-',
                              style: TextStyle(color: AppColors.textFaint)),
                        ]
                      : _actions(request),
                ),
              ),
            ],
          );
        }).toList(),
      ),
    );
  }
}

class _RequestCard extends StatelessWidget {
  const _RequestCard({
    required this.request,
    required this.actions,
    this.liveLocation,
    this.showTimeline = false,
    this.currentUserId,
    this.isResponderView = false,
    this.onConfirmReceipt,
    this.onDispatchAllocation,
    this.onMarkDelivered,
  });

  final EmergencyRequest request;
  final List<Widget> actions;
  final LiveResponderLocation? liveLocation;
  final bool showTimeline;
  final int? currentUserId;
  final bool isResponderView;
  final void Function(AllocationLine allocation)? onConfirmReceipt;
  final void Function(AllocationLine allocation)? onDispatchAllocation;
  final void Function(AllocationLine allocation)? onMarkDelivered;

  @override
  Widget build(BuildContext context) {
    final requester = request.requester;
    final unfinishedCount = request.allocations
        .where((allocation) =>
            allocation.isActive &&
            (allocation.isReserved || allocation.isDispatched) &&
            (!isResponderView || allocation.responderId == currentUserId))
        .length;
    final blockedByUnfinishedWork = isResponderView && unfinishedCount > 0;
    String? allocationStateText(int resourceId) {
      final statuses = request.allocations
          .where((allocation) => allocation.resourceId == resourceId)
          .map((allocation) => allocation.status)
          .toSet()
          .join(' / ');
      return statuses.isEmpty ? null : statuses;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                request.displayId,
                style: monoStyle(
                    size: 12.5,
                    color: AppColors.textDim,
                    weight: FontWeight.w600),
              ),
              const SizedBox(width: 8),
              StatusPill(status: request.status),
              const Spacer(),
              PriorityPill(priority: request.priority),
            ],
          ),
          if (showTimeline) ...[
            const SizedBox(height: 10),
            RequestTimeline(request: request, dense: true),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: InfoChip(
                  label: 'Requester',
                  value: requester?.name ?? 'Unknown requester',
                ),
              ),
              Expanded(
                child: InfoChip(label: 'Location', value: request.location),
              ),
            ],
          ),
          if ((requester?.email ?? '').isNotEmpty ||
              (requester?.phone ?? '').isNotEmpty) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: InfoChip(
                      label: 'Email', value: requester?.email ?? '-'),
                ),
                Expanded(
                  child: InfoChip(
                      label: 'Phone', value: requester?.phone ?? '-'),
                ),
              ],
            ),
          ],
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: InfoChip(
                    label: 'Emergency', value: request.emergencyType),
              ),
              Expanded(
                child: InfoChip(
                  label: 'Created',
                  value: formatRelative(request.createdAt),
                ),
              ),
            ],
          ),
          if (request.description.isNotEmpty) ...[
            const SizedBox(height: 6),
            InfoChip(label: 'Details', value: request.description),
          ],
          const SizedBox(height: 8),
          const Text(
            'REQUIRED RESOURCES',
            style: TextStyle(
                fontSize: 9.5, color: AppColors.textFaint, letterSpacing: .5),
          ),
          const SizedBox(height: 4),
          if (request.requiredResources.isEmpty)
            const Text('-',
                style: TextStyle(fontSize: 12.5, color: AppColors.textFaint))
          else
            ...request.requiredResources.map(
              (line) => ResourceChip(
                name: line.resourceName,
                type: line.resourceType,
                quantity: line.quantity,
                trailingText: request.allocatedFor(line.resourceId) > 0
                    ? '${request.allocatedFor(line.resourceId)} allocated · ${allocationStateText(line.resourceId) ?? ''}'
                    : allocationStateText(line.resourceId),
              ),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: InfoChip(
                  label: 'Responder',
                  value: request.acceptedBy?.name ?? 'unassigned',
                ),
              ),
              Expanded(
                child: InfoChip(
                  label: 'Accepted',
                  value: request.acceptedAt == null
                      ? '-'
                      : formatDateTime(request.acceptedAt),
                ),
              ),
            ],
          ),
          if (liveLocation != null) ...[
            const SizedBox(height: 6),
            InfoChip(
              label: liveLocation!.isLive
                  ? 'Live responder position'
                  : 'Last responder position',
              value:
                  '${liveLocation!.latitude.toStringAsFixed(5)}, ${liveLocation!.longitude.toStringAsFixed(5)} · updated ${formatDateTime(liveLocation!.updatedAt)}',
            ),
          ],
          if (showTimeline) ...[
            const SizedBox(height: 10),
            const Text(
              'ALLOCATIONS',
              style: TextStyle(
                  fontSize: 9.5, color: AppColors.textFaint, letterSpacing: .5),
            ),
            const SizedBox(height: 4),
            AllocationProgressList(
              request: request,
              currentUserId: currentUserId,
              isResponderView: isResponderView,
              onConfirmReceipt: onConfirmReceipt,
              onDispatch: onDispatchAllocation,
              onMarkDelivered: onMarkDelivered,
            ),
            if (blockedByUnfinishedWork) ...[
              const SizedBox(height: 4),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: AppColors.amberDim,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: AppColors.amber.withValues(alpha: .4)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.hourglass_bottom_rounded,
                        size: 15, color: AppColors.amber),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '$unfinishedCount allocation${unfinishedCount == 1 ? '' : 's'} still unfinished. '
                        'You stay BUSY until every one of them is delivered.',
                        style: const TextStyle(
                            fontSize: 11.5, color: AppColors.amber),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: actions),
          ],
        ],
      ),
    );
  }
}
