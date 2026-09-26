import 'package:flutter/material.dart';

import '../models/eras_models.dart';
import '../theme/app_theme.dart';
import 'common_widgets.dart';
import 'operational_status.dart';

/// Closed / after-action log. Completed and cancelled requests straight from
/// the database - no session-only memory.
class LogPanel extends StatelessWidget {
  const LogPanel({super.key, required this.logEntries, this.isMobile = false});

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
                      fontSize: 13,
                      color: AppColors.text,
                    ),
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
                      return DataRow(
                        cells: [
                          DataCell(
                            Text(
                              entry.displayId,
                              style: monoStyle(
                                size: 12.5,
                                color: AppColors.textDim,
                              ),
                            ),
                          ),
                          DataCell(Text(entry.emergencyType)),
                          DataCell(Text(entry.location)),
                          DataCell(
                            Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                if (entry.requiredResources.isEmpty)
                                  const Text(
                                    '-',
                                    style:
                                        TextStyle(color: AppColors.textFaint),
                                  )
                                else
                                  ...entry.requiredResources.map(
                                    (line) => ResourceChip(
                                      name: line.resourceName,
                                      type: line.resourceType,
                                      quantity: line.quantity,
                                    ),
                                  ),
                                if (entry.allocations.isNotEmpty) ...[
                                  const Divider(
                                      height: 6, color: AppColors.border),
                                  ...entry.allocations.map(
                                    (allocation) => AllocationOperationalRow(
                                      allocation: allocation,
                                      compact: true,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          DataCell(Text(entry.acceptedBy?.name ?? '-')),
                          DataCell(
                            Text(
                              formatDateTime(entry.createdAt),
                              style:
                                  monoStyle(size: 12, color: AppColors.textDim),
                            ),
                          ),
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
                        ],
                      );
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
                    weight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${request.emergencyType} · ${request.location}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textDim,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  request.resourcesSummary,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: AppColors.textFaint,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Responder: ${request.acceptedBy?.name ?? '-'}',
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: AppColors.textFaint,
                  ),
                ),
                if (request.allocations.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  ...request.allocations.map(
                    (allocation) => AllocationOperationalRow(
                      allocation: allocation,
                      compact: true,
                    ),
                  ),
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
