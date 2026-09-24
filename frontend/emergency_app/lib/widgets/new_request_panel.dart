import 'package:flutter/material.dart';

import '../models/eras_models.dart';
import '../theme/app_theme.dart';
import 'common_widgets.dart';

/// Payload handed to the console when the requester submits the form.
class NewRequestPayload {
  const NewRequestPayload({
    required this.emergencyType,
    required this.description,
    required this.location,
    required this.priority,
    required this.requiredResources,
  });

  final String emergencyType;
  final String description;
  final String location;
  final String priority;

  /// [{ resourceId, quantity }] - real database ids only.
  final List<Map<String, int>> requiredResources;
}

class _DraftLine {
  _DraftLine({this.resourceId, this.quantity = 1});
  int? resourceId;
  int quantity;
}

/// Requester form. Every selectable resource comes from
/// GET /api/resources, so a resource added by an admin (for example
/// "Rescue Boat") shows up without touching this file.
class NewRequestPanel extends StatefulWidget {
  const NewRequestPanel({
    super.key,
    required this.resources,
    required this.locations,
    required this.onSubmit,
    required this.onReload,
    this.submitting = false,
  });

  final List<BackendResource> resources;
  final List<String> locations;
  final Future<bool> Function(NewRequestPayload payload) onSubmit;
  final VoidCallback onReload;
  final bool submitting;

  @override
  State<NewRequestPanel> createState() => _NewRequestPanelState();
}

class _NewRequestPanelState extends State<NewRequestPanel> {
  final descriptionController = TextEditingController();
  final customTypeController = TextEditingController();

  String emergencyType = kEmergencyTypes.first;
  String priority = 'HIGH';
  String? location;
  String? errorMessage;

  final List<_DraftLine> lines = <_DraftLine>[_DraftLine()];

  @override
  void dispose() {
    descriptionController.dispose();
    customTypeController.dispose();
    super.dispose();
  }

  List<BackendResource> get selectableResources =>
      widget.resources.where((r) => r.isActive).toList();

  BackendResource? resourceById(int? id) {
    if (id == null) return null;
    return firstWhereOrNull(widget.resources, (r) => r.id == id);
  }

  bool get canAddLine {
    final used = lines.where((l) => l.resourceId != null).length;
    return used < selectableResources.length && lines.length < 10;
  }

  void addLine() {
    setState(() {
      lines.add(_DraftLine());
      errorMessage = null;
    });
  }

  void removeLine(int index) {
    setState(() {
      lines.removeAt(index);
      if (lines.isEmpty) lines.add(_DraftLine());
      errorMessage = null;
    });
  }

  void changeQuantity(int index, int delta) {
    setState(() {
      final line = lines[index];
      final resource = resourceById(line.resourceId);
      final maxQuantity = resource?.availableQuantity ?? 1;

      var next = line.quantity + delta;
      if (next < 1) next = 1;
      if (resource != null && next > maxQuantity) next = maxQuantity;

      line.quantity = next;
      errorMessage = null;
    });
  }

  String? validate() {
    final resolvedType = emergencyType == 'Other'
        ? customTypeController.text.trim()
        : emergencyType.trim();

    if (resolvedType.isEmpty) {
      return 'Enter the emergency type';
    }

    if (descriptionController.text.trim().isEmpty) {
      return 'Describe the emergency';
    }

    if (location == null || location!.trim().isEmpty) {
      return 'Select a location';
    }

    if (!kPriorities.contains(priority)) {
      return 'Select a priority';
    }

    final chosen = lines.where((l) => l.resourceId != null).toList();

    if (chosen.isEmpty) {
      return 'Add at least one resource';
    }

    final ids = <int>{};

    for (final line in chosen) {
      final resource = resourceById(line.resourceId);

      if (resource == null) {
        return 'One of the selected resources is no longer available';
      }

      if (!resource.isActive) {
        return '${resource.name} is not active anymore';
      }

      if (resource.isOutOfStock) {
        return '${resource.name} is out of stock';
      }

      if (line.quantity <= 0) {
        return 'Quantity must be greater than 0';
      }

      if (line.quantity > resource.availableQuantity) {
        return 'Only ${resource.availableQuantity} ${resource.name} available';
      }

      if (!ids.add(resource.id)) {
        return 'The same resource was added twice';
      }
    }

    return null;
  }

