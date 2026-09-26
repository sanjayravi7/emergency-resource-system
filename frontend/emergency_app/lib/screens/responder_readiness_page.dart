import 'package:flutter/material.dart';

import '../Services/api_service.dart';
import '../models/eras_models.dart';
import '../theme/app_theme.dart';

/// First responder screen after login. The catalog is loaded dynamically from
/// PostgreSQL and the checkboxes only control ResponderResource.isEnabled.
/// Resource IDs, names, units, and quantities all come from API responses.
class ResponderReadinessPage extends StatefulWidget {
  const ResponderReadinessPage({super.key, this.onSaved});

  /// Login supplies this to replace the page with the dispatch board. The
  /// Resources section leaves it null and simply pops back after saving.
  final VoidCallback? onSaved;

  @override
  State<ResponderReadinessPage> createState() => _ResponderReadinessPageState();
}

class _ResponderReadinessPageState extends State<ResponderReadinessPage> {
  final List<BackendResource> _resources = <BackendResource>[];
  final Map<int, BackendResponderResource> _inventoryByResourceId =
      <int, BackendResponderResource>{};
  final Map<int, bool> _selected = <int, bool>{};
  final Map<int, int> _available = <int, int>{};

  bool _loading = true;
  bool _saving = false;
  bool _showQuantityControls = false;
  String? _error;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final results = await Future.wait<List<dynamic>>(<Future<List<dynamic>>>[
        ApiService.getResources(),
        ApiService.getResponderResources(),
      ]);
      final resources = results[0]
          .map(
            (item) => BackendResource.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .where((resource) => resource.isActive)
          .toList();
      final inventory = results[1]
          .map(
            (item) => BackendResponderResource.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList();

      if (!mounted) return;
      setState(() {
        _resources
          ..clear()
          ..addAll(resources);
        _inventoryByResourceId
          ..clear()
          ..addEntries(
            inventory.map((item) => MapEntry(item.resourceId, item)),
          );
        _selected
          ..clear()
          ..addEntries(
            resources.map((resource) {
              final row = _inventoryByResourceId[resource.id];
              return MapEntry(resource.id, row?.isEnabled ?? false);
            }),
          );
        _available
          ..clear()
          ..addEntries(
            resources.map((resource) {
              final row = _inventoryByResourceId[resource.id];
              return MapEntry(resource.id, row?.availableQuantity ?? 0);
            }),
          );
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _saveAndContinue() async {
    final selectedCount = _selected.values.where((value) => value).length;
    setState(() {
      _saving = true;
      _error = null;
      _notice = null;
    });

    try {
      for (final resource in _resources) {
        final existing = _inventoryByResourceId[resource.id];
        final isEnabled = _selected[resource.id] ?? false;
        final available = _available[resource.id] ?? 0;

        if (existing == null) {
          // A catalog item with no inventory row starts at zero. It can be
          // selected now, but cannot make the responder compatible until real
          // inventory is added through the normal inventory workflow.
          if (isEnabled) {
            await ApiService.createResponderResource(<String, dynamic>{
              'resourceId': resource.id,
              'totalQuantity': 0,
              'availableQuantity': 0,
              'isEnabled': true,
              'status': 'UNAVAILABLE',
            });
          }
          continue;
        }

        await ApiService.updateResponderResource(existing.id, <String, dynamic>{
          'isEnabled': isEnabled,
          'availableQuantity': available,
          'status': available == 0
              ? 'UNAVAILABLE'
              : isEnabled
                  ? 'AVAILABLE'
                  : existing.status,
        });
      }

      // Existing inventory updates invoke backend lifecycle sync. With no
      // inventory rows at all, explicitly mark the responder offline.
      if (selectedCount == 0 && _inventoryByResourceId.isEmpty) {
        await ApiService.setResponderStatus('OFFLINE');
      }

      // Save is responder activity too. A heartbeat failure is surfaced here,
      // but does not cause the backend to alter an existing assignment.
      await ApiService.responderHeartbeat();

      if (!mounted) return;
      if (selectedCount == 0) {
        setState(() {
          _saving = false;
          _notice = 'Select at least one resource you are willing to provide.';
        });
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('You are now available for selected resources.'),
          behavior: SnackBarBehavior.floating,
        ),
      );

      if (widget.onSaved != null) {
        widget.onSaved!();
      } else {
        Navigator.of(context).pop(true);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = error.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  void _adjustAvailable(BackendResource resource, int delta) {
    final row = _inventoryByResourceId[resource.id];
    if (row == null) return;

    final current = _available[resource.id] ?? row.availableQuantity;
    final next = (current + delta).clamp(0, row.totalQuantity).toInt();
    setState(() => _available[resource.id] = next);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        title: const Text(
          'Responder readiness',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    padding: const EdgeInsets.all(16),
                    children: <Widget>[
                      const Text(
                        'Choose the resources you are willing to help with',
                        style: TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w700,
                          color: AppColors.text,
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Help types are separate from live inventory. Only enabled '
                        'resources with available stock can receive requests.',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: AppColors.textDim,
                        ),
                      ),
                      const SizedBox(height: 16),
                      if (_error != null) _message(_error!, AppColors.red),
                      if (_notice != null) _message(_notice!, AppColors.amber),
                      if (_resources.isEmpty)
                        _message(
                          'No active resources are available in the catalog.',
                          AppColors.textFaint,
                        )
                      else
                        Container(
                          decoration: BoxDecoration(
                            color: AppColors.surface,
                            border: Border.all(color: AppColors.border),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Column(
                            children: _resources
                                .map((resource) => _resourceRow(resource))
                                .toList(),
                          ),
                        ),
                      const SizedBox(height: 14),
                      OutlinedButton.icon(
                        onPressed: _saving
                            ? null
                            : () => setState(
                                  () => _showQuantityControls =
                                      !_showQuantityControls,
                                ),
                        icon: const Icon(Icons.tune, size: 17),
                        label: const Text('EDIT MY HELP TYPES'),
                      ),
                      const SizedBox(height: 10),
                      FilledButton(
                        onPressed: _saving ? null : _saveAndContinue,
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.teal,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: _saving
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Text('SAVE & GO AVAILABLE'),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  Widget _message(String text, Color color) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: color.withValues(alpha: .12),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Text(text, style: TextStyle(fontSize: 12.5, color: color)),
        ),
      );

  Widget _resourceRow(BackendResource resource) {
    final row = _inventoryByResourceId[resource.id];
    final selected = _selected[resource.id] ?? false;
    final available = _available[resource.id] ?? 0;
    final unit = resource.unit == null || resource.unit!.isEmpty
        ? 'unit'
        : resource.unit!;
    // SERVICE resources (e.g. Ambulance, Volunteer) are a reusable
    // responder capability: selection is the checkbox alone, there is no
    // inventory to size. CONSUMABLE resources (e.g. Blood) still pair the
    // checkbox with the quantity the responder is carrying. This branches
    // strictly on resource.mode, coming from the backend.
    final isService = resource.isService;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Column(
        children: <Widget>[
          Row(
            children: <Widget>[
              Checkbox(
                value: selected,
                onChanged: _saving
                    ? null
                    : (value) => setState(
                          () => _selected[resource.id] = value ?? false,
                        ),
                activeColor: AppColors.teal,
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      resource.name,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      isService
                          ? 'Reusable capability · no inventory to track'
                          : row == null
                              ? 'No responder inventory assigned'
                              : '$available / ${row.totalQuantity} $unit · ${row.status}',
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: AppColors.textFaint,
                      ),
                    ),
                  ],
                ),
              ),
              if (!isService)
                Text(
                  '$available $unit',
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: AppColors.textDim,
                  ),
                ),
            ],
          ),
          if (!isService && _showQuantityControls && row != null)
            Padding(
              padding: const EdgeInsets.only(left: 48, right: 6, bottom: 4),
              child: Row(
                children: <Widget>[
                  const Text(
                    'Available quantity',
                    style: TextStyle(fontSize: 11.5, color: AppColors.textDim),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: _saving || available <= 0
                        ? null
                        : () => _adjustAvailable(resource, -1),
                    icon: const Icon(Icons.remove, size: 17),
                  ),
                  Text(
                    '$available',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  IconButton(
                    onPressed: _saving || available >= row.totalQuantity
                        ? null
                        : () => _adjustAvailable(resource, 1),
                    icon: const Icon(Icons.add, size: 17),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
