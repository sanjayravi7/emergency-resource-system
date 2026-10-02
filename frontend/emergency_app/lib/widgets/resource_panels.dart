import 'package:flutter/material.dart';

import '../models/eras_models.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import 'auth_motion.dart';
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
    final p = ErasPalette.of(context);
    final lowStock = resources.where((r) => r.isActive && r.isLowStock).length;
    final outOfStock =
        resources.where((r) => r.isActive && r.isOutOfStock).length;

    return Panel(
      title: 'RESOURCE CATALOG',
      hint: 'Live resources',
      trailing: isAdmin && onCreate != null
          ? TextButton.icon(
              onPressed: onCreate,
              icon: const Icon(Icons.add, size: 16),
              style: TextButton.styleFrom(foregroundColor: p.teal),
              label:
                  const Text('New resource', style: TextStyle(fontSize: 12.5)),
            )
          : null,
      child: resources.isEmpty
          ? const EmptyState('No resources found.')
          : Column(
              children: [
                if (lowStock > 0 || outOfStock > 0)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      color: p.amberDim,
                      border: Border(
                        bottom: BorderSide(
                          color: p.amber.withValues(alpha: .35),
                        ),
                      ),
                    ),
                    child: Text(
                      '$lowStock low stock · $outOfStock out of stock',
                      style: TextStyle(fontSize: 12, color: p.amber),
                    ),
                  ),
                for (var i = 0; i < resources.length; i++)
                  EntranceReveal(
                    delay:
                        i < 6 ? Duration(milliseconds: 22 * i) : Duration.zero,
                    offset: const Offset(0, 5),
                    child: _ResourceRow(
                      resource: resources[i],
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
    final p = ErasPalette.of(context);
    final meta = resourceMetaFor(
      resource.type.isEmpty ? resource.name : resource.type,
      p,
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: p.border)),
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
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: p.text,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'ID ${resource.id}',
                      style: monoStyle(size: 11, color: p.textFaint),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  [
                    resource.type,
                    if (resource.location != null) resource.location!,
                  ].join(' · '),
                  style: TextStyle(fontSize: 11.5, color: p.textFaint),
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
                style: monoStyle(size: 12.5, color: p.textDim),
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                children: [
                  if (!resource.isActive)
                    _Tag(text: 'INACTIVE', color: p.textFaint),
                  if (resource.isActive && resource.isOutOfStock)
                    _Tag(text: 'OUT OF STOCK', color: p.red),
                  if (resource.isActive && resource.isLowStock)
                    _Tag(text: 'LOW STOCK', color: p.amber),
                ],
              ),
            ],
          ),
          if (isAdmin) ...[
            const SizedBox(width: 8),
            IconButton(
              tooltip: 'Edit resource',
              onPressed: onEdit == null ? null : () => onEdit!(resource),
              icon: Icon(Icons.edit_outlined, size: 17, color: p.textDim),
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
                color: resource.isActive ? p.teal : p.textFaint,
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
    final p = ErasPalette.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: p.dark ? color.withValues(alpha: .16) : Colors.transparent,
        border: Border.all(
          color: p.dark ? color.withValues(alpha: .65) : color,
        ),
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
    final p = ErasPalette.of(context);

    return AlertDialog(
      backgroundColor: p.surface,
      surfaceTintColor: Colors.transparent,
      title: Text(
        widget.resource == null
            ? 'New resource'
            : 'Edit ${widget.resource!.name}',
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w700,
          color: p.text,
        ),
      ),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _field('Name', nameController, p),
              _field(
                'Type',
                typeController,
                p,
                hint: 'AMBULANCE, OXYGEN, FIRE…',
              ),
              // This content is 460px wide, but AlertDialog clamps to the
              // viewport, and two half-width fields per row collide on a
              // phone. The decision therefore comes from the VIEWPORT, not
              // from a LayoutBuilder: AlertDialog measures its content with
              // IntrinsicWidth, and LayoutBuilder cannot report intrinsic
              // dimensions (it throws during performLayout).
              ..._pairedFields(
                wide: MediaQuery.sizeOf(context).width >= 500,
                first: _field('Total quantity', totalController, p),
                second: _field('Available quantity', availableController, p),
                third: _field(
                  'Unit',
                  unitController,
                  p,
                  hint: 'vehicle, unit, cylinder…',
                ),
                fourth: _field('Location', locationController, p),
              ),
              _field('Low stock threshold', thresholdController, p),
              if (error != null) ...[
                const SizedBox(height: 8),
                Text(
                  error!,
                  style: TextStyle(fontSize: 12.5, color: p.red),
                ),
              ],
            ],
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
          child: FilledButton(
            onPressed: save,
            style: FilledButton.styleFrom(
              backgroundColor: p.teal,
              foregroundColor: Colors.white,
            ),
            child: const Text('Save'),
          ),
        ),
      ],
    );
  }

  /// Two label/field pairs, side by side on wide viewports and stacked on
  /// narrow ones. `IntrinsicWidth`-safe: it is pure composition, no layout
  /// measurement.
  List<Widget> _pairedFields({
    required bool wide,
    required Widget first,
    required Widget second,
    required Widget third,
    required Widget fourth,
  }) {
    if (wide) {
      return <Widget>[
        Row(
          children: [
            Expanded(child: first),
            const SizedBox(width: 10),
            Expanded(child: second),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(child: third),
            const SizedBox(width: 10),
            Expanded(child: fourth),
          ],
        ),
      ];
    }
    return <Widget>[
      first,
      const SizedBox(height: 8),
      second,
      const SizedBox(height: 8),
      third,
      const SizedBox(height: 8),
      fourth,
    ];
  }

  Widget _field(
    String label,
    TextEditingController controller,
    ErasPalette p, {
    String? hint,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FieldLabel(label),
          const SizedBox(height: 5),
          FocusGlow(
            glowColor: p.teal,
            borderRadius: 8,
            child: TextField(
              controller: controller,
              style: TextStyle(fontSize: 13, color: p.text),
              decoration: fieldDecoration(hintText: hint, context: context),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Responder help types ───────────────────────────────────────────────────

class ResponderHelpTypesPanel extends StatelessWidget {
  const ResponderHelpTypesPanel({
    super.key,
    required this.helpTypes,
    this.title = 'MY HELP TYPES',
    this.onEditHelpTypes,
  });

  final List<ResponderHelpType> helpTypes;
  final String title;
  final VoidCallback? onEditHelpTypes;

  @override
  Widget build(BuildContext context) {
    final p = ErasPalette.of(context);
    final activeTypes = helpTypes.where((ht) => ht.enabled).toList();

    return Panel(
      title: title,
      hint: 'Categories loaded from GET /api/responders/help-types',
      child: activeTypes.isEmpty
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const EmptyState(
                  'No emergency help types configured yet. Edit your help types to choose which categories of emergencies you can respond to.',
                  title: 'NO HELP TYPES CONFIGURED',
                  icon: Icons.category_outlined,
                ),
                if (onEditHelpTypes != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: PressableScale(
                      child: OutlinedButton.icon(
                        onPressed: onEditHelpTypes,
                        icon: const Icon(Icons.edit_outlined, size: 16),
                        style: OutlinedButton.styleFrom(
                          backgroundColor:
                              p.dark ? p.surface2 : Colors.transparent,
                          foregroundColor: p.text,
                          side: BorderSide(color: p.border),
                        ),
                        label: const Text('EDIT MY HELP TYPES'),
                      ),
                    ),
                  ),
              ],
            )
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: activeTypes.map((ht) {
                      return Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: p.tealDim,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                            color: p.teal.withValues(alpha: p.dark ? .45 : .3),
                          ),
                        ),
                        child: Text(
                          ht.displayLabel.toUpperCase(),
                          style: monoStyle(
                            size: 12,
                            color: p.teal,
                            weight: FontWeight.w700,
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  if (onEditHelpTypes != null) ...[
                    const SizedBox(height: 14),
                    PressableScale(
                      child: OutlinedButton.icon(
                        onPressed: onEditHelpTypes,
                        icon: const Icon(Icons.edit_outlined, size: 16),
                        style: OutlinedButton.styleFrom(
                          backgroundColor:
                              p.dark ? p.surface2 : Colors.transparent,
                          foregroundColor: p.text,
                          side: BorderSide(color: p.border),
                        ),
                        label: const Text('EDIT MY HELP TYPES'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
    );
  }
}

// ── Responder inventory ────────────────────────────────────────────────────

class ResponderResourcesPanel extends StatelessWidget {
  const ResponderResourcesPanel({
    super.key,
    required this.resources,
    this.title = 'RESOURCE INVENTORY',
    this.onEditInventory,
  });

  final List<BackendResponderResource> resources;
  final String title;
  final VoidCallback? onEditInventory;

  @override
  Widget build(BuildContext context) {
    final p = ErasPalette.of(context);

    return Panel(
      title: title,
      hint: 'Responder resource rows',
      trailing: onEditInventory == null
          ? null
          : TextButton.icon(
              onPressed: onEditInventory,
              icon: const Icon(Icons.tune, size: 15),
              style: TextButton.styleFrom(foregroundColor: p.teal),
              label:
                  const Text('EDIT INVENTORY', style: TextStyle(fontSize: 11)),
            ),
      child: resources.isEmpty
          ? const EmptyState(
              'No inventory rows for this responder yet. Inventory is loaded '
              'from the ResponderResource table.',
              title: 'NO INVENTORY',
              icon: Icons.inventory_2_outlined,
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: resources.map((item) {
                final meta = resourceMetaFor(
                  item.resourceType.isEmpty
                      ? item.resourceName
                      : item.resourceType,
                  p,
                );

                final statusColor = responderStatusColor(item.status, p);

                return Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: p.border)),
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
                      // Resource name is the primary label (nested resource
                      // data from the backend), with the type as context.
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              item.resourceName,
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                                color: p.text,
                              ),
                            ),
                            if (item.resourceType.isNotEmpty ||
                                item.unit != null) ...[
                              const SizedBox(height: 2),
                              Text(
                                [
                                  if (item.resourceType.isNotEmpty)
                                    item.resourceType,
                                  if (item.unit != null) item.unit!,
                                ].join(' · '),
                                style: TextStyle(
                                  fontSize: 11,
                                  color: p.textFaint,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      // Available / Total
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '${item.availableQuantity} / ${item.totalQuantity}',
                            style: monoStyle(
                              size: 13,
                              color: p.text,
                              weight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            item.isEnabled ? 'ENABLED' : 'DISABLED',
                            style: monoStyle(
                              size: 9.5,
                              color: item.isEnabled ? p.teal : p.textFaint,
                              weight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: statusColor.withValues(
                                alpha: p.dark ? .18 : .12,
                              ),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              item.status,
                              style: monoStyle(
                                size: 10,
                                color: statusColor,
                                weight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
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
    final p = ErasPalette.of(context);

    return Panel(
      title: 'LIVE RESPONDERS',
      hint: 'Responders data',
      child: responders.isEmpty
          ? const EmptyState('No responders found.')
          : Column(
              children: [
                for (var i = 0; i < responders.length; i++)
                  EntranceReveal(
                    delay:
                        i < 6 ? Duration(milliseconds: 22 * i) : Duration.zero,
                    offset: const Offset(0, 5),
                    child: _responderRow(responders[i], p),
                  ),
              ],
            ),
    );
  }

  Widget _responderRow(BackendResponder r, ErasPalette p) {
    final color = responderStatusColor(r.status, p);

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: isMobile ? 14 : 16,
        vertical: 12,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: p.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${r.name}  •  ID ${r.id}',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: p.text,
                  ),
                ),
                const SizedBox(height: 4),
                // RESPONDER CONTACT PRIVACY: the responder directory is shared
                // by every role, so email/phone render for ADMIN only. The
                // backend omits both fields for any other viewer.
                if (ApiService.isAdmin && r.email.isNotEmpty)
                  Text(
                    r.email,
                    style: TextStyle(fontSize: 11.5, color: p.textFaint),
                  ),
                if (ApiService.isAdmin && (r.phone ?? '').isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    r.phone!,
                    style: TextStyle(fontSize: 11.5, color: p.textFaint),
                  ),
                ],
                if (r.location != null && r.location!.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    r.location!,
                    style: TextStyle(fontSize: 11.5, color: p.textDim),
                  ),
                ],
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: color.withValues(alpha: p.dark ? .16 : .1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              r.status,
              style: monoStyle(
                size: 11,
                color: color,
                weight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
