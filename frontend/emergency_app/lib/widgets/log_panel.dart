import 'package:flutter/material.dart';

import '../models/eras_models.dart';
import '../theme/app_theme.dart';
import 'common_widgets.dart';
import 'operational_status.dart';

/// Closed / after-action log. Completed and cancelled requests straight from
/// the database - no session-only memory.
class LogPanel extends StatelessWidget {
  const LogPanel({
    super.key,
    required this.logEntries,
    this.isMobile = false,
  });

  final List<EmergencyRequest> logEntries;
  final bool isMobile;

  @override
  Widget build(BuildContext context) {
    return Panel(
      title: 'CLOSED / AFTER-ACTION LOG',
      hint: 'Completed and cancelled requests',
      child: logEntries.isEmpty
          ? const EmptyState('Nothing closed out yet.')
          : isMobile
              ? Column(
                  children: logEntries
                      .take(50)
                      .map((entry) => _LogCard(request: entry))
                      .toList(),
                )
              : SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    headingTextStyle: tableHeadStyle(),
                    dataTextStyle: const TextStyle(
                        fontSize: 13, color: AppColors.text),
                    dataRowMinHeight: 72,
                    dataRowMaxHeight: 180,
                    columns: const [
                      DataColumn(label: Text('REQUEST ID')),
                      DataColumn(label: Text('EMERGENCY')),
                      DataColumn(label: Text('LOCATION')),
                      DataColumn(label: Text('RESOURCES')),
                      DataColumn(label: Text('RESPONDER')),
                      DataColumn(label: Text('CREATED')),
                      DataColumn(label: Text('STATUS')),
                    ],
                    rows: logEntries.take(50).map((entry) {
                      return DataRow(cells: [
                        DataCell(Text(
                          entry.displayId,
                          style:
                              monoStyle(size: 12.5, color: AppColors.textDim),
                        )),
                        DataCell(Text(entry.emergencyType)),
                        DataCell(Text(entry.location)),
                        DataCell(
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              if (entry.requiredResources.isEmpty)
                                const Text('-',
                                    style: TextStyle(
                                        color: AppColors.textFaint))
                              else
                                ...entry.requiredResources.map(
                                  (line) => ResourceChip(
                                    name: line.resourceName,
                                    type: line.resourceType,
                                    quantity: line.quantity,
                                  ),
                                ),
                              if (entry.allocations.isNotEmpty) ...[
                                const Divider(height: 6, color: AppColors.border),
                                // PHASE F: allocations are grouped by the
                                // responder who owns them; every status
                                // (RESERVED/DISPATCHED/DELIVERED/CANCELLED)
                                // is preserved per row.
                                _AllocationsByResponder(
                                    allocations: entry.allocations),
                              ],
                            ],
                          ),
                        ),
                        DataCell(
                          SizedBox(
                            width: 170,
                            child: _RespondersSummary(request: entry),
                          ),
                        ),
                        DataCell(Text(
                          formatDateTime(entry.createdAt),
                          style: monoStyle(size: 12, color: AppColors.textDim),
                        )),
                        DataCell(
                          SizedBox(
                            width: 430,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                StatusPill(status: entry.status),
                                const SizedBox(height: 7),
                                OperationalTimeline(
                                  request: entry,
                                  compact: true,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ]);
                    }).toList(),
                  ),
                ),
    );
  }
}

class _LogCard extends StatelessWidget {
  const _LogCard({required this.request});
  final EmergencyRequest request;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  request.displayId,
                  style: monoStyle(
                      size: 12.5,
                      color: AppColors.textDim,
                      weight: FontWeight.w600),
                ),
                const SizedBox(height: 3),
                Text(
                  '${request.emergencyType} · ${request.location}',
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.textDim),
                ),
                const SizedBox(height: 2),
                Text(
                  request.resourcesSummary,
                  style: const TextStyle(
                      fontSize: 11.5, color: AppColors.textFaint),
                ),
                const SizedBox(height: 2),
                _RespondersSummary(request: request, mobile: true),
                if (request.allocations.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  _AllocationsByResponder(allocations: request.allocations),
                ],
                const SizedBox(height: 7),
                OperationalTimeline(request: request, compact: true),
              ],
            ),
          ),
          StatusPill(status: request.status),
        ],
      ),
    );
  }
}

/// PHASE F: the after-action log lists every responder who worked the
/// request - the preserved acceptedBy lead first, then every assignment
/// (ACTIVE or ENDED: history is history, but it stays truthful). Names come
/// from PostgreSQL snapshots; nothing is guessed client-side.
class _RespondersSummary extends StatelessWidget {
  const _RespondersSummary({required this.request, this.mobile = false});

  final EmergencyRequest request;
  final bool mobile;

  @override
  Widget build(BuildContext context) {
    final names = <String>[];
    void add(String? name) {
      final trimmed = name?.trim();
      if (trimmed == null || trimmed.isEmpty || names.contains(trimmed)) {
        return;
      }
      names.add(trimmed);
    }

    add(request.acceptedBy?.name);
    for (final assignment in request.assignments) {
      add(assignment.responder?.name ?? 'Responder #${assignment.responderId}');
    }
    if (names.isEmpty) {
      return Text(mobile ? 'Responder: -' : '-',
          style: const TextStyle(
              fontSize: 11.5, color: AppColors.textFaint));
    }

    if (!mobile) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final name in names)
            Text(name, style: const TextStyle(fontSize: 12.5)),
        ],
      );
    }
    return Text(
      'Responders: ${names.join(', ')}',
      style: const TextStyle(fontSize: 11.5, color: AppColors.textFaint),
    );
  }
}

/// PHASE F: allocation rows grouped per responder (Part 16). With a single
/// responder the rendering is byte-for-byte the previous flat list; with
/// several responders each group gets a faint label so the after-action log
/// reads per responder. Statuses are untouched - each row keeps its own
/// AllocationStatusBadge.
class _AllocationsByResponder extends StatelessWidget {
  const _AllocationsByResponder({required this.allocations});

  final List<AllocationLine> allocations;

  @override
  Widget build(BuildContext context) {
    // Preserve the payload order but bucket by responder owner.
    final grouped = <int, List<AllocationLine>>{};
    for (final allocation in allocations) {
      grouped.putIfAbsent(allocation.responderId, () => []).add(allocation);
    }

    final singleResponder = grouped.length <= 1;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final entry in grouped.entries) ...[
          if (!singleResponder) ...[
            Text(
              '${entry.value.first.responderName ?? 'Responder #${entry.key}'}'
              ' · ${entry.value.length} allocation'
              '${entry.value.length == 1 ? '' : 's'}',
              style: const TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textFaint),
            ),
            const SizedBox(height: 2),
          ],
          for (final allocation in entry.value)
            AllocationOperationalRow(allocation: allocation, compact: true),
        ],
      ],
    );
  }
}
