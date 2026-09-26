import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

// ---------------------------------------------------------------------------
// Small parsing helpers - the backend is the source of truth, the UI only ever
// mirrors what PostgreSQL returned.
// ---------------------------------------------------------------------------

int _asInt(dynamic value, {int fallback = 0}) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

int? _asIntOrNull(dynamic value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

double? _asDoubleOrNull(dynamic value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

String? _asTrimmedString(dynamic value) {
  if (value == null) return null;
  final text = value.toString().trim();
  return text.isEmpty ? null : text;
}

DateTime? _asDate(dynamic value) {
  if (value == null) return null;
  return DateTime.tryParse(value.toString());
}

Map<String, dynamic> _asMap(dynamic value) {
  if (value is Map) {
    return Map<String, dynamic>.from(value);
  }
  return <String, dynamic>{};
}

List<Map<String, dynamic>> _asMapList(dynamic value) {
  if (value is List) {
    return value
        .whereType<Object>()
        .map((item) => _asMap(item))
        .toList(growable: false);
  }
  return const <Map<String, dynamic>>[];
}

// ---------------------------------------------------------------------------
// RESOURCE (catalog row from the Resource table)
// ---------------------------------------------------------------------------

class BackendResource {
  const BackendResource({
    required this.id,
    required this.name,
    required this.type,
    required this.totalQuantity,
    required this.availableQuantity,
    required this.isActive,
    required this.lowStockThreshold,
    this.unit,
    this.location,
    this.mode = 'CONSUMABLE',
    this.availableResponders,
  });

  final int id;
  final String name;
  final String type;
  final int totalQuantity;
  final int availableQuantity;
  final bool isActive;
  final int lowStockThreshold;
  final String? unit;
  final String? location;

  /// SERVICE (reusable responder capability, e.g. Ambulance) or CONSUMABLE
  /// (spent from inventory, e.g. Blood). Always comes from the backend -
  /// never inferred from `name`/`type` here.
  final String mode;

  /// Only meaningful for SERVICE resources: the live count of active,
  /// AVAILABLE responders with this exact resource enabled, as returned by
  /// GET /api/resources/availability. Null until that endpoint has been
  /// merged in (see [withAvailability]).
  final int? availableResponders;

  bool get isService => mode == 'SERVICE';

  /// Returns a copy with the live availability numbers from
  /// GET /api/resources/availability merged in. CONSUMABLE resources keep
  /// their catalog `availableQuantity` (already authoritative); SERVICE
  /// resources gain the live responder count.
  BackendResource withAvailability(ResourceAvailability? availability) {
    if (availability == null) return this;
    return BackendResource(
      id: id,
      name: name,
      type: type,
      totalQuantity: totalQuantity,
      availableQuantity: isService
          ? availableQuantity
          : (availability.availableQuantity ?? availableQuantity),
      isActive: isActive,
      lowStockThreshold: lowStockThreshold,
      unit: unit,
      location: location,
      mode: mode,
      availableResponders: availability.availableResponders,
    );
  }

  /// Unified "how many can I request right now" count: a responder count
  /// for SERVICE resources, real inventory for CONSUMABLE resources. Never
  /// hardcoded - both halves come straight from the backend.
  int get effectiveAvailableCount =>
      isService ? (availableResponders ?? 0) : availableQuantity;

  bool get isOutOfStock => effectiveAvailableCount <= 0;

  bool get isLowStock =>
      !isService && !isOutOfStock && availableQuantity <= lowStockThreshold;

  bool get isSelectable => isActive && !isOutOfStock;

  /// "10 / 10 vehicle", "4 responders available" or "Out of stock"
  String get availabilityLabel {
    if (!isActive) return 'Inactive';
    if (isOutOfStock) {
      return isService ? 'No responders available' : 'Out of stock';
    }

    if (isService) {
      final count = effectiveAvailableCount;
      return '$count responder${count == 1 ? '' : 's'} available';
    }

    final suffix = (unit == null || unit!.isEmpty) ? 'available' : unit!;
    return '$availableQuantity / $totalQuantity $suffix';
  }

  String get shortAvailability {
    if (!isActive) return 'inactive';
    if (isOutOfStock) {
      return isService ? 'no responders available' : 'out of stock';
    }

    if (isService) {
      final count = effectiveAvailableCount;
      return '$count responder${count == 1 ? '' : 's'} available';
    }

    final suffix = (unit == null || unit!.isEmpty) ? 'available' : '$unit available';
    return '$availableQuantity $suffix';
  }

  factory BackendResource.fromJson(Map<String, dynamic> json) {
    return BackendResource(
      id: _asInt(json['id']),
      name: json['name']?.toString() ?? 'Unknown resource',
      type: json['type']?.toString() ?? '',
      totalQuantity: _asInt(json['totalQuantity']),
      availableQuantity: _asInt(json['availableQuantity']),
      // Databases that have not run the migration yet still work: a missing
      // isActive flag is treated as active.
      isActive: json['isActive'] == null ? true : json['isActive'] == true,
      lowStockThreshold: _asInt(json['lowStockThreshold'], fallback: 1),
      unit: _asTrimmedString(json['unit']),
      location: _asTrimmedString(json['location']),
      // Older backends without the ResourceMode migration still work: a
      // missing mode is treated as CONSUMABLE, matching the database default.
      mode: _asTrimmedString(json['mode']) ?? 'CONSUMABLE',
    );
  }
}

/// One row from GET /api/resources/availability: the live "N responders
/// available" / "N units available" numbers shown to requesters. Both
/// numbers are computed by PostgreSQL/Prisma - this class only parses them.
class ResourceAvailability {
  const ResourceAvailability({
    required this.id,
    required this.name,
    required this.type,
    required this.mode,
    this.unit,
    this.availableResponders,
    this.availableQuantity,
  });

  final int id;
  final String name;
  final String type;
  final String mode;
  final String? unit;

  /// SERVICE only - count of active, AVAILABLE responders with this
  /// resource enabled. Null for CONSUMABLE resources.
  final int? availableResponders;

  /// CONSUMABLE only - current catalog inventory. Null for SERVICE
  /// resources.
  final int? availableQuantity;

  bool get isService => mode == 'SERVICE';

  /// "4 responders available" or "18 units available", straight from the
  /// backend - never a hardcoded count.
  String get label {
    if (isService) {
      final count = availableResponders ?? 0;
      return '$count responder${count == 1 ? '' : 's'} available';
    }

    final count = availableQuantity ?? 0;
    final suffix = (unit == null || unit!.isEmpty) ? 'units' : unit!;
    return '$count $suffix available';
  }

  factory ResourceAvailability.fromJson(Map<String, dynamic> json) {
    return ResourceAvailability(
      id: _asInt(json['id']),
      name: json['name']?.toString() ?? 'Unknown resource',
      type: json['type']?.toString() ?? '',
      mode: _asTrimmedString(json['mode']) ?? 'CONSUMABLE',
      unit: _asTrimmedString(json['unit']),
      availableResponders: _asIntOrNull(json['availableResponders']),
      availableQuantity: _asIntOrNull(json['availableQuantity']),
    );
  }
}

// ---------------------------------------------------------------------------
// PEOPLE
// ---------------------------------------------------------------------------

class UserSummary {
  const UserSummary({
    required this.id,
    required this.name,
    this.email,
    this.phone,
    this.responderStatus,
    this.location,
    this.latitude,
    this.longitude,
    this.lastActiveAt,
  });

  final int id;
  final String name;
  final String? email;
  final String? phone;
  final String? responderStatus;
  final String? location;
  final double? latitude;
  final double? longitude;
  final DateTime? lastActiveAt;

  static UserSummary? fromJson(dynamic value) {
    if (value is! Map) return null;

    final json = _asMap(value);
    final id = _asIntOrNull(json['id']);

    if (id == null) return null;

    return UserSummary(
      id: id,
      name: _asTrimmedString(json['name']) ??
          _asTrimmedString(json['email']) ??
          'User #$id',
      email: _asTrimmedString(json['email']),
      phone: _asTrimmedString(json['phone']),
      responderStatus: _asTrimmedString(json['responderStatus']),
      location: _asTrimmedString(json['location']),
      latitude: _asDoubleOrNull(json['latitude']),
      longitude: _asDoubleOrNull(json['longitude']),
      lastActiveAt: _asDate(json['lastActiveAt']),
    );
  }
}

class LiveResponderLocation {
  const LiveResponderLocation({
    required this.requestId,
    required this.responderId,
    required this.latitude,
    required this.longitude,
    required this.updatedAt,
    this.isLive = true,
  });

  final int requestId;
  final int responderId;
  final double latitude;
  final double longitude;
  final DateTime updatedAt;
  final bool isLive;

  factory LiveResponderLocation.fromJson(Map<String, dynamic> json) {
    return LiveResponderLocation(
      requestId: _asInt(json['requestId']),
      responderId: _asInt(json['responderId']),
      latitude: _asDoubleOrNull(json['latitude']) ?? 0,
      longitude: _asDoubleOrNull(json['longitude']) ?? 0,
      updatedAt: _asDate(json['timestamp']) ?? DateTime.now(),
      isLive: true,
    );
  }

  LiveResponderLocation asNotLive() => LiveResponderLocation(
        requestId: requestId,
        responderId: responderId,
        latitude: latitude,
        longitude: longitude,
        updatedAt: updatedAt,
        isLive: false,
      );

  LiveResponderLocation asLive() => LiveResponderLocation(
        requestId: requestId,
        responderId: responderId,
        latitude: latitude,
        longitude: longitude,
        updatedAt: updatedAt,
        isLive: true,
      );
}

class BackendResponder {
  const BackendResponder({
    required this.id,
    required this.name,
    required this.email,
    required this.status,
    this.phone,
    this.location,
    this.latitude,
    this.longitude,
    this.lastActiveAt,
  });

  final int id;
  final String name;
  final String email;
  final String status;
  final String? phone;
  final String? location;
  final double? latitude;
  final double? longitude;
  final DateTime? lastActiveAt;

  factory BackendResponder.fromJson(Map<String, dynamic> json) {
    return BackendResponder(
      id: _asInt(json['id']),
      name: json['name']?.toString() ?? 'Unknown responder',
      email: json['email']?.toString() ?? '',
      status: json['responderStatus']?.toString() ?? 'OFFLINE',
      phone: _asTrimmedString(json['phone']),
      location: _asTrimmedString(json['location']),
      latitude: _asDoubleOrNull(json['latitude']),
      longitude: _asDoubleOrNull(json['longitude']),
      lastActiveAt: _asDate(json['lastActiveAt']),
    );
  }

  BackendResponder withStatus(String nextStatus, {DateTime? updatedAt}) {
    return BackendResponder(
      id: id,
      name: name,
      email: email,
      status: nextStatus,
      phone: phone,
      location: location,
      latitude: latitude,
      longitude: longitude,
      lastActiveAt: updatedAt ?? lastActiveAt,
    );
  }
}

// ---------------------------------------------------------------------------
// RESPONDER INVENTORY (ResponderResource)
// ---------------------------------------------------------------------------

class BackendResponderResource {
  const BackendResponderResource({
    required this.id,
    required this.responderId,
    required this.resourceId,
    required this.totalQuantity,
    required this.availableQuantity,
    required this.status,
    required this.isEnabled,
    required this.responderName,
    required this.responderEmail,
    required this.responderStatus,
    required this.resourceName,
    required this.resourceType,
    this.unit,
    this.location,
  });

  final int id;
  final int responderId;
  final int resourceId;
  final int totalQuantity;
  final int availableQuantity;

  /// AVAILABLE | BUSY | UNAVAILABLE
  final String status;

  /// Durable willingness/qualification, independent from current status.
  final bool isEnabled;

  final String responderName;
  final String responderEmail;
  final String responderStatus;

  final String resourceName;
  final String resourceType;
  final String? unit;
  final String? location;

  bool get isAvailable =>
      isEnabled && status == 'AVAILABLE' && availableQuantity > 0;

  factory BackendResponderResource.fromJson(Map<String, dynamic> json) {
    final responder = _asMap(json['responder']);
    final resource = _asMap(json['resource']);

    return BackendResponderResource(
      id: _asInt(json['id']),
      responderId: _asInt(json['responderId']),
      resourceId: _asInt(json['resourceId']),
      totalQuantity: _asInt(json['totalQuantity']),
      availableQuantity: _asInt(json['availableQuantity']),
      status: json['status']?.toString() ?? 'UNAVAILABLE',
      isEnabled: json['isEnabled'] == true,
      responderName:
          _asTrimmedString(responder['name']) ?? 'Unknown responder',
      responderEmail: _asTrimmedString(responder['email']) ?? '',
      responderStatus:
          _asTrimmedString(responder['responderStatus']) ?? 'OFFLINE',
      resourceName: _asTrimmedString(resource['name']) ?? 'Resource',
      resourceType: _asTrimmedString(resource['type']) ?? '',
      unit: _asTrimmedString(resource['unit']),
      location: _asTrimmedString(resource['location']),
    );
  }
}

// ---------------------------------------------------------------------------
// REQUEST RESOURCES AND ALLOCATIONS
// ---------------------------------------------------------------------------

class RequiredResourceLine {
  const RequiredResourceLine({
    required this.resourceId,
    required this.quantity,
    required this.resourceName,
    required this.resourceType,
    this.unit,
  });

  final int resourceId;
  final int quantity;
  final String resourceName;
  final String resourceType;
  final String? unit;

  String get label => '$resourceName × $quantity';

  factory RequiredResourceLine.fromJson(Map<String, dynamic> json) {
    final resource = _asMap(json['resource']);
    final resourceId = _asInt(json['resourceId']);

    return RequiredResourceLine(
      resourceId: resourceId,
      quantity: _asInt(json['quantity'], fallback: 1),
      resourceName:
          _asTrimmedString(resource['name']) ?? 'Resource #$resourceId',
      resourceType: _asTrimmedString(resource['type']) ?? '',
      unit: _asTrimmedString(resource['unit']),
    );
  }
}

class AllocationLine {
  const AllocationLine({
    required this.id,
    required this.requestId,
    required this.resourceId,
    required this.responderId,
    required this.responderResourceId,
    required this.quantity,
    required this.status,
    required this.resourceName,
    this.responderName,
    this.allocatedAt,
    this.updatedAt,
  });

  final int id;
  final int requestId;
  final int resourceId;
  final int responderId;
  final int responderResourceId;
  final int quantity;

  /// RESERVED | DISPATCHED | DELIVERED | CANCELLED
  final String status;
  final String resourceName;
  final String? responderName;
  final DateTime? allocatedAt;
  final DateTime? updatedAt;

  bool get isActive => status != 'CANCELLED';
  bool get isReserved => status == 'RESERVED';
  bool get isDispatched => status == 'DISPATCHED';
  bool get isDelivered => status == 'DELIVERED';

  factory AllocationLine.fromJson(Map<String, dynamic> json) {
    final resource = _asMap(json['resource']);
    final responder = _asMap(json['responder']);
    final resourceId = _asInt(json['resourceId']);

    return AllocationLine(
      id: _asInt(json['id']),
      requestId: _asInt(json['requestId']),
      resourceId: resourceId,
      responderId: _asInt(json['responderId']),
      responderResourceId: _asInt(json['responderResourceId']),
      quantity: _asInt(json['quantity']),
      status: json['status']?.toString() ?? 'RESERVED',
      resourceName:
          _asTrimmedString(resource['name']) ?? 'Resource #$resourceId',
      responderName: _asTrimmedString(responder['name']),
      allocatedAt: _asDate(json['allocatedAt']),
      updatedAt: _asDate(json['updatedAt']),
    );
  }
}

// ---------------------------------------------------------------------------
// EMERGENCY REQUEST - mirrors the EmergencyRequest table
// ---------------------------------------------------------------------------

enum RequestStatus {
  pending,
  accepted,
  inProgress,
  partiallyAllocated,
  completed,
  cancelled,
}

RequestStatus requestStatusFromApi(String? value) {
  switch ((value ?? 'PENDING').toUpperCase()) {
    case 'ACCEPTED':
      return RequestStatus.accepted;
    case 'IN_PROGRESS':
      return RequestStatus.inProgress;
    case 'PARTIALLY_ALLOCATED':
      return RequestStatus.partiallyAllocated;
    case 'COMPLETED':
      return RequestStatus.completed;
    case 'CANCELLED':
      return RequestStatus.cancelled;
    case 'PENDING':
    default:
      return RequestStatus.pending;
  }
}

String statusLabel(RequestStatus status) => switch (status) {
      RequestStatus.pending => 'PENDING',
      RequestStatus.accepted => 'ACCEPTED',
      RequestStatus.inProgress => 'IN PROGRESS',
      RequestStatus.partiallyAllocated => 'PARTIAL',
      RequestStatus.completed => 'COMPLETED',
      RequestStatus.cancelled => 'CANCELLED',
    };

PillColors statusColors(RequestStatus status) => switch (status) {
      RequestStatus.pending =>
        const PillColors(AppColors.amberDim, AppColors.amber),
      RequestStatus.accepted =>
        const PillColors(AppColors.blueDim, AppColors.blue),
      RequestStatus.inProgress =>
        const PillColors(AppColors.blueDim, AppColors.blue),
      RequestStatus.partiallyAllocated =>
        const PillColors(AppColors.amberDim, AppColors.amber),
      RequestStatus.completed =>
        const PillColors(AppColors.tealDim, AppColors.teal),
      RequestStatus.cancelled =>
        const PillColors(AppColors.surface2, AppColors.textFaint),
    };

PillColors priorityColors(String priority) => switch (priority.toUpperCase()) {
      'CRITICAL' => const PillColors(AppColors.redDim, AppColors.red),
      'HIGH' => const PillColors(AppColors.amberDim, AppColors.amber),
      'MEDIUM' => const PillColors(AppColors.blueDim, AppColors.blue),
      _ => const PillColors(AppColors.surface2, AppColors.textDim),
    };

class EmergencyRequest {
  const EmergencyRequest({
    required this.id,
    required this.emergencyType,
    required this.description,
    required this.location,
    required this.priority,
    required this.status,
    required this.statusRaw,
    required this.createdAt,
    required this.requiredResources,
    required this.allocations,
    this.requester,
    this.acceptedBy,
    this.acceptedAt,
    this.updatedAt,
    this.latitude,
    this.longitude,
  });

  final int id;
  final String emergencyType;
  final String description;
  final String location;
  final String priority;
  final RequestStatus status;
  final String statusRaw;
  final DateTime createdAt;
  final DateTime? acceptedAt;
  final DateTime? updatedAt;
  final List<RequiredResourceLine> requiredResources;
  final List<AllocationLine> allocations;
  final UserSummary? requester;
  final UserSummary? acceptedBy;
  final double? latitude;
  final double? longitude;

  /// Human readable id used all over the dispatch board (DB-201).
  String get displayId => 'DB-$id';

  bool get isOpen =>
      status != RequestStatus.completed && status != RequestStatus.cancelled;

  bool get canBeCancelledByRequester =>
      status != RequestStatus.completed && status != RequestStatus.cancelled;

  List<AllocationLine> get activeAllocations =>
      allocations.where((a) => a.isActive).toList(growable: false);

  int allocatedFor(int resourceId) {
    var total = 0;
    for (final allocation in allocations) {
      if (allocation.isActive && allocation.resourceId == resourceId) {
        total += allocation.quantity;
      }
    }
    return total;
  }

  int remainingFor(int resourceId) {
    final line = firstWhereOrNull(
      requiredResources,
      (r) => r.resourceId == resourceId,
    );

    if (line == null) return 0;

    final remaining = line.quantity - allocatedFor(resourceId);
    return remaining < 0 ? 0 : remaining;
  }

  bool get isFullyAllocated {
    if (requiredResources.isEmpty) return false;
    return requiredResources.every((r) => remainingFor(r.resourceId) == 0);
  }

  String get resourcesSummary => requiredResources.isEmpty
      ? 'No resources requested'
      : requiredResources.map((r) => r.label).join(', ');

  /// Apply an authoritative allocation event to this request snapshot. The
  /// request status, when present, is also the value supplied by the backend;
  /// Flutter never derives or advances the lifecycle itself.
  EmergencyRequest withAllocation(
    AllocationLine allocation, {
    String? backendRequestStatus,
  }) {
    final nextAllocations = <AllocationLine>[
      for (final existing in allocations)
        if (existing.id != allocation.id) existing,
      allocation,
    ];
    final nextStatusRaw = backendRequestStatus ?? statusRaw;

    return EmergencyRequest(
      id: id,
      emergencyType: emergencyType,
      description: description,
      location: location,
      priority: priority,
      status: requestStatusFromApi(nextStatusRaw),
      statusRaw: nextStatusRaw,
      createdAt: createdAt,
      requiredResources: requiredResources,
      allocations: nextAllocations,
      requester: requester,
      acceptedBy: acceptedBy,
      acceptedAt: acceptedAt,
      updatedAt: allocation.updatedAt ?? updatedAt,
      latitude: latitude,
      longitude: longitude,
    );
  }

  factory EmergencyRequest.fromJson(Map<String, dynamic> json) {
    final statusRaw = (json['status'] ?? 'PENDING').toString();

    return EmergencyRequest(
      id: _asInt(json['id']),
      emergencyType: _asTrimmedString(json['emergencyType']) ?? 'Emergency',
      description: _asTrimmedString(json['description']) ?? '',
      location: _asTrimmedString(json['location']) ?? 'Unknown',
      priority: (json['priority'] ?? 'MEDIUM').toString(),
      status: requestStatusFromApi(statusRaw),
      statusRaw: statusRaw,
      createdAt: _asDate(json['createdAt']) ?? DateTime.now(),
      acceptedAt: _asDate(json['acceptedAt']),
      updatedAt: _asDate(json['updatedAt']),
      requiredResources: _asMapList(json['requiredResources'])
          .map(RequiredResourceLine.fromJson)
          .toList(growable: false),
      allocations: _asMapList(json['allocations'])
          .map(AllocationLine.fromJson)
          .toList(growable: false),
      requester: UserSummary.fromJson(json['requester']),
      acceptedBy: UserSummary.fromJson(json['acceptedBy']),
      latitude: _asDoubleOrNull(json['latitude']),
      longitude: _asDoubleOrNull(json['longitude']),
    );
  }
}

// ---------------------------------------------------------------------------
// PRESENTATION HELPERS
//
// Icons/colours are only decoration. They are derived from the resource type
// string coming from PostgreSQL, with a neutral default, so a brand new
// resource type (for example "Rescue Boat") renders correctly without any
// Flutter code change.
// ---------------------------------------------------------------------------

class ResourceMeta {
  const ResourceMeta(this.icon, this.bg, this.color);
  final IconData icon;
  final Color bg;
  final Color color;
}

ResourceMeta resourceMetaFor(String typeOrName) {
  final value = typeOrName.toUpperCase();

  if (value.contains('AMBULANCE') || value.contains('MEDICAL')) {
    return const ResourceMeta(
        Icons.local_hospital, AppColors.redDim, AppColors.red);
  }
  if (value.contains('BLOOD')) {
    return const ResourceMeta(
        Icons.water_drop, Color(0xFFFCE4F3), Color(0xFFC23E96));
  }
  if (value.contains('OXYGEN')) {
    return const ResourceMeta(Icons.air, AppColors.blueDim, AppColors.blue);
  }
  if (value.contains('FIRE')) {
    return const ResourceMeta(
        Icons.local_fire_department, AppColors.amberDim, AppColors.amber);
  }
  if (value.contains('VOLUNTEER') || value.contains('PEOPLE')) {
    return const ResourceMeta(Icons.groups, AppColors.tealDim, AppColors.teal);
  }
  if (value.contains('BOAT') || value.contains('RESCUE')) {
    return const ResourceMeta(
        Icons.directions_boat, AppColors.blueDim, AppColors.blue);
  }
  if (value.contains('FOOD') || value.contains('WATER')) {
    return const ResourceMeta(
        Icons.local_drink, AppColors.tealDim, AppColors.teal);
  }

  return const ResourceMeta(
      Icons.inventory_2, AppColors.surface2, AppColors.textDim);
}

Color responderStatusColor(String status) {
  switch (status.toUpperCase()) {
    case 'AVAILABLE':
      return AppColors.teal;
    case 'BUSY':
      return AppColors.blue;
    default:
      return AppColors.textFaint;
  }
}

// ---------------------------------------------------------------------------
// DISTRICTS - display-only coordinates for the sector map. They are labels for
// the `location` column, never a source of resources.
// ---------------------------------------------------------------------------

class District {
  const District(this.name, this.point);
  final String name;
  final Offset point;
}

/// Views available in the console. Which ones are shown depends on the role
/// of the logged in user (see navItemsForRole).
enum ConsoleView { board, newRequest, resources, responders, log }

class NavItem {
  const NavItem(this.view, this.icon, this.label);
  final ConsoleView view;
  final IconData icon;
  final String label;
}

List<NavItem> navItemsForRole(String? role) {
  return <NavItem>[
    const NavItem(ConsoleView.board, Icons.dashboard_outlined, 'Board'),
    if (role == 'REQUESTER')
      const NavItem(ConsoleView.newRequest, Icons.add_circle_outline, 'New'),
    const NavItem(ConsoleView.resources, Icons.inventory_2_outlined, 'Resources'),
    const NavItem(ConsoleView.responders, Icons.groups_2_outlined, 'Responders'),
    const NavItem(ConsoleView.log, Icons.receipt_long_outlined, 'Log'),
  ];
}

const List<District> kDistricts = <District>[
  District('North Ridge', Offset(150, 55)),
  District('Harbor District', Offset(470, 70)),
  District('Old Town', Offset(300, 130)),
  District('Riverside', Offset(100, 190)),
  District('Eastgate', Offset(520, 195)),
  District('Summit Heights', Offset(300, 40)),
];

const List<String> kEmergencyTypes = <String>[
  'Fire',
  'Medical',
  'Accident',
  'Flood',
  'Rescue',
  'Other',
];

const List<String> kPriorities = <String>[
  'LOW',
  'MEDIUM',
  'HIGH',
  'CRITICAL',
];
