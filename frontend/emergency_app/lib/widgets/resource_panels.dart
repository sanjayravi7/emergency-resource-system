import 'package:flutter/material.dart';

import '../models/eras_models.dart';
import '../theme/app_theme.dart';
import 'common_widgets.dart';

// ── Resource catalog (read for everyone, managed by ADMIN) ─────────────────

class ResourceCatalogPanel extends StatelessWidget {
  const ResourceCatalogPanel({
    super.key,
    required this.resources,
    required this.isAdmin,
    this.onCreate,
    this.onEdit,
    this.onToggleActive,
    this.isMobile = false,
  });

  final List<BackendResource> resources;
  final bool isAdmin;
  final VoidCallback? onCreate;
  final void Function(BackendResource resource)? onEdit;
  final void Function(BackendResource resource, bool isActive)? onToggleActive;
  final bool isMobile;

  @override
  Widget build(BuildContext context) {
    final lowStock = resources.where((r) => r.isActive && r.isLowStock).length;
    final outOfStock =
        resources.where((r) => r.isActive && r.isOutOfStock).length;

    return Panel(
      title: 'RESOURCE CATALOG',
      hint: 'Live resources from PostgreSQL',
      trailing: isAdmin && onCreate != null
          ? TextButton.icon(
              onPressed: onCreate,
              icon: const Icon(Icons.add, size: 16),
              style: TextButton.styleFrom(foregroundColor: AppColors.teal),
              label: const Text('New resource',
                  style: TextStyle(fontSize: 12.5)),
            )
          : null,
      child: resources.isEmpty
          ? const EmptyState('No resources found in the database.')
          : Column(
              children: [
                if (lowStock > 0 || outOfStock > 0)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    color: AppColors.amberDim,
                    child: Text(
                      '$lowStock low stock · $outOfStock out of stock',
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.amber),
                    ),
                  ),
                ...resources.map(
                  (resource) => _ResourceRow(
                    resource: resource,
                    isAdmin: isAdmin,
                    onEdit: onEdit,
                    onToggleActive: onToggleActive,
                  ),
                ),
              ],
            ),
    );
  }
}

class _ResourceRow extends StatelessWidget {
  const _ResourceRow({
    required this.resource,
    required this.isAdmin,
    this.onEdit,
    this.onToggleActive,
  });

  final BackendResource resource;
  final bool isAdmin;
  final void Function(BackendResource resource)? onEdit;
  final void Function(BackendResource resource, bool isActive)? onToggleActive;

  @override
  Widget build(BuildContext context) {
    final meta = resourceMetaFor(
        resource.type.isEmpty ? resource.name : resource.type);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: meta.bg,
              borderRadius: BorderRadius.circular(5),
            ),
            child: Icon(meta.icon, size: 17, color: meta.color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        resource.name,
                        style: const TextStyle(
                            fontSize: 13.5, fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'ID ${resource.id}',
                      style: monoStyle(size: 11, color: AppColors.textFaint),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  [
                    resource.type,
                    if (resource.location != null) resource.location!,
                  ].join(' · '),
                  style: const TextStyle(
                      fontSize: 11.5, color: AppColors.textFaint),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${resource.availableQuantity}/${resource.totalQuantity}'
                '${resource.unit == null ? '' : ' ${resource.unit}'}',
                style: monoStyle(size: 12.5, color: AppColors.textDim),
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                children: [
                  if (!resource.isActive)
                    const _Tag(text: 'INACTIVE', color: AppColors.textFaint),
                  if (resource.isActive && resource.isOutOfStock)
                    const _Tag(text: 'OUT OF STOCK', color: AppColors.red),
                  if (resource.isActive && resource.isLowStock)
                    const _Tag(text: 'LOW STOCK', color: AppColors.amber),
                ],
              ),
            ],
          ),
          if (isAdmin) ...[
            const SizedBox(width: 8),
            IconButton(
              tooltip: 'Edit resource',
              onPressed: onEdit == null ? null : () => onEdit!(resource),
              icon: const Icon(Icons.edit_outlined,
                  size: 17, color: AppColors.textDim),
            ),
            IconButton(
              tooltip: resource.isActive ? 'Deactivate' : 'Restore',
              onPressed: onToggleActive == null
                  ? null
                  : () => onToggleActive!(resource, !resource.isActive),
              icon: Icon(
                resource.isActive
                    ? Icons.toggle_on_outlined
                    : Icons.toggle_off_outlined,
                size: 20,
                color: resource.isActive ? AppColors.teal : AppColors.textFaint,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        text,
        style: monoStyle(size: 9.5, color: color, weight: FontWeight.w600),
      ),
    );
  }
}

