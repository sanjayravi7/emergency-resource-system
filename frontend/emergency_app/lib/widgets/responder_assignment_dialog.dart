import 'package:flutter/material.dart';

import '../models/eras_models.dart';
import '../theme/app_theme.dart';

/// ADMIN responder picker. Compatibility comes from the backend's existing
/// acceptance rules (`compatibleRequestIds`); this widget never guesses from
/// labels and never offers an incompatible responder.
class ResponderAssignmentDialog extends StatefulWidget {
  const ResponderAssignmentDialog({
    super.key,
    required this.request,
    required this.responders,
  });

  final EmergencyRequest request;
  final List<BackendResponder> responders;

  @override
  State<ResponderAssignmentDialog> createState() =>
      _ResponderAssignmentDialogState();
}

class _ResponderAssignmentDialogState extends State<ResponderAssignmentDialog> {
  int? selectedResponderId;

  List<BackendResponder> get compatibleResponders {
    final rows = widget.responders
        .where((responder) => responder.isCompatibleWith(widget.request.id))
        .toList();
    rows.sort((left, right) => left.name.compareTo(right.name));
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final rows = compatibleResponders;
    final selected = firstWhereOrNull(
      rows,
      (responder) => responder.id == selectedResponderId,
    );

    return AlertDialog(
      key: const Key('responder-assignment-dialog'),
      backgroundColor: AppColors.surface,
      title: Text('Accept / assign ${widget.request.displayId}'),
      content: SizedBox(
        width: 620,
        child: rows.isEmpty
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 18),
                child: Text(
                  'No compatible AVAILABLE responders right now. Help types, '
                  'active workload and resource availability are checked by '
                  'the backend.',
                  style: TextStyle(color: AppColors.textDim, height: 1.45),
                ),
              )
            : ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 520),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: rows.length,
                  separatorBuilder: (_, __) =>
                      const Divider(height: 1, color: AppColors.border),
                  itemBuilder: (context, index) {
                    final responder = rows[index];
                    return _ResponderChoice(
                      responder: responder,
                      selected: selectedResponderId == responder.id,
                      onSelected: () =>
                          setState(() => selectedResponderId = responder.id),
                    );
                  },
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('confirm-admin-assignment-button'),
          onPressed: selected == null
              ? null
              : () => Navigator.of(context).pop(selected),
          style: FilledButton.styleFrom(backgroundColor: AppColors.teal),
          child: const Text('Assign responder'),
        ),
      ],
    );
  }
}

class _ResponderChoice extends StatelessWidget {
  const _ResponderChoice({
    required this.responder,
    required this.selected,
    required this.onSelected,
  });

  final BackendResponder responder;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    final helpTypes = responder.helpTypes
        .map((row) => row.displayLabel)
        .where((label) => label.trim().isNotEmpty)
        .join(', ');

    return InkWell(
      key: Key('assignment-responder-${responder.id}'),
      onTap: onSelected,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 20,
                color: selected ? AppColors.teal : AppColors.textFaint,
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          responder.name,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      _StatusBadge(status: responder.status),
                    ],
                  ),
                  if (helpTypes.isNotEmpty) ...[
                    const SizedBox(height: 5),
                    Text(
                      'Help types · $helpTypes',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textDim,
                      ),
                    ),
                  ],
                  const SizedBox(height: 5),
                  if (responder.resources.isEmpty)
                    const Text(
                      'No enabled inventory/resource rows',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: AppColors.textFaint,
                      ),
                    )
                  else
                    Wrap(
                      spacing: 6,
                      runSpacing: 5,
                      children: [
                        for (final resource in responder.resources)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.surface2,
                              border: Border.all(color: AppColors.border),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              resource.isService
                                  ? '${resource.resourceName} · enabled · ${resource.status}'
                                  : '${resource.resourceName} · '
                                      '${resource.availableQuantity}/${resource.totalQuantity} '
                                      '${resource.status}',
                              style: const TextStyle(
                                fontSize: 10.5,
                                color: AppColors.textDim,
                              ),
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final color = responderStatusColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        status,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}