  Future<void> submit() async {
    final error = validate();

    if (error != null) {
      setState(() => errorMessage = error);
      return;
    }

    setState(() => errorMessage = null);

    final resolvedType = emergencyType == 'Other'
        ? customTypeController.text.trim()
        : emergencyType.trim();

    final payload = NewRequestPayload(
      emergencyType: resolvedType,
      description: descriptionController.text.trim(),
      location: location!,
      priority: priority,
      requiredResources: lines
          .where((l) => l.resourceId != null)
          .map((l) => <String, int>{
                'resourceId': l.resourceId!,
                'quantity': l.quantity,
              })
          .toList(),
    );

    final saved = await widget.onSubmit(payload);

    if (!mounted || !saved) return;

    setState(() {
      descriptionController.clear();
      lines
        ..clear()
        ..add(_DraftLine());
      errorMessage = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    // Keep the location selection valid even if the list changes.
    if (location == null && widget.locations.isNotEmpty) {
      location = widget.locations.first;
    }

    return Panel(
      title: 'SUBMIT REQUEST',
      hint: 'Resources load live from PostgreSQL',
      trailing: IconButton(
        tooltip: 'Reload resources',
        onPressed: widget.onReload,
        icon: const Icon(Icons.refresh, size: 18, color: AppColors.textDim),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final narrow = constraints.maxWidth < 620;

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _emergencyFields(narrow),
                const SizedBox(height: 18),
                const Divider(height: 1, color: AppColors.border),
                const SizedBox(height: 14),
                const FieldLabel('Required resources'),
                const SizedBox(height: 10),
                if (selectableResources.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'No active resources found in the database.',
                      style: TextStyle(fontSize: 12.5, color: AppColors.red),
                    ),
                  )
                else
                  ...List.generate(
                    lines.length,
                    (index) => _resourceRow(index, narrow),
                  ),
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: canAddLine ? addLine : null,
                    icon: const Icon(Icons.add, size: 16),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.teal,
                    ),
                    label: const Text('Add another resource',
                        style: TextStyle(fontSize: 12.5)),
                  ),
                ),
                const SizedBox(height: 8),
                _summary(),
                if (errorMessage != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: AppColors.redDim,
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(
                      errorMessage!,
                      style: const TextStyle(
                          fontSize: 12.5, color: AppColors.red),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: widget.submitting ? null : submit,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.teal,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(5),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 15),
                    ),
                    child: Text(
                      widget.submitting ? 'Submitting…' : 'Submit request',
                      style: const TextStyle(fontSize: 14),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'The request is stored in PostgreSQL as an EmergencyRequest with one '
                  'RequestResource row per selected resource. Responders that own matching '
                  'available inventory will see it on their dispatch board.',
                  style: TextStyle(
                      fontSize: 11.5, color: AppColors.textFaint, height: 1.5),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _emergencyFields(bool narrow) {
    final typeField = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const FieldLabel('Emergency type'),
        const SizedBox(height: 6),
        DropdownButtonFormField<String>(
          key: ValueKey('emergency-type-$emergencyType'),
          initialValue: emergencyType,
          isExpanded: true,
          decoration: fieldDecoration(),
          items: kEmergencyTypes
              .map((type) =>
                  DropdownMenuItem<String>(value: type, child: Text(type)))
              .toList(),
          onChanged: (value) {
            if (value == null) return;
            setState(() {
              emergencyType = value;
              errorMessage = null;
            });
          },
        ),
        if (emergencyType == 'Other') ...[
          const SizedBox(height: 8),
          TextField(
            controller: customTypeController,
            decoration: fieldDecoration(hintText: 'Describe the type'),
            style: const TextStyle(fontSize: 13),
          ),
        ],
      ],
    );

    final locationField = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const FieldLabel('Location'),
        const SizedBox(height: 6),
        DropdownButtonFormField<String>(
          key: ValueKey('location-$location'),
          initialValue: location,
          isExpanded: true,
          decoration: fieldDecoration(),
          items: widget.locations
              .map((name) =>
                  DropdownMenuItem<String>(value: name, child: Text(name)))
              .toList(),
          onChanged: (value) {
            if (value == null) return;
            setState(() {
              location = value;
              errorMessage = null;
            });
          },
        ),
      ],
    );

    final priorityField = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const FieldLabel('Priority'),
        const SizedBox(height: 6),
        DropdownButtonFormField<String>(
          key: ValueKey('priority-$priority'),
          initialValue: priority,
          isExpanded: true,
          decoration: fieldDecoration(),
          items: kPriorities
              .map((value) => DropdownMenuItem<String>(
                    value: value,
                    child: Text(titleCase(value)),
                  ))
              .toList(),
          onChanged: (value) {
            if (value == null) return;
            setState(() {
              priority = value;
              errorMessage = null;
            });
          },
        ),
      ],
    );

    final descriptionField = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const FieldLabel('Description'),
        const SizedBox(height: 6),
        TextField(
          controller: descriptionController,
          minLines: 2,
          maxLines: 3,
          style: const TextStyle(fontSize: 13),
          decoration: fieldDecoration(
            hintText: 'What happened, how many people are affected…',
          ),
          onChanged: (_) {
            if (errorMessage != null) {
              setState(() => errorMessage = null);
            }
          },
        ),
      ],
    );

    if (narrow) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          typeField,
          const SizedBox(height: 12),
          locationField,
          const SizedBox(height: 12),
          priorityField,
          const SizedBox(height: 12),
          descriptionField,
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: typeField),
            const SizedBox(width: 12),
            Expanded(child: locationField),
            const SizedBox(width: 12),
            Expanded(child: priorityField),
          ],
        ),
        const SizedBox(height: 12),
        descriptionField,
      ],
    );
  }

  Widget _resourceRow(int index, bool narrow) {
    final line = lines[index];
    final resource = resourceById(line.resourceId);

    final takenElsewhere = lines
        .asMap()
        .entries
        .where((entry) => entry.key != index)
        .map((entry) => entry.value.resourceId)
        .whereType<int>()
        .toSet();

    final items = selectableResources
        .where((r) => !takenElsewhere.contains(r.id))
        .map(
          (r) => DropdownMenuItem<int>(
            value: r.id,
            enabled: r.isSelectable,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    r.name,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: r.isSelectable
                          ? AppColors.text
                          : AppColors.textFaint,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  r.isOutOfStock ? 'Out of stock' : r.shortAvailability,
                  style: TextStyle(
                    fontSize: 11,
                    color:
                        r.isOutOfStock ? AppColors.red : AppColors.textFaint,
                  ),
                ),
              ],
            ),
          ),
        )
        .toList();

    // A resource that was selected before an admin deactivated it must still
    // be a valid dropdown entry, otherwise the dropdown would assert.
    if (line.resourceId != null &&
        !items.any((item) => item.value == line.resourceId)) {
      final stale = resourceById(line.resourceId);

      items.insert(
        0,
        DropdownMenuItem<int>(
          value: line.resourceId,
          enabled: false,
          child: Text(
            stale == null
                ? 'Resource #${line.resourceId} (unavailable)'
                : '${stale.name} (unavailable)',
            style: const TextStyle(fontSize: 13, color: AppColors.textFaint),
          ),
        ),
      );
    }

    final selector = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const FieldLabel('Resource'),
        const SizedBox(height: 6),
        DropdownButtonFormField<int>(
          key: ValueKey(
              'resource-${identityHashCode(line)}-${line.resourceId}'),
          initialValue: line.resourceId,
          isExpanded: true,
          decoration: fieldDecoration(),
          hint: const Text('Select a resource',
              style: TextStyle(fontSize: 13, color: AppColors.textFaint)),
          items: items,
          onChanged: (value) {
            if (value == null) return;
            setState(() {
              line.resourceId = value;
              final picked = resourceById(value);
              if (picked != null && line.quantity > picked.availableQuantity) {
                line.quantity = picked.availableQuantity;
              }
              if (line.quantity < 1) line.quantity = 1;
              errorMessage = null;
            });
          },
        ),
      ],
    );

    final availability = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const FieldLabel('Available'),
        const SizedBox(height: 6),
        Container(
          height: 42,
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: AppColors.surface2,
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Text(
            resource == null ? '-' : resource.availabilityLabel,
            style: monoStyle(
              size: 12.5,
              color: resource == null
                  ? AppColors.textFaint
                  : resource.isOutOfStock
                      ? AppColors.red
                      : resource.isLowStock
                          ? AppColors.amber
                          : AppColors.textDim,
            ),
          ),
        ),
      ],
    );

    final quantity = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const FieldLabel('Quantity'),
        const SizedBox(height: 6),
        Container(
          height: 42,
          decoration: BoxDecoration(
            color: AppColors.surface2,
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                onPressed:
                    resource == null ? null : () => changeQuantity(index, -1),
                icon: const Icon(Icons.remove, size: 16),
                splashRadius: 18,
              ),
              Text(
                '${line.quantity}',
                style: monoStyle(
                    size: 14, color: AppColors.text, weight: FontWeight.w600),
              ),
              IconButton(
                onPressed:
                    resource == null ? null : () => changeQuantity(index, 1),
                icon: const Icon(Icons.add, size: 16),
                splashRadius: 18,
              ),
            ],
          ),
        ),
      ],
    );

    final removeButton = IconButton(
      tooltip: 'Remove resource',
      onPressed: lines.length == 1 && line.resourceId == null
          ? null
          : () => removeLine(index),
      icon: const Icon(Icons.close, size: 18, color: AppColors.textFaint),
    );

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 12),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(6),
      ),
      child: narrow
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: selector),
                    removeButton,
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: availability),
                    const SizedBox(width: 10),
                    SizedBox(width: 132, child: quantity),
                  ],
                ),
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 4, child: selector),
                const SizedBox(width: 12),
                Expanded(flex: 3, child: availability),
                const SizedBox(width: 12),
                SizedBox(width: 140, child: quantity),
                removeButton,
              ],
            ),
    );
  }

  Widget _summary() {
    final chosen = lines.where((l) => l.resourceId != null).toList();

    if (chosen.isEmpty) {
      return const Text(
        'No resources selected yet.',
        style: TextStyle(fontSize: 12, color: AppColors.textFaint),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface2,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'REQUIRED',
            style: TextStyle(
                fontSize: 10, color: AppColors.textFaint, letterSpacing: .6),
          ),
          const SizedBox(height: 6),
          ...chosen.map((line) {
            final resource = resourceById(line.resourceId);
            if (resource == null) return const SizedBox.shrink();

            return ResourceChip(
              name: resource.name,
              type: resource.type,
              quantity: line.quantity,
              trailingText: resource.unit,
            );
          }),
        ],
      ),
    );
  }
}