// ── ADMIN editor ───────────────────────────────────────────────────────────

class ResourceEditorDialog extends StatefulWidget {
  const ResourceEditorDialog({super.key, this.resource});

  /// null => create a new resource
  final BackendResource? resource;

  @override
  State<ResourceEditorDialog> createState() => _ResourceEditorDialogState();
}

class _ResourceEditorDialogState extends State<ResourceEditorDialog> {
  late final TextEditingController nameController;
  late final TextEditingController typeController;
  late final TextEditingController totalController;
  late final TextEditingController availableController;
  late final TextEditingController unitController;
  late final TextEditingController locationController;
  late final TextEditingController thresholdController;

  String? error;

  @override
  void initState() {
    super.initState();
    final resource = widget.resource;

    nameController = TextEditingController(text: resource?.name ?? '');
    typeController = TextEditingController(text: resource?.type ?? '');
    totalController =
        TextEditingController(text: '${resource?.totalQuantity ?? 0}');
    availableController =
        TextEditingController(text: '${resource?.availableQuantity ?? 0}');
    unitController = TextEditingController(text: resource?.unit ?? '');
    locationController = TextEditingController(text: resource?.location ?? '');
    thresholdController =
        TextEditingController(text: '${resource?.lowStockThreshold ?? 1}');
  }

  @override
  void dispose() {
    nameController.dispose();
    typeController.dispose();
    totalController.dispose();
    availableController.dispose();
    unitController.dispose();
    locationController.dispose();
    thresholdController.dispose();
    super.dispose();
  }

  void save() {
    final total = int.tryParse(totalController.text.trim());
    final available = int.tryParse(availableController.text.trim());
    final threshold = int.tryParse(thresholdController.text.trim());

    if (nameController.text.trim().isEmpty) {
      setState(() => error = 'Name is required');
      return;
    }

    if (typeController.text.trim().isEmpty) {
      setState(() => error = 'Type is required');
      return;
    }

    if (total == null || total < 0) {
      setState(() => error = 'Total quantity must be 0 or more');
      return;
    }

    if (available == null || available < 0) {
      setState(() => error = 'Available quantity must be 0 or more');
      return;
    }

    if (available > total) {
      setState(() => error = 'Available cannot exceed total');
      return;
    }

    if (threshold == null || threshold < 0) {
      setState(() => error = 'Low stock threshold must be 0 or more');
      return;
    }

    Navigator.of(context).pop(<String, dynamic>{
      'name': nameController.text.trim(),
      'type': typeController.text.trim(),
      'totalQuantity': total,
      'availableQuantity': available,
      'unit': unitController.text.trim(),
      'location': locationController.text.trim(),
      'lowStockThreshold': threshold,
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text(
        widget.resource == null ? 'New resource' : 'Edit ${widget.resource!.name}',
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
      ),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _field('Name', nameController),
              _field('Type', typeController, hint: 'AMBULANCE, OXYGEN, FIRE…'),
              Row(
                children: [
                  Expanded(child: _field('Total quantity', totalController)),
                  const SizedBox(width: 10),
                  Expanded(
                      child: _field('Available quantity', availableController)),
                ],
              ),
              Row(
                children: [
                  Expanded(
                      child: _field('Unit', unitController,
                          hint: 'vehicle, unit, cylinder…')),
                  const SizedBox(width: 10),
                  Expanded(child: _field('Location', locationController)),
                ],
              ),
              _field('Low stock threshold', thresholdController),
              if (error != null) ...[
                const SizedBox(height: 8),
                Text(error!,
                    style:
                        const TextStyle(fontSize: 12.5, color: AppColors.red)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: save,
          style: FilledButton.styleFrom(backgroundColor: AppColors.teal),
          child: const Text('Save'),
        ),
      ],
    );
  }

  Widget _field(String label, TextEditingController controller,
      {String? hint}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FieldLabel(label),
          const SizedBox(height: 5),
          TextField(
            controller: controller,
            style: const TextStyle(fontSize: 13),
            decoration: fieldDecoration(hintText: hint),
          ),
        ],
      ),
    );
  }
}

