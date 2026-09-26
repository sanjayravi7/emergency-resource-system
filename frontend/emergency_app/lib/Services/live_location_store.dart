import 'package:flutter/foundation.dart';

import '../models/eras_models.dart';

/// Request-scoped responder telemetry used by the board and Google Map.
///
/// This is deliberately not a request/allocation lifecycle model. Request and
/// allocation state still comes exclusively from PostgreSQL. The store only
/// tracks ephemeral GPS sharing state and the latest authorized coordinate so
/// a location event can repaint the relevant UI without reloading the board.
class LiveLocationStore extends ChangeNotifier {
  final Map<int, LiveResponderLocation> _locations =
      <int, LiveResponderLocation>{};
  final Set<int> _activelySharing = <int>{};
  int? _localSharingRequestId;

  Map<int, LiveResponderLocation> get locations =>
      Map<int, LiveResponderLocation>.unmodifiable(_locations);

  Set<int> get activelySharingRequestIds =>
      Set<int>.unmodifiable(_activelySharing);

  int? get localSharingRequestId => _localSharingRequestId;

  bool isActivelySharing(int requestId) => _activelySharing.contains(requestId);

  LiveResponderLocation? locationFor(int requestId) => _locations[requestId];

  void beginRemoteSharing({required int requestId, required int responderId}) {
    if (requestId <= 0 || responderId <= 0) return;
    if (_activelySharing.add(requestId)) notifyListeners();
  }

  void applyUpdate(LiveResponderLocation location) {
    if (location.requestId <= 0 || location.responderId <= 0) return;
    _activelySharing.add(location.requestId);
    _locations[location.requestId] = location.asLive();
    notifyListeners();
  }

  /// Keep the last coordinate visible, but explicitly mark it as stale.
  void stopSharing(int requestId) {
    var changed = _activelySharing.remove(requestId);
    if (_localSharingRequestId == requestId) {
      _localSharingRequestId = null;
      changed = true;
    }

    final existing = _locations[requestId];
    if (existing != null && existing.isLive) {
      _locations[requestId] = existing.asNotLive();
      changed = true;
    }
    if (changed) notifyListeners();
  }

  void beginLocalSharing(int requestId) {
    if (requestId <= 0) return;
    final changed =
        _localSharingRequestId != requestId ||
        !_activelySharing.contains(requestId);
    _localSharingRequestId = requestId;
    _activelySharing.add(requestId);
    if (changed) notifyListeners();
  }

  void endLocalSharing([int? requestId]) {
    final target = requestId ?? _localSharingRequestId;
    if (target == null) return;
    stopSharing(target);
  }

  /// A disconnected socket cannot carry live telemetry. GPS streaming is
  /// stopped by the page and every existing point becomes last-known.
  void markConnectionLost() {
    var changed = _activelySharing.isNotEmpty || _localSharingRequestId != null;
    _activelySharing.clear();
    _localSharingRequestId = null;

    for (final entry in _locations.entries.toList(growable: false)) {
      if (!entry.value.isLive) continue;
      _locations[entry.key] = entry.value.asNotLive();
      changed = true;
    }
    if (changed) notifyListeners();
  }

  /// Merge PostgreSQL's throttled responder coordinate after a REST resync.
  /// A currently-live socket coordinate always wins over the persisted point.
  void reconcile(Iterable<EmergencyRequest> requests) {
    final openRequests = <int, EmergencyRequest>{
      for (final request in requests)
        if (request.isOpen) request.id: request,
    };
    var changed = false;

    for (final requestId in _locations.keys.toList(growable: false)) {
      if (openRequests.containsKey(requestId)) continue;
      _locations.remove(requestId);
      _activelySharing.remove(requestId);
      if (_localSharingRequestId == requestId) _localSharingRequestId = null;
      changed = true;
    }

    for (final requestId in _activelySharing.toList(growable: false)) {
      if (openRequests.containsKey(requestId)) continue;
      _activelySharing.remove(requestId);
      if (_localSharingRequestId == requestId) _localSharingRequestId = null;
      changed = true;
    }

    for (final request in openRequests.values) {
      final responder = request.acceptedBy;
      if (responder == null ||
          responder.latitude == null ||
          responder.longitude == null) {
        continue;
      }

      final existing = _locations[request.id];
      if (existing?.isLive == true) continue;

      final persisted = LiveResponderLocation(
        requestId: request.id,
        responderId: responder.id,
        latitude: responder.latitude!,
        longitude: responder.longitude!,
        updatedAt:
            responder.lastActiveAt ?? request.updatedAt ?? request.createdAt,
        isLive: false,
      );

      if (!_sameLocation(existing, persisted)) {
        _locations[request.id] = persisted;
        changed = true;
      }
    }

    if (changed) notifyListeners();
  }

  /// Terminal requests must not retain either active or last-known tracking.
  void removeRequest(int requestId) {
    final removedLocation = _locations.remove(requestId) != null;
    final removedActive = _activelySharing.remove(requestId);
    final removedLocal = _localSharingRequestId == requestId;
    if (removedLocal) _localSharingRequestId = null;
    if (removedLocation || removedActive || removedLocal) notifyListeners();
  }

  bool _sameLocation(LiveResponderLocation? left, LiveResponderLocation right) {
    return left != null &&
        left.requestId == right.requestId &&
        left.responderId == right.responderId &&
        left.latitude == right.latitude &&
        left.longitude == right.longitude &&
        left.updatedAt == right.updatedAt &&
        left.isLive == right.isLive;
  }
}
