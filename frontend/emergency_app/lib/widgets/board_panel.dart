import 'package:flutter/material.dart';

import '../models/eras_models.dart';
import '../services/api_service.dart';
import '../services/email_privacy.dart';
import '../services/socket_service.dart';
import '../theme/app_theme.dart';
import 'auth_motion.dart';
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
    this.onViewRequest,
    this.onEditRequest,
    this.onAssignRequest,
    this.onAccept,
    this.onStartResponse,
    this.onCompleteResponse,
    this.onAllocate,
    this.onEndAssignment,
    this.onCancelRequest,
    this.onDispatchAllocation,
    this.onMarkDelivered,
    this.onConfirmReceipt,
    this.onStartLocationSharing,
    this.onStopLocationSharing,
    this.liveLocations = const <int, Map<int, LiveResponderLocation>>{},
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
  final void Function(EmergencyRequest request)? onViewRequest;
  final void Function(EmergencyRequest request)? onEditRequest;
  final void Function(EmergencyRequest request)? onAssignRequest;
  final void Function(EmergencyRequest request)? onAccept;
  final void Function(EmergencyRequest request)? onStartResponse;
  final void Function(EmergencyRequest request)? onCompleteResponse;

  /// LEGACY allocation workflow hooks. Leave them null (the normal responder
  /// console does) and no Allocate / Dispatch / Delivered control is rendered.
  final void Function(EmergencyRequest request)? onAllocate;
  final void Function(EmergencyRequest request)? onEndAssignment;
  final void Function(EmergencyRequest request)? onCancelRequest;
  final void Function(AllocationLine allocation)? onDispatchAllocation;
  final void Function(AllocationLine allocation)? onMarkDelivered;
  final void Function(AllocationLine allocation)? onConfirmReceipt;
  final Future<void> Function(EmergencyRequest request)? onStartLocationSharing;
  final Future<void> Function(int? requestId)? onStopLocationSharing;

  /// Multi-responder live points: requestId -> responderId -> latest point.
  final Map<int, Map<int, LiveResponderLocation>> liveLocations;
  final Set<int> activelySharingRequestIds;
  final int? sharingRequestId;
  final RealtimeConnectionStatus connectionStatus;
  final bool isMobile;

  bool _canAccept(EmergencyRequest request) =>
      role == 'RESPONDER' &&
      request.isOpen &&
      !request.isFullyAllocated &&
      onAccept != null;

  // Normal responder workflow for EVERY emergency, resource-free or
  // resource-bearing: Accept -> START RESPONSE -> COMPLETE RESPONSE. The
  // requested resources are matched server-side at acceptance; starting and
  // completing never depend on required resources or Allocation rows.
  bool _canStartResponse(EmergencyRequest request) =>
      role == 'RESPONDER' &&
      request.status == RequestStatus.accepted &&
      currentUserId != null &&
      (request.isAssignedTo(currentUserId!) ||
          request.isLegacyAcceptedBy(currentUserId!)) &&
      onStartResponse != null;

  bool _canCompleteResponse(EmergencyRequest request) =>
      role == 'RESPONDER' &&
      request.status == RequestStatus.inProgress &&
      currentUserId != null &&
      (request.isAssignedTo(currentUserId!) ||
          request.isLegacyAcceptedBy(currentUserId!)) &&
      onCompleteResponse != null;

  // LEGACY allocation controls (Allocate / Confirm & Dispatch / Mark
  // Delivered). They render ONLY when a caller explicitly wires the matching
  // callback; the normal responder console never does, so the normal
  // responder workflow contains just Accept -> Start Response -> Complete
  // Response. Kept for compatibility/history views only.
  //  - Allocate: RESPONDER who PARTICIPATES (ACTIVE assignment, an
  //    unfinished allocation of theirs, or the legacy acceptedBy lead) -
  //    the same rule the backend authorizes. Only for resource-bearing requests.
  bool _canAllocate(EmergencyRequest request) =>
      role == 'RESPONDER' &&
      request.requiredResources.isNotEmpty &&
      onAllocate != null &&
      request.participatesAsResponder(currentUserId) &&
      request.isOpen &&
      !request.isFullyAllocated;

  bool _canEndAssignment(EmergencyRequest request) =>
      role == 'RESPONDER' &&
      currentUserId != null &&
      request.isAssignedTo(currentUserId!) &&
      onEndAssignment != null;

  bool _canEdit(EmergencyRequest request) =>
      role == 'REQUESTER' &&
      request.status == RequestStatus.pending &&
      onEditRequest != null;

  bool _canAdminAssign(EmergencyRequest request) =>
      role == 'ADMIN' &&
      request.status == RequestStatus.pending &&
      onAssignRequest != null;

  bool _canCancel(EmergencyRequest request) =>
      (role == 'REQUESTER' || role == 'ADMIN') &&
      onCancelRequest != null &&
      request.isOpen;

  List<AllocationLine> _dispatchable(EmergencyRequest request) =>
      request.allocations
          .where((allocation) =>
              role == 'RESPONDER' &&
              allocation.responderId == currentUserId &&
              allocation.isReserved)
          .toList(growable: false);

  // Responder-side delivery fallback: the responder may complete their own
  // DISPATCHED allocation when the requester never confirms receipt.
  List<AllocationLine> _deliverable(EmergencyRequest request) => request
      .allocations
      .where((allocation) =>
          role == 'RESPONDER' &&
          allocation.responderId == currentUserId &&
          allocation.isDispatched)
      .toList(growable: false);

  List<AllocationLine> _receivable(EmergencyRequest request) =>
      request.allocations
          .where((allocation) => role == 'REQUESTER' && allocation.isDispatched)
          .toList(growable: false);

  String? _allocationStateText(EmergencyRequest request, int resourceId) {
    final statuses = request.allocations
        .where((allocation) => allocation.resourceId == resourceId)
        .map((allocation) => allocation.status)
        .toSet()
        .join(' / ');
    return statuses.isEmpty ? null : statuses;
  }

  Widget _locationCell(EmergencyRequest request, ErasPalette p) {
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
            style: TextStyle(color: p.text),
          ),
        ),
        if (request.coordinateLabel != null)
          Text(
            request.coordinateLabel!,
            style: monoStyle(size: 10.5, color: p.textFaint),
          )
        else
          Text(
            'No precise coordinates',
            style: TextStyle(fontSize: 10.5, color: p.textFaint),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = ErasPalette.of(context);

    return Panel(
      title: title,
      hint: isMobile ? '' : hint,
      child: requests.isEmpty
          ? EmptyState(emptyMessage, title: emptyTitle, icon: emptyIcon)
          : isMobile
              ? Column(
                  children: [
                    for (var i = 0; i < requests.length; i++)
                      EntranceReveal(
                        delay: i < 5
                            ? Duration(milliseconds: 28 * i)
                            : Duration.zero,
                        offset: const Offset(0, 6),
                        child: _RequestCard(
                          request: requests[i],
                          actions: _actions(requests[i], p),
                          liveLocations: liveLocations[requests[i].id] ??
                              const <int, LiveResponderLocation>{},
                          connectionStatus: connectionStatus,
                        ),
                      ),
                  ],
                )
              : _table(context, p),
    );
  }

  List<Widget> _actions(EmergencyRequest request, ErasPalette p) {
    final actions = <Widget>[];

    if (onViewRequest != null) {
      actions.add(
        PressableScale(
          child: OutlinedButton(
            key: Key('view-request-${request.id}'),
            onPressed: () => onViewRequest!(request),
            style: OutlinedButton.styleFrom(
              backgroundColor: p.dark ? p.surface2 : Colors.transparent,
              foregroundColor: p.textDim,
              side: BorderSide(color: p.border),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
            child: const Text('VIEW', style: TextStyle(fontSize: 12)),
          ),
        ),
      );
    }

    if (_canAdminAssign(request)) {
      actions.add(
        PressableScale(
          child: FilledButton(
            key: Key('assign-request-${request.id}'),
            onPressed: () => onAssignRequest!(request),
            style: FilledButton.styleFrom(
              backgroundColor: p.teal,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
            child: const Text(
              'ACCEPT / ASSIGN',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ),
      );
    }

    if (_canEdit(request)) {
      actions.add(
        PressableScale(
          child: OutlinedButton(
            key: Key('edit-request-${request.id}'),
            onPressed: () => onEditRequest!(request),
            style: OutlinedButton.styleFrom(
              backgroundColor: p.dark ? p.surface2 : Colors.transparent,
              foregroundColor: p.blue,
              side: BorderSide(color: p.blue),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
            child: const Text('EDIT', style: TextStyle(fontSize: 12)),
          ),
        ),
      );
    }

    if (_canAccept(request)) {
      actions.add(
        PressableScale(
          child: FilledButton(
            onPressed: () => onAccept!(request),
            style: FilledButton.styleFrom(
              backgroundColor: p.teal,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            child: const Text('Accept', style: TextStyle(fontSize: 12)),
          ),
        ),
      );
    }

    if (_canStartResponse(request)) {
      actions.add(
        PressableScale(
          child: FilledButton(
            onPressed: () => onStartResponse!(request),
            style: FilledButton.styleFrom(
              backgroundColor: p.teal,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            child: const Text(
              'START RESPONSE',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ),
      );
    }

    if (_canCompleteResponse(request)) {
      // Active response: the status pill already reads IN PROGRESS; surface
      // this device's live-location state next to the completion control.
      // ON/OFF reflects the real local sharing state (permission + stream),
      // never a guess - another responder's stream never turns it ON.
      actions.add(
        Container(
          key: Key('location-sharing-state-${request.id}'),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: p.surface2,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: p.border),
          ),
          child: Text(
            'Location sharing: '
            '${sharingRequestId == request.id ? 'ON' : 'OFF'}',
            style: monoStyle(
              size: 11,
              color: sharingRequestId == request.id ? p.teal : p.textDim,
              weight: FontWeight.w600,
            ),
          ),
        ),
      );
      actions.add(
        PressableScale(
          child: FilledButton(
            onPressed: () => onCompleteResponse!(request),
            style: FilledButton.styleFrom(
              backgroundColor: p.teal,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            child: const Text(
              'COMPLETE RESPONSE',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ),
      );
    }

    if (_canAllocate(request)) {
      actions.add(
        PressableScale(
          child: OutlinedButton(
            onPressed: () => onAllocate!(request),
            style: OutlinedButton.styleFrom(
              backgroundColor: p.dark ? p.surface2 : Colors.transparent,
              foregroundColor: p.blue,
              side: BorderSide(color: p.blue),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            child: const Text('Allocate', style: TextStyle(fontSize: 12)),
          ),
        ),
      );
    }

    if (_canEndAssignment(request)) {
      actions.add(
        PressableScale(
          child: OutlinedButton(
            onPressed: () => onEndAssignment!(request),
            style: OutlinedButton.styleFrom(
              backgroundColor: p.dark ? p.surface2 : Colors.transparent,
              foregroundColor: p.amber,
              side: BorderSide(color: p.amber),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
            child: const Text(
              'End Assignment',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ),
      );
    }

    if (onDispatchAllocation != null) {
      for (final allocation in _dispatchable(request)) {
        actions.add(
          PressableScale(
            child: OutlinedButton(
              onPressed: () => onDispatchAllocation!(allocation),
              style: OutlinedButton.styleFrom(
                backgroundColor: p.dark ? p.surface2 : Colors.transparent,
                foregroundColor: p.blue,
                side: BorderSide(color: p.blue),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              child: Text('Confirm & Dispatch · ${allocation.resourceName}',
                  style: const TextStyle(fontSize: 12)),
            ),
          ),
        );
      }
    }

    if (onMarkDelivered != null) {
      for (final allocation in _deliverable(request)) {
        actions.add(
          PressableScale(
            child: FilledButton(
              onPressed: () => onMarkDelivered!(allocation),
              style: FilledButton.styleFrom(
                backgroundColor: p.teal,
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              child: Text('Mark Delivered · ${allocation.resourceName}',
                  style: const TextStyle(fontSize: 12)),
            ),
          ),
        );
      }
    }

    if (onConfirmReceipt != null) {
      for (final allocation in _receivable(request)) {
        actions.add(
          PressableScale(
            child: FilledButton(
              onPressed: () => onConfirmReceipt!(allocation),
              style: FilledButton.styleFrom(
                backgroundColor: p.teal,
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              child: Text('Confirm received ${allocation.resourceName}',
                  style: const TextStyle(fontSize: 12)),
            ),
          ),
        );
      }
    }

    if (_canCancel(request)) {
      actions.add(
        PressableScale(
          child: OutlinedButton(
            key: Key('cancel-request-${request.id}'),
            onPressed: () => onCancelRequest!(request),
            style: OutlinedButton.styleFrom(
              backgroundColor:
                  p.dark ? p.redDim.withValues(alpha: .45) : Colors.transparent,
              foregroundColor: p.red,
              side: BorderSide(color: p.red),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            child: const Text('CANCEL REQUEST', style: TextStyle(fontSize: 12)),
          ),
        ),
      );
    }

    // Live-location gate: any responder the backend would authorize
    // (participation rule) may stream, not only the acceptedBy lead.
    final currentResponderParticipates = role == 'RESPONDER' &&
        request.participatesAsResponder(currentUserId) &&
        request.status == RequestStatus.inProgress;
    if (currentResponderParticipates && onStartLocationSharing != null) {
      // Another responder streaming this request must not turn this device's
      // action into "Stop". Local sharing is isolated by authenticated
      // responder identity; remote stream state is display-only.
      final isSharing = sharingRequestId == request.id;
      actions.add(
        isSharing && onStopLocationSharing != null
            ? PressableScale(
                child: OutlinedButton(
                  onPressed: () => onStopLocationSharing!(request.id),
                  style: OutlinedButton.styleFrom(
                    backgroundColor: p.dark ? p.surface2 : Colors.transparent,
                    foregroundColor: p.amber,
                    side: BorderSide(color: p.amber),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                  child: const Text('Stop Live Location',
                      style: TextStyle(fontSize: 12)),
                ),
              )
            : PressableScale(
                child: FilledButton(
                  onPressed:
                      connectionStatus == RealtimeConnectionStatus.connected
                          ? () => onStartLocationSharing!(request)
                          : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: p.blue,
                    foregroundColor: Colors.white,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                  child: const Text('Start Live Location',
                      style: TextStyle(fontSize: 12)),
                ),
              ),
      );
    }

    return actions;
  }

  Widget _table(BuildContext context, ErasPalette p) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        headingTextStyle: tableHeadStyle(context),
        dataTextStyle: TextStyle(fontSize: 13, color: p.text),
        headingRowColor: WidgetStatePropertyAll(
          p.dark ? p.surface2.withValues(alpha: .42) : Colors.transparent,
        ),
        // Rows are content-driven. Multi-responder emergencies can contain
        // several participant/contact/location rows, so the desktop ceiling
        // must accommodate 3+ responders instead of clipping a fixed card.
        headingRowHeight: 40,
        dataRowMinHeight: 104,
        dataRowMaxHeight: 520,
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
          final rowActions = _actions(request, p);

          return DataRow(
            cells: [
              DataCell(Text(
                request.displayId,
                style: monoStyle(size: 12.5, color: p.textDim),
              )),
              DataCell(
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      requester?.name ?? 'Unknown requester',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: p.text,
                      ),
                    ),
                    if ((requester?.email ?? '').isNotEmpty)
                      Text(
                        // A requester's address is shared with the responders
                        // working their emergency, but never in full: only the
                        // signed-in owner keeps their own value readable.
                        displayEmailForOthers(
                          requester!.email,
                          isOwnAccount: requester!.id == currentUserId,
                        ),
                        style: TextStyle(fontSize: 11, color: p.textFaint),
                      ),
                    if ((requester?.phone ?? '').isNotEmpty)
                      Text(
                        requester!.phone!,
                        style: TextStyle(fontSize: 11, color: p.textFaint),
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
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: p.text,
                      ),
                    ),
                    if (request.description != null &&
                        request.description!.isNotEmpty)
                      SizedBox(
                        width: 190,
                        child: Text(
                          request.description!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: p.textFaint),
                        ),
                      ),
                  ],
                ),
              ),
              DataCell(_locationCell(request, p)),
              DataCell(PriorityPill(priority: request.priority)),
              DataCell(
                SizedBox(
                  width: 310,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      if (request.requiredResources.isEmpty)
                        Text('-', style: TextStyle(color: p.textFaint))
                      else
                        ...request.requiredResources.map((line) {
                          final allocated =
                              request.allocatedFor(line.resourceId);
                          return ResourceChip(
                            name: line.resourceName,
                            type: line.resourceType,
                            quantity: line.quantity,
                            trailingText: allocated > 0
                                ? '$allocated allocated'
                                : _allocationStateText(
                                    request, line.resourceId),
                          );
                        }),
                      if (request.allocations.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Divider(height: 1, color: p.border),
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
                      style: monoStyle(size: 12, color: p.textDim),
                    ),
                    Text(
                      formatRelative(request.createdAt),
                      style: TextStyle(fontSize: 10.5, color: p.textFaint),
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
                SizedBox(
                  width: 210,
                  child: _RespondersCell(
                    request: request,
                    liveLocations: liveLocations[request.id] ??
                        const <int, LiveResponderLocation>{},
                    connectionStatus: connectionStatus,
                    compact: true,
                  ),
                ),
              ),
              DataCell(
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: rowActions.isEmpty
                      ? [
                          Text('-', style: TextStyle(color: p.textFaint)),
                        ]
                      : rowActions,
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
    required this.connectionStatus,
    this.liveLocations = const <int, LiveResponderLocation>{},
  });

  final EmergencyRequest request;
  final List<Widget> actions;

  /// This request's live points, one entry per responder.
  final Map<int, LiveResponderLocation> liveLocations;
  final RealtimeConnectionStatus connectionStatus;

  @override
  Widget build(BuildContext context) {
    final p = ErasPalette.of(context);
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
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: p.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final requestId = Text(
                request.displayId,
                style: monoStyle(
                  size: 12.5,
                  color: p.textDim,
                  weight: FontWeight.w600,
                ),
              );
              final status = StatusPill(status: request.status);
              final priority = PriorityPill(priority: request.priority);
              if (constraints.maxWidth < 360) {
                return Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [requestId, status, priority],
                );
              }
              return Row(
                children: [
                  requestId,
                  const SizedBox(width: 8),
                  status,
                  const Spacer(),
                  priority,
                ],
              );
            },
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
                    label: 'Email',
                    value: displayEmailForOthers(
                      requester?.email,
                      isOwnAccount: requester?.id == ApiService.currentUserId,
                      fallback: '-',
                    ),
                  ),
                ),
                Expanded(
                  child:
                      InfoChip(label: 'Phone', value: requester?.phone ?? '-'),
                ),
              ],
            ),
          ],
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child:
                    InfoChip(label: 'Emergency', value: request.emergencyType),
              ),
              Expanded(
                child: InfoChip(
                  label: 'Created',
                  value: formatRelative(request.createdAt),
                ),
              ),
            ],
          ),
          if (request.description != null &&
              request.description!.isNotEmpty) ...[
            const SizedBox(height: 6),
            InfoChip(label: 'Details', value: request.description!),
          ],
          const SizedBox(height: 8),
          Text(
            'REQUIRED RESOURCES',
            style:
                TextStyle(fontSize: 9.5, color: p.textFaint, letterSpacing: .5),
          ),
          const SizedBox(height: 4),
          if (request.requiredResources.isEmpty)
            Text('-', style: TextStyle(fontSize: 12.5, color: p.textFaint))
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
            Text(
              'ALLOCATIONS',
              style: TextStyle(
                fontSize: 9.5,
                color: p.textFaint,
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
                  label: 'Lead responder',
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
          _RespondersCell(
            request: request,
            liveLocations: liveLocations,
            connectionStatus: connectionStatus,
          ),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: actions),
          ],
        ],
      ),
    );
  }
}

/// PHASE F multi-responder summary: lead responder (preserved acceptedBy
/// semantics) plus every additional ACTIVE assignment, with per-responder
/// live-location rows. ENDED assignments are history and never render as
/// active work (Part 15); terminal requests rely on their status pill for
/// the active/over distinction instead of inventing client-side lifecycle.
class _RespondersCell extends StatelessWidget {
  const _RespondersCell({
    required this.request,
    required this.liveLocations,
    required this.connectionStatus,
    this.compact = false,
  });

  final EmergencyRequest request;
  final Map<int, LiveResponderLocation> liveLocations;
  final RealtimeConnectionStatus connectionStatus;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final p = ErasPalette.of(context);
    final lead = request.acceptedBy;
    final leadId = lead?.id ?? request.acceptedById;
    final additional = request.additionalActiveAssignments;
    final activeIds = request.activeParticipantResponderIds;
    final leadIsActive = leadId != null && activeIds.contains(leadId);
    final leadHasActiveAssignment =
        leadId != null && request.isAssignedTo(leadId);
    final leadIsLegacyActive =
        leadId != null && request.isLegacyAcceptedBy(leadId);
    final leadHasAllocationOnlyParticipation = leadId != null &&
        !leadHasActiveAssignment &&
        !leadIsLegacyActive &&
        request.ownsUnfinishedAllocation(leadId);
    final allocationOnly = <int, AllocationLine>{};
    for (final allocation in request.allocations) {
      if (!(allocation.isReserved || allocation.isDispatched) ||
          request.isAssignedTo(allocation.responderId) ||
          allocation.responderId == leadId) {
        continue;
      }
      allocationOnly.putIfAbsent(allocation.responderId, () => allocation);
    }

    String? displayName(int responderId) {
      final assignment = firstWhereOrNull(
        request.activeAssignments,
        (row) => row.responderId == responderId,
      );
      return assignment?.responder?.name ??
          (lead?.id == responderId ? lead!.name : null);
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${activeIds.length} active responder${activeIds.length == 1 ? '' : 's'}',
          style: TextStyle(fontSize: 10.5, color: p.textFaint),
        ),
        if (lead != null) ...[
          Text(
            lead.name,
            style: TextStyle(
              fontSize: 12.5,
              color: leadIsActive ? p.text : p.textFaint,
            ),
          ),
          Text(
            leadHasActiveAssignment || leadIsLegacyActive
                ? 'LEAD · ACTIVE${request.acceptedAt == null ? '' : ' · at ${formatDateTime(request.acceptedAt)}'}'
                : leadHasAllocationOnlyParticipation
                    ? 'LEAD · ASSIGNMENT ENDED · ALLOCATION ACTIVE'
                    : 'HISTORICAL LEAD · ENDED',
            style: TextStyle(fontSize: 10.5, color: p.textFaint),
          ),
          // RESPONDER CONTACT PRIVACY: the backend already omits responder
          // email/phone for non-admin viewers; this gate keeps a direct widget
          // test or a future payload change from rendering them either.
          if (ApiService.isAdmin && (lead.phone ?? '').isNotEmpty)
            Text(
              lead.phone!,
              style: TextStyle(fontSize: 10.5, color: p.textFaint),
            ),
          if ((lead.responderStatus ?? '').isNotEmpty)
            Text(
              'STATUS · ${lead.responderStatus}',
              style: TextStyle(fontSize: 10.5, color: p.textFaint),
            ),
        ] else
          Text(
            'unassigned',
            style: TextStyle(fontSize: 12.5, color: p.textFaint),
          ),
        for (final assignment in additional) ...[
          const SizedBox(height: 4),
          Text(
            assignment.responder?.name ??
                'Responder #${assignment.responderId}',
            style: TextStyle(
              fontSize: 12.5,
              color: p.text,
            ),
          ),
          Text(
            'ASSIGNED · ${assignment.status}',
            style: TextStyle(fontSize: 10.5, color: p.textFaint),
          ),
          if ((assignment.responder?.responderStatus ?? '').isNotEmpty)
            Text(
              'STATUS · ${assignment.responder!.responderStatus}',
              style: TextStyle(fontSize: 10.5, color: p.textFaint),
            ),
          if (ApiService.isAdmin &&
              (assignment.responder?.phone ?? '').isNotEmpty)
            Text(
              assignment.responder!.phone!,
              style: TextStyle(fontSize: 10.5, color: p.textFaint),
            ),
        ],
        for (final entry in allocationOnly.entries) ...[
          const SizedBox(height: 4),
          Text(
            entry.value.responderName ?? 'Responder #${entry.key}',
            style: TextStyle(fontSize: 12.5, color: p.text),
          ),
          Text(
            'ALLOCATION · ACTIVE',
            style: TextStyle(fontSize: 10.5, color: p.textFaint),
          ),
        ],
        for (final entry in liveLocations.entries)
          if (request.participatesAsResponder(entry.key)) ...[
            const SizedBox(height: 4),
            LocationSharingSummary(
              // Per-responder activeness comes from that responder's own
              // stream state - one responder sharing must never light up
              // another responder's stale point.
              isActive: entry.value.isLive,
              location: entry.value,
              connectionStatus: connectionStatus,
              compact: compact,
              responderLabel:
                  displayName(entry.key) ?? 'Responder #${entry.key}',
            ),
          ],
      ],
    );
  }
}