// ── Responder inventory ────────────────────────────────────────────────────

class ResponderResourcesPanel extends StatelessWidget {
  const ResponderResourcesPanel({
    super.key,
    required this.resources,
    this.title = 'RESPONDER INVENTORY',
  });

  final List<BackendResponderResource> resources;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Panel(
      title: title,
      hint: 'ResponderResource rows from PostgreSQL',
      child: resources.isEmpty
          ? const EmptyState('No responder resources found in the database.')
          : Column(
              children: resources.map((item) {
                final meta = resourceMetaFor(item.resourceType.isEmpty
                    ? item.resourceName
                    : item.resourceType);

                return Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: const BoxDecoration(
                    border:
                        Border(bottom: BorderSide(color: AppColors.border)),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: meta.bg,
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Icon(meta.icon, size: 16, color: meta.color),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${item.responderName}  •  ID ${item.responderId}',
                              style: const TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '${item.resourceName}'
                              '${item.unit == null ? '' : ' (${item.unit})'}',
                              style: const TextStyle(
                                  fontSize: 12, color: AppColors.textDim),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        '${item.availableQuantity}/${item.totalQuantity}',
                        style: monoStyle(size: 12.5, color: AppColors.textDim),
                      ),
                      const SizedBox(width: 14),
                      Text(
                        item.status,
                        style: monoStyle(
                          size: 11,
                          color: item.status == 'AVAILABLE'
                              ? AppColors.teal
                              : item.status == 'BUSY'
                                  ? AppColors.blue
                                  : AppColors.textFaint,
                          weight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
    );
  }
}

// ── Live responders ────────────────────────────────────────────────────────

class BackendRespondersPanel extends StatelessWidget {
  const BackendRespondersPanel({
    super.key,
    required this.responders,
    this.isMobile = false,
  });

  final List<BackendResponder> responders;
  final bool isMobile;

  @override
  Widget build(BuildContext context) {
    return Panel(
      title: 'LIVE RESPONDERS',
      hint: 'Responders loaded from PostgreSQL',
      child: responders.isEmpty
          ? const EmptyState('No responders found in the database.')
          : Column(
              children: responders.map((r) {
                final color = responderStatusColor(r.status);

                return Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: isMobile ? 14 : 16,
                    vertical: 12,
                  ),
                  decoration: const BoxDecoration(
                    border:
                        Border(bottom: BorderSide(color: AppColors.border)),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${r.name}  •  ID ${r.id}',
                              style: const TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              r.email,
                              style: const TextStyle(
                                  fontSize: 11.5, color: AppColors.textFaint),
                            ),
                            if (r.phone != null) ...[
                              const SizedBox(height: 2),
                              Text(
                                r.phone!,
                                style: const TextStyle(
                                    fontSize: 11.5,
                                    color: AppColors.textFaint),
                              ),
                            ],
                            if (r.location != null &&
                                r.location!.isNotEmpty) ...[
                              const SizedBox(height: 3),
                              Text(
                                r.location!,
                                style: const TextStyle(
                                    fontSize: 11.5, color: AppColors.textDim),
                              ),
                            ],
                          ],
                        ),
                      ),
                      Text(
                        r.status,
                        style: monoStyle(
                            size: 11, color: color, weight: FontWeight.w600),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
    );
  }
}
