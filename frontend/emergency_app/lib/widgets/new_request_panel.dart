import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../models/eras_models.dart';
import '../services/location_service.dart';
import '../theme/app_theme.dart';
import 'auth_motion.dart';
import 'common_widgets.dart';
import 'requester_location_picker.dart';

/// Payload handed to the console when the requester submits the form.
class NewRequestPayload {
  const NewRequestPayload({
    required this.emergencyType,
    required this.description,
    required this.location,
    required this.priority,
    required this.requiredResources,
    this.latitude,
    this.longitude,
    this.allowGpsFallback = true,
  });

  final String emergencyType;
  final String? description;
  final String location;
  final String priority;
  final double? latitude;
  final double? longitude;
  final bool allowGpsFallback;

  bool get hasPreciseLocation => latitude != null && longitude != null;

  /// [{ resourceId, quantity }] - real database ids only.
  final List<Map<String, int>> requiredResources;
}

class _DraftLine {
  _DraftLine({this.resourceId, this.quantity = 1});

  int? resourceId;
  int quantity;
}

/// Upper bound for one SERVICE resource line. Responder availability never
/// limits the requested quantity (an emergency is always accepted, even with
/// zero responders online); this only keeps the +/- stepper from producing
/// absurd numbers. The backend independently caps quantities.
const int _maxServiceRequestQuantity = 20;

/// Shared REQUESTER / ADMIN emergency form. Every selectable resource comes
/// from GET /api/resources, so a resource added by an admin (for example
/// "Rescue Boat") shows up without touching this file.
class NewRequestPanel extends StatefulWidget {
  const NewRequestPanel({
    super.key,
    required this.resources,
    required this.onSubmit,
    required this.onReload,
    required this.onUseCurrentLocation,
    this.locationService,
    this.submitting = false,
    this.showMapPreview,
    this.initialRequest,
    this.panelTitle,
    this.submitLabel,
  });

  final List<BackendResource> resources;
  final Future<bool> Function(NewRequestPayload payload) onSubmit;
  final VoidCallback onReload;

  /// Reads browser/device GPS. Returns null when denied or unavailable.
  final Future<GeoPoint?> Function() onUseCurrentLocation;

  /// Google-backed reverse geocoding / place autocomplete. Injectable so tests
  /// can provide a fake; defaults to the platform implementation.
  final LocationService? locationService;

  final bool submitting;
  final bool? showMapPreview;

  /// When present, the same request form becomes the requester PATCH editor.
  /// Every mutable value is initialized from the authoritative request
  /// snapshot; completed/cancelled authorization remains a backend concern.
  final EmergencyRequest? initialRequest;
  final String? panelTitle;
  final String? submitLabel;

  @override
  State<NewRequestPanel> createState() => _NewRequestPanelState();
}

class _NewRequestPanelState extends State<NewRequestPanel> {
  final descriptionController = TextEditingController();
  final customTypeController = TextEditingController();
  final locationController = TextEditingController();

  String emergencyType = kEmergencyTypes.first;
  String priority = 'HIGH';
  double? latitude;
  double? longitude;
  bool allowGpsFallback = true;
  String? errorMessage;

  late final LocationService locationService =
      widget.locationService ?? createLocationService();

  final List<_DraftLine> lines = <_DraftLine>[];

  @override
  void initState() {
    super.initState();
    final initial = widget.initialRequest;
    if (initial == null) {
      lines.add(_DraftLine());
      return;
    }

    String? knownType;
    for (final type in kEmergencyTypes) {
      if (type.toLowerCase() == initial.emergencyType.toLowerCase()) {
        knownType = type;
        break;
      }
    }
    if (knownType == null) {
      emergencyType = 'Other';
      customTypeController.text = initial.emergencyType;
    } else {
      emergencyType = knownType;
    }
    descriptionController.text = initial.description ?? '';
    locationController.text = initial.location;
    priority = kPriorities.contains(initial.priority.toUpperCase())
        ? initial.priority.toUpperCase()
        : 'HIGH';
    latitude = initial.latitude;
    longitude = initial.longitude;
    allowGpsFallback = !initial.hasPreciseLocation;
    lines.addAll(
      initial.requiredResources.map(
        (line) => _DraftLine(
          resourceId: line.resourceId,
          quantity: line.quantity,
        ),
      ),
    );
    if (lines.isEmpty) lines.add(_DraftLine());
  }

