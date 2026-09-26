import 'package:flutter/material.dart';

import '../Services/socket_service.dart';
import '../models/eras_models.dart';
import '../theme/app_theme.dart';
import 'common_widgets.dart';
import 'operational_status.dart';

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
    this.onStartLocationSharing,
    this.onStopLocationSharing,
    this.liveLocations = const <int, LiveResponderLocation>{},
    this.activelySharingRequestIds = const <int>{},
    this.sharingRequestId,
    this.connectionStatus = RealtimeConnectionStatus.offline,
    this.isMobile = false,
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
  final Future<void> Function(EmergencyRequest request)? onStartLocationSharing;
  final Future<void> Function(int? requestId)? onStopLocationSharing;
  final Map<int, LiveResponderLocation> liveLocations;
  final Set<int> activelySharingRequestIds;
  final int? sharingRequestId;
  final RealtimeConnectionStatus connectionStatus;
  final bool isMobile;

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

  Widget _locationCell(EmergencyRequest request) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 180,
          child: Text(
            request.location,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (request.coordinateLabel != null)
          Text(
            request.coordinateLabel!,
            style: monoStyle(size: 10.5, color: AppColors.textFaint),
          )
        else
          const Text(
            'No precise coordinates',
            style: TextStyle(fontSize: 10.5, color: AppColors.textFaint),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Panel(
      title: title,
      hint: isMobile ? '' : hint,
      child: requests.isEmpty
          ? EmptyState(emptyMessage, title: emptyTitle, icon: emptyIcon)
          : isMobile
              ? Column(
                  children: requests
                      .map((request) => _RequestCard(
                            request: request,
                            actions: _actions(request),
                            liveLocation: liveLocations[request.id],
                            isActivelySharing:
                                activelySharingRequestIds.contains(request.id),
                            connectionStatus: connectionStatus,
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

    if (onDispatchAllocation != null) {
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
            child: Text('Confirm & Dispatch · ${allocation.resourceName}',
                style: const TextStyle(fontSize: 12)),
          ),
        );
      }
    }

    if (onMarkDelivered != null) {
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

    if (onConfirmReceipt != null) {
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

    final assignedToCurrentResponder =
        role == 'RESPONDER' &&
        request.acceptedBy?.id == currentUserId &&
        request.isOpen;
    if (assignedToCurrentResponder && onStartLocationSharing != null) {
      final isSharing = sharingRequestId == request.id ||
          activelySharingRequestIds.contains(request.id);
      actions.add(
        isSharing && onStopLocationSharing != null
            ? OutlinedButton(
                onPressed: () => onStopLocationSharing!(request.id),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.amber,
                  side: const BorderSide(color: AppColors.amber),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
                child: const Text('Stop Live Location',
                    style: TextStyle(fontSize: 12)),
              )
            : FilledButton(
                onPressed: connectionStatus == RealtimeConnectionStatus.connected
                    ? () => onStartLocationSharing!(request)
                    : null,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.blue,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
                child: const Text('Start Live Location',
                    style: TextStyle(fontSize: 12)),
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
        dataRowMinHeight: 104,
        dataRowMaxHeight: 220,
        columnSpacing: 22,
        horizontalMargin: 16,
        columns: const [
          DataColumn(label: Text('REQUEST ID')),
          DataColumn(label: Text('REQUESTER')),
          DataColumn(label: Text('EMERGENCY')),
          DataColumn(label: Text('LOCATION')),
          DataColumn(label: Text('PRIORITY')),
          DataColumn(label: Text('RESOURCES / ALLOCATIONS')),
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
                    if (request.description != null && request.description!.isNotEmpty)
                      SizedBox(
                        width: 190,
                        child: Text(
                          request.description!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 11, color: AppColors.textFaint),
                        ),
                      ),
                  ],
                ),
              ),
              DataCell(_locationCell(request)),
              DataCell(PriorityPill(priority: request.priority)),
              DataCell(
                SizedBox(
                  width: 310,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      if (request.requiredResources.isEmpty)
                        const Text('-',
                            style: TextStyle(color: AppColors.textFaint))
                      else
                        ...request.requiredResources.map((line) {
                          final allocated = request.allocatedFor(line.resourceId);
                          return ResourceChip(
                            name: line.resourceName,
                            type: line.resourceType,
                            quantity: line.quantity,
                            trailingText: allocated > 0
                                ? '$allocated allocated'
                                : _allocationStateText(request, line.resourceId),
                          );
                        }),
                      if (request.allocations.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        const Divider(height: 1, color: AppColors.border),
                        const SizedBox(height: 3),
                        ...request.allocations.map(
                          (allocation) => AllocationOperationalRow(
                            allocation: allocation,
                            compact: true,
                          ),
                        ),
                      ],
                    ],
                  ),
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
              DataCell(
                SizedBox(
                  width: 430,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      StatusPill(status: request.status),
                      const SizedBox(height: 8),
                      OperationalTimeline(request: request, compact: true),
                    ],
                  ),
                ),
              ),
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
                    if (activelySharingRequestIds.contains(request.id) ||
                        liveLocations[request.id] != null)
                      LocationSharingSummary(
                        isActive:
                            activelySharingRequestIds.contains(request.id),
                        location: liveLocations[request.id],
                        connectionStatus: connectionStatus,
                        compact: true,
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
    required this.isActivelySharing,
    required this.connectionStatus,
    this.liveLocation,
  });

  final EmergencyRequest request;
  final List<Widget> actions;
  final LiveResponderLocation? liveLocation;
  final bool isActivelySharing;
  final RealtimeConnectionStatus connectionStatus;

  @override
  Widget build(BuildContext context) {
    final requester = request.requester;
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
          const SizedBox(height: 10),
          OperationalTimeline(request: request),
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
          const SizedBox(height: 6),
          InfoChip(
            label: 'Coordinates',
            value: request.coordinateLabel ?? 'No precise coordinates',
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
          if (request.description != null && request.description!.isNotEmpty) ...[
            const SizedBox(height: 6),
            InfoChip(label: 'Details', value: request.description!),
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
          if (request.allocations.isNotEmpty) ...[
            const SizedBox(height: 10),
            const Text(
              'ALLOCATIONS',
              style: TextStyle(
                fontSize: 9.5,
                color: AppColors.textFaint,
                letterSpacing: .5,
              ),
            ),
            const SizedBox(height: 4),
            ...request.allocations.map(
              (allocation) => AllocationOperationalRow(
                allocation: allocation,
              ),
            ),
          ],
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
          if (isActivelySharing || liveLocation != null) ...[
            const SizedBox(height: 8),
            LocationSharingSummary(
              isActive: isActivelySharing,
              location: liveLocation,
              connectionStatus: connectionStatus,
            ),
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
