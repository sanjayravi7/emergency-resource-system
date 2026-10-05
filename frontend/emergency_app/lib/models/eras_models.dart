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

String? _asOptionalStoredText(dynamic value) {
  if (value == null) return null;
  final text = value.toString();
  return text.trim().isEmpty ? null : text;
}

DateTime? _asDate(dynamic value) {
  if (value == null) return null;
  return DateTime.tryParse(value.toString());
}

bool isValidCoordinatePair(double? latitude, double? longitude) =>
    latitude != null &&
    longitude != null &&
    latitude.isFinite &&
    longitude.isFinite &&
    latitude >= -90 &&
    latitude <= 90 &&
    longitude >= -180 &&
    longitude <= 180;

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

  /// A SERVICE capability with no available responder right now. This is an
  /// informational state, never a submission blocker: the emergency request
  /// is still created and stays PENDING until a compatible responder comes
  /// online (the backend guarantees this).
  bool get hasNoRespondersOnline => isService && effectiveAvailableCount <= 0;

  /// Out of spendable inventory. Only CONSUMABLE resources can be out of
  /// stock - a SERVICE resource is a reusable responder capability, so
  /// "zero responders online" is reported through [hasNoRespondersOnline]
  /// instead and never blocks an emergency.
  bool get isOutOfStock => !isService && availableQuantity <= 0;

  bool get isLowStock =>
      !isService && !isOutOfStock && availableQuantity <= lowStockThreshold;

  /// Whether the requester can pick this resource for a new emergency.
  ///
  /// A SERVICE resource stays selectable while active no matter how many
  /// responders are online right now - responder availability must never
  /// block filing an emergency. A CONSUMABLE resource requires real spendable
  /// inventory, which the backend also enforces on creation.
  bool get isSelectable => isActive && (isService || !isOutOfStock);

  /// "10 / 10 vehicle", "4 responders available", "No responders online yet"
  /// or "Out of stock"
  String get availabilityLabel {
    if (!isActive) return 'Inactive';
    if (isOutOfStock) return 'Out of stock';

    if (isService) {
      if (hasNoRespondersOnline) return 'No responders online yet';
      final count = effectiveAvailableCount;
      return '$count responder${count == 1 ? '' : 's'} available';
    }

    final suffix = (unit == null || unit!.isEmpty) ? 'available' : unit!;
    return '$availableQuantity / $totalQuantity $suffix';
  }

  String get shortAvailability {
    if (!isActive) return 'inactive';
    if (isOutOfStock) return 'out of stock';

    if (isService) {
      if (hasNoRespondersOnline) return 'no responders online yet';
      final count = effectiveAvailableCount;
      return '$count responder${count == 1 ? '' : 's'} available';
    }

    final suffix =
        (unit == null || unit!.isEmpty) ? 'available' : '$unit available';
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

/// Operational relationship counts returned by the ADMIN user directory.
///
/// These JSON keys intentionally match the backend's `history` payload:
/// `requests`, `acceptedRequests`, `responderAssignments`, `allocations`,
/// `responderResources`, and `responderHelpTypes`. The display layer gives the
/// latter two user-facing labels (Inventory and Help types) without changing
/// the API contract.
class AdminUserHistory {
  const AdminUserHistory({
    this.requests = 0,
    this.acceptedRequests = 0,
    this.responderAssignments = 0,
    this.allocations = 0,
    this.responderResources = 0,
    this.responderHelpTypes = 0,
    this.total = 0,
    this.deletable = false,
  });

  /// Emergencies requested by the account (`history.requests`).
  final int requests;

  /// Emergencies accepted as lead responder (`history.acceptedRequests`).
  final int acceptedRequests;

  final int responderAssignments;
  final int allocations;

  /// Durable inventory rows held by the responder (`history.responderResources`).
  final int responderResources;

  /// Responder help-type rows (`history.responderHelpTypes`).
  final int responderHelpTypes;

  final int total;

  /// This value is supplied by the backend. It is never inferred from the
  /// client-side counters and is only a UI hint; DELETE is always revalidated
  /// by the backend.
  final bool deletable;

  factory AdminUserHistory.fromJson(Map<String, dynamic> json) {
    return AdminUserHistory(
      requests: _asInt(json['requests']),
      acceptedRequests: _asInt(json['acceptedRequests']),
      responderAssignments: _asInt(json['responderAssignments']),
      allocations: _asInt(json['allocations']),
      responderResources: _asInt(json['responderResources']),
      responderHelpTypes: _asInt(json['responderHelpTypes']),
      total: _asInt(json['total']),
      deletable: json['deletable'] == true,
    );
  }
}

/// Safe projection of one row from the ADMIN-only GET /api/users directory.
///
/// The backend includes other account properties for its own purposes. This
/// model deliberately keeps only the fields needed by the management screen;
/// credentials, Firebase identifiers and device tokens are never retained or
/// exposed to widgets.
class AdminUser {
  const AdminUser({
    required this.id,
    required this.name,
    required this.role,
    required this.isActive,
    this.email,
    this.phone,
    this.responderStatus,
    this.history = const AdminUserHistory(),
  });

  final int id;
  final String name;
  final String? email;
  final String? phone;
  final String role;
  final bool isActive;
  final String? responderStatus;
  final AdminUserHistory history;

  factory AdminUser.fromJson(Map<String, dynamic> json) {
    final id = _asInt(json['id']);
    final historyJson = _asMap(json['history']);
    return AdminUser(
      id: id,
      name: _asTrimmedString(json['name']) ?? 'User #$id',
      email: _asTrimmedString(json['email']),
      phone: _asTrimmedString(json['phone']),
      role: _asTrimmedString(json['role']) ?? 'UNKNOWN',
      isActive: json['isActive'] == true,
      responderStatus: _asTrimmedString(json['responderStatus']),
      history: AdminUserHistory.fromJson(historyJson),
    );
  }
}

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

  /// Strict parser for realtime telemetry. Missing or out-of-range coordinates
  /// are ignored instead of becoming a fabricated marker at 0,0.
  static LiveResponderLocation? tryFromJson(Map<String, dynamic> json) {
    final requestId = _asIntOrNull(json['requestId']);
    final responderId = _asIntOrNull(json['responderId']);
    final latitude = _asDoubleOrNull(json['latitude']);
    final longitude = _asDoubleOrNull(json['longitude']);
    if (requestId == null ||
        requestId <= 0 ||
        responderId == null ||
        responderId <= 0 ||
        !isValidCoordinatePair(latitude, longitude)) {
      return null;
    }
    return LiveResponderLocation(
      requestId: requestId,
      responderId: responderId,
      latitude: latitude!,
      longitude: longitude!,
      updatedAt: _asDate(json['timestamp']) ?? DateTime.now(),
      isLive: true,
    );
  }

  /// Non-null compatibility factory for trusted/test payloads. Invalid
  /// telemetry is rejected rather than converted to a fabricated 0,0 point;
  /// production socket ingestion should prefer [tryFromJson] so malformed
  /// events can be ignored without throwing.
  factory LiveResponderLocation.fromJson(Map<String, dynamic> json) {
    final parsed = tryFromJson(json);
    if (parsed == null) {
      throw const FormatException('Invalid responder location payload.');
    }
    return parsed;
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
    this.isActive = true,
    this.phone,
    this.location,
    this.latitude,
    this.longitude,
    this.lastActiveAt,
    this.helpTypes = const <ResponderHelpType>[],
    this.resources = const <BackendResponderResource>[],
    this.compatibleRequestIds = const <int>{},
  });

  final int id;
  final String name;
  final String email;
  final String status;
  final bool isActive;
  final String? phone;
  final String? location;
  final double? latitude;
  final double? longitude;
  final DateTime? lastActiveAt;

  /// Enabled emergency categories and resource/inventory facts returned by the
  /// existing ADMIN responder endpoint. They are display metadata only;
  /// [compatibleRequestIds] is the backend-computed assignment allow-list.
  final List<ResponderHelpType> helpTypes;
  final List<BackendResponderResource> resources;
  final Set<int> compatibleRequestIds;

  bool isCompatibleWith(int requestId) =>
      isActive &&
      status == 'AVAILABLE' &&
      compatibleRequestIds.contains(requestId);

  factory BackendResponder.fromJson(Map<String, dynamic> json) {
    final helpTypeRows =
        json['helpTypes'] ?? json['responderHelpTypes'] ?? const <dynamic>[];
    final resourceRows =
        json['resources'] ?? json['responderResources'] ?? const <dynamic>[];
    final compatibleRows =
        json['compatibleRequestIds'] as List<dynamic>? ?? const <dynamic>[];

    return BackendResponder(
      id: _asInt(json['id']),
      name: json['name']?.toString() ?? 'Unknown responder',
      email: json['email']?.toString() ?? '',
      status: json['responderStatus']?.toString() ?? 'OFFLINE',
      isActive: json['isActive'] == null ? true : json['isActive'] == true,
      phone: _asTrimmedString(json['phone']),
      location: _asTrimmedString(json['location']),
      latitude: _asDoubleOrNull(json['latitude']),
      longitude: _asDoubleOrNull(json['longitude']),
      lastActiveAt: _asDate(json['lastActiveAt']),
      helpTypes: _asMapList(helpTypeRows)
          .map(ResponderHelpType.fromJson)
          .where((row) => row.enabled)
          .toList(growable: false),
      resources: _asMapList(resourceRows)
          .map(BackendResponderResource.fromJson)
          .toList(growable: false),
      compatibleRequestIds: compatibleRows
          .map(_asIntOrNull)
          .whereType<int>()
          .where((id) => id > 0)
          .toSet(),
    );
  }

  BackendResponder withStatus(String nextStatus, {DateTime? updatedAt}) {
    return BackendResponder(
      id: id,
      name: name,
      email: email,
      status: nextStatus,
      isActive: isActive,
      phone: phone,
      location: location,
      latitude: latitude,
      longitude: longitude,
      lastActiveAt: updatedAt ?? lastActiveAt,
      helpTypes: helpTypes,
      resources: resources,
      compatibleRequestIds: compatibleRequestIds,
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
    this.resourceMode = 'CONSUMABLE',
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

  bool get isService => resourceMode == 'SERVICE';

  bool get isAvailable =>
      isEnabled &&
      status == 'AVAILABLE' &&
      (isService || availableQuantity > 0);

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
      responderName: _asTrimmedString(responder['name']) ?? 'Unknown responder',
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
// RESPONDER HELP TYPE (category readiness, independent from physical inventory)
// ---------------------------------------------------------------------------

class ResponderHelpType {
  const ResponderHelpType({
    required this.category,
    this.label,
    this.enabled = true,
  });

  final String category;
  final String? label;
  final bool enabled;

  String get displayLabel => label ?? category;

  factory ResponderHelpType.fromJson(Map<String, dynamic> json) {
    return ResponderHelpType(
      category: (json['category'] ?? json['value'] ?? '').toString(),
      label: json['label']?.toString(),
      enabled: json['enabled'] == null ? true : json['enabled'] == true,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'category': category,
        if (label != null) 'label': label,
        'enabled': enabled,
      };
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

    // The server ships the joined resource row (`resource: {name, type,
    // unit}`). Older or hand-built payloads carry the same values flat
    // (`resourceName` / `resourceType`), so both are accepted instead of
    // silently degrading the label to "Resource #id".
    return RequiredResourceLine(
      resourceId: resourceId,
      quantity: _asInt(json['quantity'], fallback: 1),
      resourceName: _asTrimmedString(resource['name']) ??
          _asTrimmedString(json['resourceName']) ??
          _asTrimmedString(json['name']) ??
          'Resource #$resourceId',
      resourceType: _asTrimmedString(resource['type']) ??
          _asTrimmedString(json['resourceType']) ??
          _asTrimmedString(json['type']) ??
          '',
      unit:
          _asTrimmedString(resource['unit']) ?? _asTrimmedString(json['unit']),
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
// RESPONDER ASSIGNMENT - one row per responder working one emergency
// ---------------------------------------------------------------------------

/// Mirrors the backend `assignments[]` entries in request snapshots
/// (ResponderAssignment rows; see the Phase E realtime contract).
///
/// Only fields the backend actually returns are modeled - nothing is invented.
class ResponderAssignmentLine {
  const ResponderAssignmentLine({
    required this.id,
    required this.requestId,
    required this.responderId,
    required this.status,
    this.acceptedAt,
    this.endedAt,
    this.createdAt,
    this.updatedAt,
    this.responder,
  });

  final int id;
  final int requestId;
  final int responderId;

  /// ACTIVE while the responder is working the emergency, ENDED once their
  /// involvement is over. Backend snapshot is the source of truth.
  final String status;
  final DateTime? acceptedAt;
  final DateTime? endedAt;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// Operational responder summary (id, name, phone, responderStatus,
  /// location, coordinates, lastActiveAt) when the backend includes it.
  final UserSummary? responder;

  bool get isActive => status == 'ACTIVE';
  bool get isEnded => status == 'ENDED';

  factory ResponderAssignmentLine.fromJson(Map<String, dynamic> json) {
    return ResponderAssignmentLine(
      id: _asInt(json['id']),
      requestId: _asInt(json['requestId']),
      responderId: _asInt(json['responderId']),
      status: json['status']?.toString() ?? 'ACTIVE',
      acceptedAt: _asDate(json['acceptedAt']),
      endedAt: _asDate(json['endedAt']),
      createdAt: _asDate(json['createdAt']),
      updatedAt: _asDate(json['updatedAt']),
      responder: UserSummary.fromJson(json['responder']),
    );
  }
}

// ---------------------------------------------------------------------------
// EMERGENCY REQUEST - mirrors the EmergencyRequest table
// ---------------------------------------------------------------------------

List<ResponderAssignmentLine> _parseAssignments(dynamic value) {
  final byResponder = <int, ResponderAssignmentLine>{};
  for (final json in _asMapList(value)) {
    final assignment = ResponderAssignmentLine.fromJson(json);
    // A full REST/socket snapshot is authoritative. If an old proxy duplicated
    // a row, the last copy wins and one responder still renders exactly once.
    byResponder[assignment.responderId] = assignment;
  }
  final rows = byResponder.values.toList(growable: false)
    ..sort((left, right) => left.id.compareTo(right.id));
  return rows;
}

List<AllocationLine> _parseAllocations(dynamic value) {
  final byId = <int, AllocationLine>{};
  for (final json in _asMapList(value)) {
    final allocation = AllocationLine.fromJson(json);
    byId[allocation.id] = allocation;
  }
  final rows = byId.values.toList(growable: false)
    ..sort((left, right) => left.id.compareTo(right.id));
  return rows;
}

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

/// Whether a realtime request payload reports a TERMINAL lifecycle state.
///
/// Works for both Phase E payload shapes:
///   * a full `request` snapshot (`payload['request']['status']`), and
///   * a redacted invalidation that carries only `payload['status']`.
///
/// The backend status string stays authoritative - Flutter never derives or
/// advances the lifecycle itself. Terminal requests must drop every piece of
/// per-request tracking state (all responders, not just one).
bool isTerminalRequestPayload(Map<String, dynamic> payload) {
  final raw = payload['status'] ??
      (payload['request'] is Map
          ? (payload['request'] as Map)['status']
          : null);
  if (raw == null) return false;
  final status = requestStatusFromApi(raw.toString());
  return status == RequestStatus.completed || status == RequestStatus.cancelled;
}

String statusLabel(RequestStatus status) => switch (status) {
      RequestStatus.pending => 'PENDING',
      RequestStatus.accepted => 'ACCEPTED',
      RequestStatus.inProgress => 'IN PROGRESS',
      RequestStatus.partiallyAllocated => 'PARTIAL',
      RequestStatus.completed => 'COMPLETED',
      RequestStatus.cancelled => 'CANCELLED',
    };

PillColors statusColors(RequestStatus status, [ErasPalette? palette]) {
  final p = palette ?? ErasPalette.light;
  switch (status) {
    case RequestStatus.pending:
      return PillColors(p.amberDim, p.amber);
    case RequestStatus.accepted:
      return PillColors(p.blueDim, p.blue);
    case RequestStatus.inProgress:
      return PillColors(p.blueDim, p.blue);
    case RequestStatus.partiallyAllocated:
      return PillColors(p.amberDim, p.amber);
    case RequestStatus.completed:
      return PillColors(p.tealDim, p.teal);
    case RequestStatus.cancelled:
      return PillColors(p.surface2, p.textFaint);
  }
}

PillColors priorityColors(String priority, [ErasPalette? palette]) {
  final p = palette ?? ErasPalette.light;
  switch (priority.toUpperCase()) {
    case 'CRITICAL':
      return PillColors(p.redDim, p.red);
    case 'HIGH':
      return PillColors(p.amberDim, p.amber);
    case 'MEDIUM':
      return PillColors(p.blueDim, p.blue);
    default:
      return PillColors(p.surface2, p.textDim);
  }
}

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
    this.assignments = const <ResponderAssignmentLine>[],
    this.requester,
    this.acceptedBy,
    this.acceptedById,
    this.acceptedAt,
    this.updatedAt,
    this.latitude,
    this.longitude,
  });

  final int id;
  final String emergencyType;
  final String? description;
  final String location;
  final String priority;
  final RequestStatus status;
  final String statusRaw;
  final DateTime createdAt;
  final DateTime? acceptedAt;
  final DateTime? updatedAt;
  final List<RequiredResourceLine> requiredResources;
  final List<AllocationLine> allocations;

  /// Multi-responder membership (ResponderAssignment rows). Defaults to an
  /// empty list, so payloads from backends without assignments still parse.
  final List<ResponderAssignmentLine> assignments;
  final UserSummary? requester;

  /// First/lead responder (legacy compatibility, never overwritten by the
  /// backend). Additional responders live in [assignments].
  final UserSummary? acceptedBy;

  /// Preserved even when an older/redacted payload omits the acceptedBy
  /// summary. The richer [acceptedBy] object remains the display source.
  final int? acceptedById;
  final double? latitude;
  final double? longitude;

  /// Human readable id used all over the dispatch board (DB-201).
  String get displayId => 'DB-$id';

  bool get hasPreciseLocation => isValidCoordinatePair(latitude, longitude);

  String? get coordinateLabel =>
      hasPreciseLocation ? formatCoordinatePair(latitude!, longitude!) : null;

  bool get isOpen =>
      status != RequestStatus.completed && status != RequestStatus.cancelled;

  bool get canBeCancelledByRequester =>
      status != RequestStatus.completed && status != RequestStatus.cancelled;

  List<AllocationLine> get activeAllocations =>
      allocations.where((a) => a.isActive).toList(growable: false);

  /// Assignments with ACTIVE status only. ENDED rows are history, never
  /// active work (Part 15).
  List<ResponderAssignmentLine> get activeAssignments =>
      assignments.where((a) => a.isActive).toList(growable: false);

  /// Modern assignment test: ONLY an ACTIVE ResponderAssignment counts.
  /// acceptedBy alone is never treated as an assignment except through the
  /// explicit legacy helper below.
  bool isAssignedTo(int userId) =>
      assignments.any((a) => a.isActive && a.responderId == userId);

  /// Legacy compatibility: a pre-assignment-era lead pair carries only
  /// acceptedBy. Exactly like the backend's per-pair rule, it counts only
  /// when NO assignment row exists for THIS responder on this request -
  /// once the pair has a row (ACTIVE or ENDED), the table alone decides.
  bool isLegacyAcceptedBy(int? userId) =>
      userId != null &&
      (acceptedBy?.id ?? acceptedById) == userId &&
      !assignments.any((a) => a.responderId == userId);

  /// The responder owns an unfinished (RESERVED/DISPATCHED) allocation on
  /// this request. Allocation intentionally requires no assignment
  /// (Part 7, category B - the allocation-only flow).
  bool ownsUnfinishedAllocation(int? userId) => userId != null
      ? allocations.any(
          (a) => a.responderId == userId && (a.isReserved || a.isDispatched))
      : false;

  /// Full realtime-participation test mirroring the backend Socket.IO rule
  /// (Phase E): ACTIVE assignment OR unfinished allocation OR the legacy
  /// acceptedBy fallback. This is what authorizes room subscriptions and
  /// live-location sharing client-side; the backend stays authoritative.
  bool participatesAsResponder(int? userId) =>
      userId != null &&
      (isAssignedTo(userId) ||
          ownsUnfinishedAllocation(userId) ||
          isLegacyAcceptedBy(userId));

  /// De-duplicated responder identities participating through an ACTIVE
  /// assignment, unfinished allocation, or the pair-scoped legacy lead.
  Set<int> get activeParticipantResponderIds {
    final ids = <int>{
      ...activeAssignments.map((assignment) => assignment.responderId),
      ...allocations
          .where(
              (allocation) => allocation.isReserved || allocation.isDispatched)
          .map((allocation) => allocation.responderId),
    }..removeWhere((id) => id <= 0);
    final leadId = acceptedBy?.id ?? acceptedById;
    if (leadId != null && isLegacyAcceptedBy(leadId)) ids.add(leadId);
    return Set<int>.unmodifiable(ids);
  }

  /// ACTIVE assigned responders (assignment summaries), excluding the lead
  /// responder who is rendered separately through the preserved acceptedBy
  /// fields.
  List<ResponderAssignmentLine> get additionalActiveAssignments {
    final leadId = acceptedBy?.id;
    return activeAssignments
        .where((a) => a.responderId != leadId)
        .toList(growable: false);
  }

  /// Merge one assignment row into the snapshot (responder.assigned event).
  /// The pair (requestId, responderId) is unique in the backend, so an
  /// existing row for the same responder is replaced, never duplicated.
  EmergencyRequest withAssignment(ResponderAssignmentLine assignment) {
    final byResponder = <int, ResponderAssignmentLine>{
      for (final existing in assignments) existing.responderId: existing,
      assignment.responderId: assignment,
    };
    final nextAssignments = byResponder.values.toList(growable: false)
      ..sort((a, b) => a.id.compareTo(b.id));

    return EmergencyRequest(
      id: id,
      emergencyType: emergencyType,
      description: description,
      location: location,
      priority: priority,
      status: status,
      statusRaw: statusRaw,
      createdAt: createdAt,
      requiredResources: requiredResources,
      allocations: allocations,
      assignments: nextAssignments,
      requester: requester,
      acceptedBy: acceptedBy,
      acceptedById: acceptedById,
      acceptedAt: acceptedAt,
      updatedAt: updatedAt,
      latitude: latitude,
      longitude: longitude,
    );
  }

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
    ]..sort((left, right) => left.id.compareTo(right.id));
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
      assignments: assignments,
      requester: requester,
      acceptedBy: acceptedBy,
      acceptedById: acceptedById,
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
      description: _asOptionalStoredText(json['description']),
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
      allocations: _parseAllocations(json['allocations']),
      // Backward compatible: old payloads without assignments parse to an
      // empty list (null-safe, no cast failures). Duplicate rows from repeated
      // realtime/reconnect delivery collapse by responder identity.
      assignments: _parseAssignments(json['assignments']),
      requester: UserSummary.fromJson(json['requester']),
      acceptedBy: UserSummary.fromJson(json['acceptedBy']),
      acceptedById: _asIntOrNull(json['acceptedById']) ??
          UserSummary.fromJson(json['acceptedBy'])?.id,
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

ResourceMeta resourceMetaFor(String typeOrName, [ErasPalette? palette]) {
  final p = palette ?? ErasPalette.light;
  final value = typeOrName.toUpperCase();

  if (value.contains('AMBULANCE') || value.contains('MEDICAL')) {
    return ResourceMeta(Icons.local_hospital, p.redDim, p.red);
  }
  if (value.contains('BLOOD')) {
    return ResourceMeta(Icons.water_drop, p.bloodBg, p.bloodText);
  }
  if (value.contains('OXYGEN')) {
    return ResourceMeta(Icons.air, p.blueDim, p.blue);
  }
  if (value.contains('FIRE')) {
    return ResourceMeta(Icons.local_fire_department, p.amberDim, p.amber);
  }
  if (value.contains('VOLUNTEER') || value.contains('PEOPLE')) {
    return ResourceMeta(Icons.groups, p.tealDim, p.teal);
  }
  if (value.contains('BOAT') || value.contains('RESCUE')) {
    return ResourceMeta(Icons.directions_boat, p.blueDim, p.blue);
  }
  if (value.contains('FOOD') || value.contains('WATER')) {
    return ResourceMeta(Icons.local_drink, p.tealDim, p.teal);
  }

  return ResourceMeta(Icons.inventory_2, p.surface2, p.textDim);
}

Color responderStatusColor(String status, [ErasPalette? palette]) {
  final p = palette ?? ErasPalette.light;
  switch (status.toUpperCase()) {
    case 'AVAILABLE':
      return p.teal;
    case 'BUSY':
      return p.blue;
    default:
      return p.textFaint;
  }
}

String formatCoordinatePair(double latitude, double longitude) =>
    '${latitude.toStringAsFixed(6)}, ${longitude.toStringAsFixed(6)}';

/// Views available in the console. Which ones are shown depends on the role
/// of the logged in user (see navItemsForRole).
enum ConsoleView { board, newRequest, resources, responders, log, users }

class NavItem {
  const NavItem(this.view, this.icon, this.label);
  final ConsoleView view;
  final IconData icon;
  final String label;
}

List<NavItem> navItemsForRole(String? role) {
  return <NavItem>[
    const NavItem(ConsoleView.board, Icons.dashboard_outlined, 'Board'),
    if (role == 'REQUESTER' || role == 'ADMIN')
      const NavItem(
        ConsoleView.newRequest,
        Icons.add_circle_outline,
        'New Emergency',
      ),
    const NavItem(
        ConsoleView.resources, Icons.inventory_2_outlined, 'Resources'),
    const NavItem(
        ConsoleView.responders, Icons.groups_2_outlined, 'Responders'),
    const NavItem(ConsoleView.log, Icons.receipt_long_outlined, 'Log'),
    if (role == 'ADMIN')
      const NavItem(ConsoleView.users, Icons.manage_accounts_outlined, 'Users'),
  ];
}

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
