import 'package:flutter/material.dart';

import '../models/eras_models.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/auth_motion.dart';

abstract class ResponderReadinessGateway {
  Future<Map<String, dynamic>> getHelpTypes();
  Future<List<dynamic>> getResources();
  Future<List<dynamic>> getInventory();
  Future<void> updateHelpTypes(Iterable<String> values);
  Future<void> createInventory(Map<String, dynamic> data);
  Future<void> updateInventory(int id, Map<String, dynamic> data);
  Future<void> setAvailable();
  Future<void> heartbeat();
}

class _ApiResponderReadinessGateway implements ResponderReadinessGateway {
  @override
  Future<Map<String, dynamic>> getHelpTypes() =>
      ApiService.getResponderHelpTypes();
  @override
  Future<List<dynamic>> getResources() => ApiService.getResources();
  @override
  Future<List<dynamic>> getInventory() => ApiService.getResponderResources();
  @override
  Future<void> updateHelpTypes(Iterable<String> values) async {
    await ApiService.updateResponderHelpTypes(values);
  }

  @override
  Future<void> createInventory(Map<String, dynamic> data) async {
    await ApiService.createResponderResource(data);
  }

  @override
  Future<void> updateInventory(int id, Map<String, dynamic> data) async {
    await ApiService.updateResponderResource(id, data);
  }

  @override
  Future<void> setAvailable() => ApiService.setResponderStatus('AVAILABLE');
  @override
  Future<void> heartbeat() => ApiService.responderHeartbeat();
}

/// Responder category readiness and optional physical inventory.
///
/// Help types come from GET /api/responders/help-types and determine which
/// emergencies the responder may discover. Resource/ResponderResource rows
/// remain a separate allocation concern and may be completely empty.
class ResponderReadinessPage extends StatefulWidget {
  const ResponderReadinessPage({
    super.key,
    this.onSaved,
    this.gateway,
  });

  final VoidCallback? onSaved;
  final ResponderReadinessGateway? gateway;

  @override
  State<ResponderReadinessPage> createState() => _ResponderReadinessPageState();
}

class _ResponderReadinessPageState extends State<ResponderReadinessPage> {
  late final ResponderReadinessGateway _gateway =
      widget.gateway ?? _ApiResponderReadinessGateway();

  final List<Map<String, String>> _helpTypes = <Map<String, String>>[];
  final Set<String> _selectedHelpTypes = <String>{};

  final List<BackendResource> _resources = <BackendResource>[];
  final Map<int, BackendResponderResource> _inventoryByResourceId =
      <int, BackendResponderResource>{};
  final Map<int, bool> _inventoryEnabled = <int, bool>{};
  final Map<int, int> _available = <int, int>{};
  final Map<int, int> _total = <int, int>{};
  final Map<int, bool> _availableEdited = <int, bool>{};

  bool _loading = true;
  bool _saving = false;
  bool _editingHelpTypes = false;
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
      final results = await Future.wait<dynamic>(<Future<dynamic>>[
        _gateway.getHelpTypes(),
        _gateway.getResources(),
        _gateway.getInventory(),
      ]);
      final helpResponse = Map<String, dynamic>.from(results[0] as Map);
      final categories =
          (helpResponse['categories'] as List<dynamic>? ?? <dynamic>[])
              .map((item) => Map<String, dynamic>.from(item as Map))
              .map((item) => <String, String>{
                    'value': item['value'].toString(),
                    'label': item['label'].toString(),
                  })
              .toList();
      final selected =
          (helpResponse['selected'] as List<dynamic>? ?? <dynamic>[])
              .map((item) => item.toString())
              .toSet();
      final resources = (results[1] as List<dynamic>)
          .map((item) =>
              BackendResource.fromJson(Map<String, dynamic>.from(item as Map)))
          .where((resource) => resource.isActive)
          .toList();
      final inventory = (results[2] as List<dynamic>)
          .map((item) => BackendResponderResource.fromJson(
              Map<String, dynamic>.from(item as Map)))
          .toList();

