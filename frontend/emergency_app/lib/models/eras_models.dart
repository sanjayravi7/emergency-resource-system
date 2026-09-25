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
    required this.mode,
    required this.totalQuantity,
    required this.availableQuantity,
    required this.isActive,
    required this.lowStockThreshold,
    this.unit,
    this.location,
    this.availableResponders,
  });

  final int id;
  final String name;
  final String type;
  final String mode;
  final int totalQuantity;
  final int availableQuantity;
  final bool isActive;
  final int lowStockThreshold;
  final String? unit;
  final String? location;
  final int? availableResponders;

  bool get isService => mode == 'SERVICE';

  bool get isOutOfStock => !isService && availableQuantity <= 0;

  bool get isLowStock =>
      !isService && !isOutOfStock && availableQuantity <= lowStockThreshold;

  bool get isSelectable => isActive && (isService || !isOutOfStock);

  /// Availability for request selection comes from the availability endpoint.
  String get availabilityLabel {
    if (!isActive) return 'Inactive';
    if (isService) {
      return '${availableResponders ?? 0} responders available';
    }
    if (isOutOfStock) return 'Out of stock';

    final suffix = _consumableUnit;
    return '$availableQuantity $suffix available';
  }

  String get shortAvailability {
    if (!isActive) return 'inactive';
    if (isService) return '${availableResponders ?? 0} responders available';
    if (isOutOfStock) return 'out of stock';

    return '$availableQuantity $_consumableUnit available';
  }

  String get _consumableUnit {
    if (unit == null || unit!.isEmpty || unit == 'unit') return 'units';
    return unit!;
  }

  factory BackendResource.fromJson(Map<String, dynamic> json) {
    return BackendResource(
      id: _asInt(json['id']),
      name: json['name']?.toString() ?? 'Unknown resource',
      type: json['type']?.toString() ?? '',
      mode: json['mode']?.toString() ?? 'CONSUMABLE',
      totalQuantity: _asInt(json['totalQuantity']),
      availableQuantity: _asInt(json['availableQuantity']),
      // Databases that have not run the migration yet still work: a missing
      // isActive flag is treated as active.
      isActive: json['isActive'] == null ? true : json['isActive'] == true,
      lowStockThreshold: _asInt(json['lowStockThreshold'], fallback: 1),
      unit: _asTrimmedString(json['unit']),
      location: _asTrimmedString(json['location']),
      availableResponders: _asIntOrNull(json['availableResponders']),
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
  });

  final int id;
  final String name;
  final String? email;
  final String? phone;
  final String? responderStatus;
  final String? location;

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
    );
  }
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
    required this.resourceMode,
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
  final String resourceMode;
  final String? unit;
  final String? location;

  bool get isAvailable => resourceMode == 'SERVICE'
      ? isEnabled
      : isEnabled && status == 'AVAILABLE' && availableQuantity > 0;

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
      resourceMode: _asTrimmedString(resource['mode']) ?? 'CONSUMABLE',
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
    required this.resourceMode,
    this.unit,
  });

  final int resourceId;
  final int quantity;
  final String resourceName;
  final String resourceType;
  final String resourceMode;
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
      resourceMode: _asTrimmedString(resource['mode']) ?? 'CONSUMABLE',
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
