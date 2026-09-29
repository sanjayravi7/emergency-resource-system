import 'package:flutter/material.dart';

import '../models/eras_models.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';

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
      final categories = (helpResponse['categories'] as List<dynamic>? ??
              <dynamic>[])
          .map((item) => Map<String, dynamic>.from(item as Map))
          .map((item) => <String, String>{
                'value': item['value'].toString(),
                'label': item['label'].toString(),
              })
          .toList();
      final selected = (helpResponse['selected'] as List<dynamic>? ??
              <dynamic>[])
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
          ..addEntries(inventory.map((item) => MapEntry(item.resourceId, item)));
        _inventoryEnabled
          ..clear()
          ..addEntries(resources.map((resource) => MapEntry(
              resource.id,
              _inventoryByResourceId[resource.id]?.isEnabled ?? false)));
        _available
          ..clear()
          ..addEntries(resources.map((resource) => MapEntry(
              resource.id,
              _inventoryByResourceId[resource.id]?.availableQuantity ?? 0)));
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

        if (existing == null) {
          if (isEnabled) {
            await _gateway.createInventory(<String, dynamic>{
              'resourceId': resource.id,
              'totalQuantity': 0,
              'availableQuantity': 0,
              'isEnabled': true,
              'status': 'UNAVAILABLE',
            });
          }
          continue;
        }

        await _gateway.updateInventory(existing.id, <String, dynamic>{
          'isEnabled': isEnabled,
          'availableQuantity': available,
          'status': available == 0
              ? 'UNAVAILABLE'
              : isEnabled
                  ? 'AVAILABLE'
                  : existing.status,
        });
      }

      await _gateway.setAvailable();
      await _gateway.heartbeat();

      if (!mounted) return;
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
        title: const Text('Responder readiness',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
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
                      if (_error != null) _message(_error!, AppColors.red),
                      if (_notice != null) _message(_notice!, AppColors.amber),
                      _helpTypeSection(),
                      const SizedBox(height: 22),
                      _inventorySection(),
                      const SizedBox(height: 18),
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
                                    strokeWidth: 2, color: Colors.white),
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

  Widget _helpTypeSection() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text('WHAT CAN YOU HELP WITH?',
              style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                  color: AppColors.text)),
          const SizedBox(height: 6),
          const Text(
            'These emergency categories determine which requests you receive. '
            'They do not depend on your resource inventory.',
            style: TextStyle(fontSize: 12.5, color: AppColors.textDim),
          ),
          const SizedBox(height: 12),
          if (_helpTypes.isEmpty)
            _message('No emergency help types are configured.', AppColors.red)
          else if (_editingHelpTypes)
            Container(
              key: const Key('help-type-selector'),
              decoration: BoxDecoration(
                color: AppColors.surface,
                border: Border.all(color: AppColors.border),
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
                    color: AppColors.surface,
                    child: CheckboxListTile(
                      key: Key('help-type-$value'),
                      dense: true,
                      value: _selectedHelpTypes.contains(value),
                      activeColor: AppColors.teal,
                      title: Text(item['label']!),
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
                  .where((item) =>
                      _selectedHelpTypes.contains(item['value']!))
                  .map((item) => Chip(label: Text(item['label']!)))
                  .toList(),
            ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            key: const Key('edit-help-types'),
            onPressed: _saving
                ? null
                : () => setState(() {
                      _editingHelpTypes = !_editingHelpTypes;
                    }),
            icon: const Icon(Icons.edit_outlined, size: 17),
            label: Text(
                _editingHelpTypes ? 'DONE EDITING HELP TYPES' : 'EDIT MY HELP TYPES'),
          ),
        ],
      );

  Widget _inventorySection() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text('RESOURCE INVENTORY (OPTIONAL)',
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppColors.text)),
          const SizedBox(height: 6),
          const Text(
            'Physical and reusable resources are managed separately and are '
            'checked when resources are allocated.',
            style: TextStyle(fontSize: 12.5, color: AppColors.textDim),
          ),
          const SizedBox(height: 12),
          if (_resources.isEmpty)
            _message(
              'No resource inventory is configured yet. You can still choose '
              'your emergency help types and go available.',
              AppColors.textFaint,
            )
          else ...<Widget>[
            Container(
              key: const Key('resource-inventory'),
              decoration: BoxDecoration(
                color: AppColors.surface,
                border: Border.all(color: AppColors.border),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                children: _resources.map(_resourceRow).toList(),
              ),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: _saving
                  ? null
                  : () => setState(() =>
                      _showQuantityControls = !_showQuantityControls),
              icon: const Icon(Icons.inventory_2_outlined, size: 17),
              label: const Text('EDIT RESOURCE INVENTORY'),
            ),
          ],
        ],
      );

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
    final selected = _inventoryEnabled[resource.id] ?? false;
    final available = _available[resource.id] ?? 0;
    final unit = resource.unit == null || resource.unit!.isEmpty
        ? 'unit'
        : resource.unit!;
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
                    : (value) => setState(() =>
                        _inventoryEnabled[resource.id] = value ?? false),
                activeColor: AppColors.teal,
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(resource.name,
                        style: const TextStyle(
                            fontSize: 13.5, fontWeight: FontWeight.w600)),
                    Text(
                      isService
                          ? 'Reusable resource · no quantity to track'
                          : row == null
                              ? 'No responder inventory assigned'
                              : '$available / ${row.totalQuantity} $unit · ${row.status}',
                      style: const TextStyle(
                          fontSize: 11.5, color: AppColors.textFaint),
                    ),
                  ],
                ),
              ),
              if (!isService)
                Text('$available $unit',
                    style: const TextStyle(
                        fontSize: 12.5, color: AppColors.textDim)),
            ],
          ),
          if (!isService && _showQuantityControls && row != null)
            Padding(
              padding: const EdgeInsets.only(left: 48, right: 6, bottom: 4),
              child: Row(
                children: <Widget>[
                  const Text('Available quantity',
                      style:
                          TextStyle(fontSize: 11.5, color: AppColors.textDim)),
                  const Spacer(),
                  IconButton(
                    onPressed: _saving || available <= 0
                        ? null
                        : () => _adjustAvailable(resource, -1),
                    icon: const Icon(Icons.remove, size: 17),
                  ),
                  Text('$available',
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600)),
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