      if (!mounted) return;
      setState(() {
        _helpTypes
          ..clear()
          ..addAll(categories);
        _selectedHelpTypes
          ..clear()
          ..addAll(selected);
        // New responders immediately see editable choices; returning
        // responders get a concise summary until they choose Edit.
        _editingHelpTypes = selected.isEmpty;

        _resources
          ..clear()
          ..addAll(resources);
        _inventoryByResourceId
          ..clear()
          ..addEntries(
              inventory.map((item) => MapEntry(item.resourceId, item)));
        _inventoryEnabled
          ..clear()
          ..addEntries(resources.map((resource) => MapEntry(resource.id,
              _inventoryByResourceId[resource.id]?.isEnabled ?? false)));
        _available
          ..clear()
          ..addEntries(resources.map((resource) => MapEntry(resource.id,
              _inventoryByResourceId[resource.id]?.availableQuantity ?? 0)));
        _total
          ..clear()
          ..addEntries(resources.map((resource) => MapEntry(resource.id,
              _inventoryByResourceId[resource.id]?.totalQuantity ?? 0)));
        _availableEdited.clear();
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
    if (_selectedHelpTypes.isEmpty) {
      setState(() {
        _notice = 'Select at least one emergency help type to go available.';
        _editingHelpTypes = true;
      });
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
      _notice = null;
    });

    try {
      await _gateway.updateHelpTypes(_selectedHelpTypes);

      // Inventory remains optional. Existing allocation semantics are retained
      // whenever a catalog row and responder inventory row do exist.
      for (final resource in _resources) {
        final existing = _inventoryByResourceId[resource.id];
        final isEnabled = _inventoryEnabled[resource.id] ?? false;
        final available = _available[resource.id] ?? 0;

        final total = _total[resource.id] ?? 0;
        if (available < 0 || total < 0 || available > total) {
          throw Exception(
            '${resource.name}: available quantity must be between 0 and total quantity.',
          );
        }
        if (existing == null) {
          // An empty form is not an inventory row. This prevents readiness
          // from silently creating zero-quantity resources.
          if (total > 0 || available > 0 || isEnabled) {
            await _gateway.createInventory(<String, dynamic>{
              'resourceId': resource.id,
              'totalQuantity': total,
              'availableQuantity': available,
              'isEnabled': isEnabled,
              'status': available > 0 ? 'AVAILABLE' : 'UNAVAILABLE',
            });
          }
          continue;
        }

        await _gateway.updateInventory(existing.id, <String, dynamic>{
          'totalQuantity': total,
          'availableQuantity': available,
          'isEnabled': isEnabled,
          'status': available > 0 && isEnabled ? 'AVAILABLE' : 'UNAVAILABLE',
        });
      }

      await _gateway.setAvailable();
      await _gateway.heartbeat();

      if (!mounted) return;
      // The save completed: leave the transient saving state so the page is
      // interactable again when the caller keeps it mounted instead of
      // navigating away below (the button would otherwise spin forever).
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('You are available for your selected help types.'),
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

  @override
  Widget build(BuildContext context) {
    final p = ErasPalette.of(context);

    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(
        backgroundColor: p.header,
        surfaceTintColor: Colors.transparent,
        foregroundColor: p.text,
        title: Text(
          'Responder readiness',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: p.text,
          ),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: _loading
                ? Center(child: CircularProgressIndicator(color: p.teal))
                : ListView(
                    padding: const EdgeInsets.all(16),
                    children: <Widget>[
                      if (_error != null) _message(_error!, p.red),
                      if (_notice != null) _message(_notice!, p.amber),
                      EntranceReveal(
                        offset: const Offset(0, 8),
                        child: _helpTypeSection(p),
                      ),
                      const SizedBox(height: 22),
                      EntranceReveal(
                        delay: const Duration(milliseconds: 60),
                        offset: const Offset(0, 8),
                        child: _inventorySection(p),
                      ),
                      const SizedBox(height: 18),
                      HoverLift(
                        enabled: !_saving,
                        lift: 1.2,
                        builder: (context, hovered) => PressableScale(
                          enabled: !_saving,
                          child: FilledButton(
                            onPressed: _saving ? null : _saveAndContinue,
                            style: FilledButton.styleFrom(
                              backgroundColor: p.teal,
                              foregroundColor: Colors.white,
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
                                : const Text('SAVE INVENTORY & GO AVAILABLE'),
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  Widget _helpTypeSection(ErasPalette p) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'WHAT CAN YOU HELP WITH?',
            style: TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.w700,
              color: p.text,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'These emergency categories determine which requests you receive. '
            'They do not depend on your resource inventory.',
            style: TextStyle(fontSize: 12.5, color: p.textDim),
          ),
          const SizedBox(height: 12),
          if (_helpTypes.isEmpty)
            _message('No emergency help types are configured.', p.red)
          else if (_editingHelpTypes)
            Container(
              key: const Key('help-type-selector'),
              decoration: BoxDecoration(
                color: p.surface,
                border: Border.all(color: p.cardBorder),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                children: _helpTypes.map((item) {
                  final value = item['value']!;
                  // CheckboxListTile uses InkWell for its tap feedback. Give
                  // every tile its own Material ancestor so the splash and
                  // selected state remain visible even though the selector is
                  // inside a bordered surface container.
                  return Material(
                    color: p.surface,
                    child: CheckboxListTile(
                      key: Key('help-type-$value'),
                      dense: true,
                      value: _selectedHelpTypes.contains(value),
                      activeColor: p.teal,
                      checkColor: Colors.white,
                      title: Text(
                        item['label']!,
                        style: TextStyle(color: p.text, fontSize: 13.5),
                      ),
                      onChanged: _saving
                          ? null
                          : (checked) => setState(() {
                                if (checked ?? false) {
                                  _selectedHelpTypes.add(value);
                                } else {
                                  _selectedHelpTypes.remove(value);
                                }
                                _notice = null;
                              }),
                    ),
                  );
                }).toList(),
              ),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: _helpTypes
                  .where((item) => _selectedHelpTypes.contains(item['value']!))
                  .map(
                    (item) => Chip(
                      backgroundColor: p.tealDim,
                      side: BorderSide(color: p.teal.withValues(alpha: .4)),
                      label: Text(
                        item['label']!,
                        style: TextStyle(
                          color: p.teal,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          const SizedBox(height: 10),
          PressableScale(
            child: OutlinedButton.icon(
              key: const Key('edit-help-types'),
              onPressed: _saving ? null : _toggleEditHelpTypes,
              style: OutlinedButton.styleFrom(
                backgroundColor: p.dark ? p.surface2 : Colors.transparent,
                foregroundColor: p.text,
                side: BorderSide(color: p.border),
              ),
              icon: const Icon(Icons.edit_outlined, size: 17),
              label: Text(
                _editingHelpTypes
                    ? 'DONE EDITING HELP TYPES'
                    : 'EDIT MY HELP TYPES',
              ),
            ),
          ),
        ],
      );

  void _toggleEditHelpTypes() {
    setState(() => _editingHelpTypes = !_editingHelpTypes);
  }

  void _toggleQuantityControls() {
    setState(() => _showQuantityControls = !_showQuantityControls);
  }

  Widget _inventorySection(ErasPalette p) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'RESOURCE INVENTORY (OPTIONAL)',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: p.text,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Physical and reusable resources are managed separately and are '
            'checked when resources are allocated.',
            style: TextStyle(fontSize: 12.5, color: p.textDim),
          ),
          const SizedBox(height: 12),
          if (_resources.isEmpty)
            _message(
              'No active resources are available in the catalog yet. You can still choose '
              'your emergency help types and go available.',
              p.textFaint,
            )
          else ...<Widget>[
            Container(
              key: const Key('resource-inventory'),
              decoration: BoxDecoration(
                color: p.surface,
                border: Border.all(color: p.cardBorder),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                children: _resources.map((r) => _resourceRow(r, p)).toList(),
              ),
            ),
            const SizedBox(height: 10),
            PressableScale(
              child: OutlinedButton.icon(
                onPressed: _saving ? null : _toggleQuantityControls,
                style: OutlinedButton.styleFrom(
                  backgroundColor: p.dark ? p.surface2 : Colors.transparent,
                  foregroundColor: p.text,
                  side: BorderSide(color: p.border),
                ),
                icon: const Icon(Icons.inventory_2_outlined, size: 17),
                label: const Text('EDIT RESOURCE INVENTORY'),
              ),
            ),
          ],
        ],
      );

  Widget _message(String text, Color color) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: color.withValues(alpha: .14),
            border: Border.all(color: color.withValues(alpha: .35)),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(text, style: TextStyle(fontSize: 12.5, color: color)),
        ),
      );

  Widget _quantityField(
    BackendResource resource,
    String label,
    int value,
    ValueChanged<String> onChanged,
    ErasPalette p,
  ) {
    return FocusGlow(
      glowColor: p.teal,
      borderRadius: 8,
      child: TextFormField(
        key: Key('${label.toLowerCase().replaceAll(' ', '-')}-${resource.id}'),
        initialValue: value.toString(),
        enabled: !_saving,
        keyboardType: TextInputType.number,
        style: TextStyle(fontSize: 13, color: p.text),
        decoration: fieldDecoration(context: context).copyWith(
          labelText: label,
          labelStyle: TextStyle(fontSize: 12, color: p.textDim),
        ),
        onChanged: onChanged,
      ),
    );
  }

  /// One resource row of the responder inventory editor.
  ///
  /// Layout is responsive on purpose: the "Total quantity" / "Available
  /// quantity" fields sit side by side on wide surfaces and stack vertically on
  /// narrow ones, and the trailing availability chip is only rendered when
  /// there is room for it. That removes the collision between the two fields
  /// (and between the availability chip and the "No responder inventory
  /// assigned" caption) on small Android viewports.
  Widget _resourceRow(BackendResource resource, ErasPalette p) {
    final row = _inventoryByResourceId[resource.id];
    final selected = _inventoryEnabled[resource.id] ?? false;
    final available = _available[resource.id] ?? 0;
    final unit = resource.unit == null || resource.unit!.isEmpty
        ? 'unit'
        : resource.unit!;
    final isService = resource.isService;
    final statusText = isService
        ? 'Reusable resource · no quantity to track'
        : row == null
            ? 'No responder inventory assigned'
            : '$available / ${row.totalQuantity} $unit · ${row.status}';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: p.border)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Below this width the two quantity fields and the availability chip
          // no longer fit next to the resource name without colliding.
          final wide = constraints.maxWidth >= 460;

          return Column(
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Checkbox(
                    value: selected,
                    onChanged: _saving
                        ? null
                        : (value) => setState(
                              () => _inventoryEnabled[resource.id] =
                                  value ?? false,
                            ),
                    activeColor: p.teal,
                    checkColor: Colors.white,
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          resource.name,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: p.text,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          statusText,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: p.textFaint,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  // Only reserve space for the chip when the row is wide
                  // enough that it cannot collide with the caption above.
                  if (!isService && wide)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Text(
                        '$available $unit',
                        style: TextStyle(fontSize: 12.5, color: p.textDim),
                      ),
                    ),
                ],
              ),
              if (!isService)
                Padding(
                  padding: const EdgeInsets.only(left: 48, right: 6, bottom: 6),
                  child: wide
                      ? Row(
                          children: <Widget>[
                            Expanded(
                              child: _quantityField(
                                resource,
                                'Total quantity',
                                _total[resource.id] ?? 0,
                                (value) {
                                  final next = int.tryParse(value) ?? 0;
                                  setState(() {
                                    _total[resource.id] = next;
                                    if (!(_availableEdited[resource.id] ??
                                        false)) {
                                      _available[resource.id] = next;
                                    }
                                  });
                                },
                                p,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _quantityField(
                                resource,
                                'Available quantity',
                                available,
                                (value) {
                                  setState(() {
                                    _available[resource.id] =
                                        int.tryParse(value) ?? 0;
                                    _availableEdited[resource.id] = true;
                                  });
                                },
                                p,
                              ),
                            ),
                          ],
                        )
                      : Column(
                          children: <Widget>[
                            _quantityField(
                              resource,
                              'Total quantity',
                              _total[resource.id] ?? 0,
                              (value) {
                                final next = int.tryParse(value) ?? 0;
                                setState(() {
                                  _total[resource.id] = next;
                                  if (!(_availableEdited[resource.id] ??
                                      false)) {
                                    _available[resource.id] = next;
                                  }
                                });
                              },
                              p,
                            ),
                            const SizedBox(height: 8),
                            _quantityField(
                              resource,
                              'Available quantity',
                              available,
                              (value) {
                                setState(() {
                                  _available[resource.id] =
                                      int.tryParse(value) ?? 0;
                                  _availableEdited[resource.id] = true;
                                });
                              },
                              p,
                            ),
                          ],
                        ),
                ),
            ],
          );
        },
      ),
    );
  }
}
