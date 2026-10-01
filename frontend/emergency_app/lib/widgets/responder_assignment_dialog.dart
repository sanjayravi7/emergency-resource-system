import 'package:flutter/material.dart';

import '../models/eras_models.dart';
import '../theme/app_theme.dart';
import 'auth_motion.dart';

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
    final p = ErasPalette.of(context);
    final rows = compatibleResponders;
    final selected = firstWhereOrNull(
      rows,
      (responder) => responder.id == selectedResponderId,
    );

    return AlertDialog(
      key: const Key('responder-assignment-dialog'),
      backgroundColor: p.surface,
      surfaceTintColor: Colors.transparent,
      title: Text(
        'Accept / assign ${widget.request.displayId}',
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w700,
          color: p.text,
        ),
      ),
      content: SizedBox(
        width: 620,
        child: rows.isEmpty
            ? Padding(
                padding: const EdgeInsets.symmetric(vertical: 18),
                child: Text(
                  'No compatible AVAILABLE responders right now. Help types, '
                  'active workload and resource availability are checked by '
                  'the backend.',
                  style: TextStyle(color: p.textDim, height: 1.45),
                ),
              )
            : ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 520),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: rows.length,
                  separatorBuilder: (_, __) =>
                      Divider(height: 1, color: p.border),
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
          style: TextButton.styleFrom(foregroundColor: p.textDim),
          child: const Text('Cancel'),
        ),
        PressableScale(
          enabled: selected != null,
          child: FilledButton(
            key: const Key('confirm-admin-assignment-button'),
            onPressed: selected == null
                ? null
                : () => Navigator.of(context).pop(selected),
            style: FilledButton.styleFrom(
              backgroundColor: p.teal,
              foregroundColor: Colors.white,
            ),
            child: const Text('Assign responder'),
          ),
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
    final p = ErasPalette.of(context);
    final helpTypes = responder.helpTypes
        .map((row) => row.displayLabel)
        .where((label) => label.trim().isNotEmpty)
        .join(', ');

    return InkWell(
      key: Key('assignment-responder-${responder.id}'),
      onTap: onSelected,
      child: AnimatedContainer(
        duration: AuthMotion.fast,
        curve: AuthMotion.outCurve,
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? p.tealDim.withValues(alpha: .45)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
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
                color: selected ? p.teal : p.textFaint,
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
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: p.text,
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
                      style: TextStyle(
                        fontSize: 12,
                        color: p.textDim,
                      ),
                    ),
                  ],
                  const SizedBox(height: 5),
                  if (responder.resources.isEmpty)
                    Text(
                      'No enabled inventory/resource rows',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: p.textFaint,
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
                              color: p.surface2,
                              border: Border.all(color: p.border),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              resource.isService
                                  ? '${resource.resourceName} · enabled · ${resource.status}'
                                  : '${resource.resourceName} · '
                                      '${resource.availableQuantity}/${resource.totalQuantity} '
                                      '${resource.status}',
                              style: TextStyle(
                                fontSize: 10.5,
                                color: p.textDim,
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
    final p = ErasPalette.of(context);
    final color = responderStatusColor(status, p);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: p.dark ? .18 : .12),
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
