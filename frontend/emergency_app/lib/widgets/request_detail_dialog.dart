import 'package:flutter/material.dart';

import '../models/eras_models.dart';
import '../theme/app_theme.dart';
import 'common_widgets.dart';
import 'operational_status.dart';

/// Opens the same database-backed request detail view for requester, admin and
/// responder boards/logs. Callers decide whether the signed-in role is allowed
/// to see a request; this widget never fetches or broadens authorization.
Future<void> showRequestDetailDialog(
  BuildContext context,
  EmergencyRequest request,
) {
  return showDialog<void>(
    context: context,
    builder: (_) => RequestDetailDialog(request: request),
  );
}

class RequestDetailDialog extends StatelessWidget {
  const RequestDetailDialog({super.key, required this.request});

  final EmergencyRequest request;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      key: const Key('request-detail-dialog'),
      backgroundColor: AppColors.surface,
      insetPadding: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: AppColors.border),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 880, maxHeight: size.height * .9),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 10, 14),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'REQUEST DETAILS',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            letterSpacing: .8,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          request.displayId,
                          key: const Key('request-detail-id'),
                          style: monoStyle(size: 12, color: AppColors.textDim),
                        ),
                      ],
                    ),
                  ),
                  StatusPill(status: request.status),
                  IconButton(
                    tooltip: 'Close request details',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: AppColors.border),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: _RequestDetailBody(request: request),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RequestDetailBody extends StatelessWidget {
  const _RequestDetailBody({required this.request});

  final EmergencyRequest request;

  @override
  Widget build(BuildContext context) {
    final requester = request.requester;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            _DetailTile(label: 'Request ID', value: request.displayId),
            _DetailTile(
              label: 'Emergency Type',
              value: request.emergencyType,
              key: const Key('request-detail-emergency-type'),
            ),
            _DetailTile(label: 'Priority', value: request.priority),
            _DetailTile(label: 'Status', value: request.statusRaw),
            _DetailTile(label: 'Location', value: request.location),
            if (request.coordinateLabel != null)
              _DetailTile(
                label: 'Coordinates',
                value: request.coordinateLabel!,
              ),
            _DetailTile(
              label: 'Created time',
              value: formatDateTime(request.createdAt),
            ),
            _DetailTile(
              label: 'Updated time',
              value: request.updatedAt == null
                  ? '-'
                  : formatDateTime(request.updatedAt),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _Section(
          title: 'DESCRIPTION',
          child: Text(
            request.description?.trim().isNotEmpty == true
                ? request.description!
                : 'No description provided.',
            key: const Key('request-detail-description'),
            style: const TextStyle(fontSize: 13, height: 1.45),
          ),
        ),
        const SizedBox(height: 12),
        _Section(
          title: 'REQUESTER',
          child: requester == null
              ? const Text('Requester details unavailable.')
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(requester.name),
                    if ((requester.email ?? '').isNotEmpty)
                      Text(
                        requester.email!,
                        style: const TextStyle(color: AppColors.textDim),
                      ),
                    if ((requester.phone ?? '').isNotEmpty)
                      Text(
                        requester.phone!,
                        style: const TextStyle(color: AppColors.textDim),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: 12),
        _Section(
          title: 'RESPONDERS / ASSIGNMENTS',
          child: _AssignmentsDetail(request: request),
        ),
        const SizedBox(height: 12),
        _Section(
          title: 'REQUIRED RESOURCES',
          child: request.requiredResources.isEmpty
              ? const Text(
                  'No resources requested.',
                  style: TextStyle(color: AppColors.textFaint),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final line in request.requiredResources)
                      ResourceChip(
                        name: line.resourceName,
                        type: line.resourceType,
                        quantity: line.quantity,
                        trailingText: line.unit,
                      ),
                  ],
                ),
        ),
        const SizedBox(height: 12),
        _Section(
          title: 'ALLOCATION HISTORY',
          child: request.allocations.isEmpty
              ? const Text(
                  'No allocation history.',
                  style: TextStyle(color: AppColors.textFaint),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final allocation in request.allocations)
                      AllocationOperationalRow(allocation: allocation),
                  ],
                ),
        ),
        const SizedBox(height: 12),
        _Section(
          title: 'TIMELINE',
          child: OperationalTimeline(request: request),
        ),
      ],
    );
  }
}

class _AssignmentsDetail extends StatelessWidget {
  const _AssignmentsDetail({required this.request});

  final EmergencyRequest request;

  @override
  Widget build(BuildContext context) {
    if (request.assignments.isEmpty && request.acceptedBy == null) {
      return const Text(
        'No responder assigned.',
        style: TextStyle(color: AppColors.textFaint),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (request.acceptedBy != null)
          _AssignmentRow(
            name: request.acceptedBy!.name,
            status: 'LEAD',
            timestamp: request.acceptedAt,
          ),
        for (final assignment in request.assignments)
          _AssignmentRow(
            name: assignment.responder?.name ??
                'Responder #${assignment.responderId}',
            status: assignment.status,
            timestamp: assignment.acceptedAt ?? assignment.createdAt,
            endedAt: assignment.endedAt,
          ),
      ],
    );
  }
}

class _AssignmentRow extends StatelessWidget {
  const _AssignmentRow({
    required this.name,
    required this.status,
    this.timestamp,
    this.endedAt,
  });

  final String name;
  final String status;
  final DateTime? timestamp;
  final DateTime? endedAt;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.person_outline, size: 16, color: AppColors.textDim),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              '$name · $status'
              '${timestamp == null ? '' : ' · ${formatDateTime(timestamp)}'}'
              '${endedAt == null ? '' : ' · ended ${formatDateTime(endedAt)}'}',
              style: const TextStyle(fontSize: 12.5, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface2,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: AppColors.textFaint,
              letterSpacing: .6,
            ),
          ),
          const SizedBox(height: 7),
          child,
        ],
      ),
    );
  }
}

class _DetailTile extends StatelessWidget {
  const _DetailTile({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 200,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.surface2,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              fontSize: 9.5,
              color: AppColors.textFaint,
              letterSpacing: .5,
            ),
          ),
          const SizedBox(height: 4),
          SelectableText(value, style: const TextStyle(fontSize: 12.5)),
        ],
      ),
    );
  }
}