  @override
  void dispose() {
    descriptionController.dispose();
    customTypeController.dispose();
    locationController.dispose();
    super.dispose();
  }

  List<BackendResource> get selectableResources =>
      widget.resources.where((r) => r.isActive).toList();

  /// True when at least one selected SERVICE capability currently has no
  /// online responder. Drives the "your request will queue as PENDING" note -
  /// purely informational, never a blocker.
  bool get _needsResponderQueueNotice {
    for (final line in lines) {
      if (line.resourceId == null) continue;
      final resource = resourceById(line.resourceId);
      if (resource != null && resource.hasNoRespondersOnline) return true;
    }
    return false;
  }

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

      // A SERVICE resource is a reusable responder capability: the quantity
      // says how many units of that capability the emergency needs and is
      // never limited by the number of responders online right now. A
      // CONSUMABLE resource is bounded by real spendable inventory.
      final int maxQuantity;
      if (resource == null) {
        maxQuantity = 1;
      } else if (resource.isService) {
        maxQuantity = _maxServiceRequestQuantity;
      } else {
        maxQuantity = resource.effectiveAvailableCount;
      }

      var next = line.quantity + delta;
      if (next < 1) next = 1;
      if (next > maxQuantity) next = maxQuantity;

      line.quantity = next;
      errorMessage = null;
    });
  }

  void onLocationChanged(double? newLatitude, double? newLongitude) {
    setState(() {
      latitude = newLatitude;
      longitude = newLongitude;
      // A precise location is claimed as soon as coordinates exist.
      allowGpsFallback = newLatitude == null || newLongitude == null;
      errorMessage = null;
    });
  }

  bool get hasPreciseLocation => latitude != null && longitude != null;

  String? validate() {
    final resolvedType = emergencyType == 'Other'
        ? customTypeController.text.trim()
        : emergencyType.trim();

    if (resolvedType.isEmpty) {
      return 'Enter the emergency type';
    }

    if (locationController.text.trim().isEmpty) {
      return 'Select or enter a place. Use "Use my current location" or search '
          'for a nearby place.';
    }

    // Exactly one coordinate can never be stored: it is not a real point.
    if ((latitude == null) != (longitude == null)) {
      return 'Precise location is incomplete. Re-detect your location or pick '
          'a place from search.';
    }

    if (!kPriorities.contains(priority)) {
      return 'Select a priority';
    }

    final chosen = lines.where((l) => l.resourceId != null).toList();

    // Resource information is OPTIONAL. An emergency must always be fileable -
    // an empty catalog, zero selected resources or nothing allocatable can
    // never block submission. Any lines the requester DID choose are still
    // validated below; a completely empty selection is valid and simply files
    // the emergency with zero RequestResource rows.

    final ids = <int>{};

    for (final line in chosen) {
      final resource = resourceById(line.resourceId);

      if (resource == null) {
        return 'One of the selected resources is no longer available';
      }

      if (!resource.isActive) {
        return '${resource.name} is not active anymore';
      }

      // Zero responders online NEVER blocks a SERVICE resource: the request
      // is filed and stays PENDING until a compatible responder is
      // available. Only a CONSUMABLE resource can be rejected for missing
      // inventory, which the backend also enforces.
      if (resource.isOutOfStock) {
        return '${resource.name} is out of stock';
      }

      if (line.quantity <= 0) {
        return 'Quantity must be greater than 0';
      }

      if (!resource.isService &&
          line.quantity > resource.effectiveAvailableCount) {
        return 'Only ${resource.effectiveAvailableCount} '
            '${resource.name} available';
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

    final rawDescription = descriptionController.text;
    final normalizedDescription =
        rawDescription.trim().isEmpty ? null : rawDescription;

    final payload = NewRequestPayload(
      emergencyType: resolvedType,
      description: normalizedDescription,
      location: locationController.text.trim(),
      priority: priority,
      latitude: latitude,
      longitude: longitude,
      allowGpsFallback: allowGpsFallback,
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
      locationController.clear();
      latitude = null;
      longitude = null;
      allowGpsFallback = true;
      lines
        ..clear()
        ..add(_DraftLine());
      errorMessage = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = ErasPalette.of(context);

    return Panel(
      title: widget.panelTitle ??
          (widget.initialRequest == null ? 'NEW EMERGENCY' : 'EDIT REQUEST'),
      hint: widget.initialRequest == null
          ? 'Resources load live from PostgreSQL'
          : 'Only PENDING requests can be changed',
      trailing: RefreshSpinButton(
        tooltip: 'Reload resources',
        onPressed: widget.onReload,
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final narrow = constraints.maxWidth < 620;

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _emergencyFields(narrow, p),
                const SizedBox(height: 18),
                Divider(height: 1, color: p.border),
                const SizedBox(height: 14),
                const FieldLabel('Required resources'),
                const SizedBox(height: 10),
                if (selectableResources.isEmpty)
                  // Purely informational, never a blocker: resource
                  // information is optional. An empty catalog does not stop a
                  // requester from filing an emergency - the request is
                  // submitted immediately and stays PENDING until a compatible
                  // responder is available.
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'No resources in the catalog yet. Resources are optional '
                      '- you can submit this emergency now and responders will '
                      'be matched as they come online.',
                      style: TextStyle(fontSize: 12.5, color: p.textDim),
                    ),
                  )
                else
                  ...List.generate(
                    lines.length,
                    (index) => _resourceRow(index, narrow, p),
                  ),
                if (_needsResponderQueueNotice) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Some selected services have no responders online right '
                    'now. Your request is still submitted immediately and '
                    'stays PENDING until a compatible responder is available.',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: p.amber,
                      height: 1.5,
                    ),
                  ),
                ],
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: canAddLine ? addLine : null,
                    icon: const Icon(Icons.add, size: 16),
                    style: TextButton.styleFrom(
                      foregroundColor: p.teal,
                    ),
                    label: const Text('Add another resource',
                        style: TextStyle(fontSize: 12.5)),
                  ),
                ),
                const SizedBox(height: 8),
                _summary(p),
                if (errorMessage != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: p.redDim,
                      borderRadius: BorderRadius.circular(5),
                      border: Border.all(color: p.red.withValues(alpha: .38)),
                    ),
                    child: Text(
                      errorMessage!,
                      style: TextStyle(fontSize: 12.5, color: p.red),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: HoverLift(
                    enabled: !widget.submitting,
                    lift: 1.2,
                    child: PressableScale(
                      enabled: !widget.submitting,
                      child: FilledButton(
                        onPressed: widget.submitting ? null : submit,
                        style: FilledButton.styleFrom(
                          backgroundColor: p.teal,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(6),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 15),
                        ),
                        child: Text(
                          widget.submitting
                              ? 'Saving…'
                              : (widget.submitLabel ??
                                  (widget.initialRequest == null
                                      ? 'Submit request'
                                      : 'Save changes')),
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _emergencyFields(bool narrow, ErasPalette p) {
    final typeField = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const FieldLabel('Emergency type'),
        const SizedBox(height: 6),
        DropdownButtonFormField<String>(
          key: ValueKey('emergency-type-$emergencyType'),
          initialValue: emergencyType,
          isExpanded: true,
          dropdownColor: p.surface2,
          iconEnabledColor: p.textDim,
          style: TextStyle(fontSize: 13, color: p.text),
          decoration: fieldDecoration(context: context),
          items: kEmergencyTypes
              .map(
                (type) => DropdownMenuItem<String>(
                  value: type,
                  child: Text(
                    type,
                    style: TextStyle(fontSize: 13, color: p.text),
                  ),
                ),
              )
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
          FocusGlow(
            borderRadius: 8,
            child: TextField(
              key: const Key('custom-emergency-type-field'),
              controller: customTypeController,
              decoration: fieldDecoration(
                hintText: 'Describe the type',
                context: context,
              ),
              style: TextStyle(fontSize: 13, color: p.text),
            ),
          ),
        ],
      ],
    );

    final locationField = _locationField();

    final priorityField = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const FieldLabel('Priority'),
        const SizedBox(height: 6),
        DropdownButtonFormField<String>(
          key: ValueKey('priority-$priority'),
          initialValue: priority,
          isExpanded: true,
          dropdownColor: p.surface2,
          iconEnabledColor: p.textDim,
          style: TextStyle(fontSize: 13, color: p.text),
          decoration: fieldDecoration(context: context),
          items: kPriorities
              .map(
                (value) => DropdownMenuItem<String>(
                  value: value,
                  child: Text(
                    titleCase(value),
                    style: TextStyle(fontSize: 13, color: p.text),
                  ),
                ),
              )
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
        const FieldLabel('Description (optional)'),
        const SizedBox(height: 6),
        FocusGlow(
          borderRadius: 8,
          child: TextField(
            key: const Key('request-description-field'),
            controller: descriptionController,
            minLines: 2,
            maxLines: 3,
            style: TextStyle(fontSize: 13, color: p.text),
            decoration: fieldDecoration(
              hintText: 'What happened, how many people are affected…',
              context: context,
            ),
            onChanged: (_) {
              if (errorMessage != null) {
                setState(() => errorMessage = null);
              }
            },
          ),
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
            Expanded(child: priorityField),
          ],
        ),
        const SizedBox(height: 12),
        locationField,
        const SizedBox(height: 12),
        descriptionField,
      ],
    );
  }

  Widget _locationField() {
    return RequesterLocationPicker(
      placeController: locationController,
      latitude: latitude,
      longitude: longitude,
      locationService: locationService,
      onUseCurrentLocation: widget.onUseCurrentLocation,
      onLocationChanged: onLocationChanged,
      onPlaceTextChanged: () {
        if (errorMessage != null) {
          setState(() => errorMessage = null);
        } else {
          setState(() {});
        }
      },
      enabled: !widget.submitting,
      showMapPreview: widget.showMapPreview ?? kIsWeb,
    );
  }

  Widget _resourceRow(int index, bool narrow, ErasPalette p) {
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
                      color: r.isSelectable ? p.text : p.textFaint,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  r.shortAvailability,
                  style: TextStyle(
                    fontSize: 11,
                    color: _shortAvailabilityColor(p, r),
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
            style: TextStyle(fontSize: 13, color: p.textFaint),
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
          key:
              ValueKey('resource-${identityHashCode(line)}-${line.resourceId}'),
          initialValue: line.resourceId,
          isExpanded: true,
          dropdownColor: p.surface2,
          iconEnabledColor: p.textDim,
          style: TextStyle(fontSize: 13, color: p.text),
          decoration: fieldDecoration(context: context),
          hint: Text(
            'Select a resource',
            style: TextStyle(fontSize: 13, color: p.textFaint),
          ),
          items: items,
          onChanged: (value) {
            if (value == null) return;
            setState(() {
              line.resourceId = value;
              final picked = resourceById(value);
              // Only CONSUMABLE inventory bounds the quantity. A SERVICE
              // capability is never clamped to the current responder count -
              // the emergency must be filable even with zero responders.
              if (picked != null &&
                  !picked.isService &&
                  line.quantity > picked.effectiveAvailableCount) {
                line.quantity = picked.effectiveAvailableCount;
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
            color: p.surface2,
            border: Border.all(color: p.border),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            resource == null ? '-' : resource.availabilityLabel,
            style: monoStyle(
              size: 12.5,
              color: _lineAvailabilityColor(p, resource),
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
            color: p.surface2,
            border: Border.all(color: p.border),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                onPressed:
                    resource == null ? null : () => changeQuantity(index, -1),
                icon: Icon(Icons.remove, size: 16, color: p.textDim),
                splashRadius: 18,
              ),
              Text(
                '${line.quantity}',
                style: monoStyle(
                  size: 14,
                  color: p.text,
                  weight: FontWeight.w600,
                ),
              ),
              IconButton(
                onPressed:
                    resource == null ? null : () => changeQuantity(index, 1),
                icon: Icon(Icons.add, size: 16, color: p.textDim),
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
      icon: Icon(Icons.close, size: 18, color: p.textFaint),
    );

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 12),
      decoration: BoxDecoration(
        color: p.dark ? p.surface2.withValues(alpha: .36) : Colors.transparent,
        border: Border.all(color: p.border),
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

  Widget _summary(ErasPalette p) {
    final chosen = lines.where((l) => l.resourceId != null).toList();

    if (chosen.isEmpty) {
      return Text(
        'No resources selected yet.',
        style: TextStyle(fontSize: 12, color: p.textFaint),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: p.surface2,
        border: Border.all(color: p.border),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'REQUIRED',
            style: TextStyle(
              fontSize: 10,
              color: p.textFaint,
              letterSpacing: .6,
            ),
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

  Color _shortAvailabilityColor(ErasPalette p, ResourceItem r) {
    if (r.isOutOfStock) return p.red;
    if (r.hasNoRespondersOnline) return p.amber;
    return p.textFaint;
  }

  Color _lineAvailabilityColor(ErasPalette p, ResourceItem? r) {
    if (r == null) return p.textFaint;
    if (r.isOutOfStock) return p.red;
    if (r.isLowStock) return p.amber;
    return p.textDim;
  }
}
