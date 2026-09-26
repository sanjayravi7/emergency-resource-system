import 'package:flutter/foundation.dart';

import '../models/eras_models.dart';

/// Request-scoped responder telemetry used by the board and Google Map.
///
/// This is deliberately not a request/allocation lifecycle model. Request and
/// allocation state still comes exclusively from PostgreSQL. The store only
/// tracks ephemeral GPS sharing state and the latest authorized coordinate so
/// a location event can repaint the relevant UI without reloading the board.
///
/// PHASE F: state is keyed by (requestId, responderId) so multiple responders
/// can stream locations for the same emergency without overwriting each
/// other. A responder's update or stop only ever touches that responder's
/// entry; terminal cleanup clears the whole request.
class LiveLocationStore extends ChangeNotifier {
  /// requestId -> responderId -> latest point.
  final Map<int, Map<int, LiveResponderLocation>> _locationsByRequest =
      <int, Map<int, LiveResponderLocation>>{};

  /// requestId -> responder ids currently streaming.
  final Map<int, Set<int>> _activelySharingByRequest = <int, Set<int>>{};

  /// The request (and responder) THIS device is streaming for. A responder
  /// only ever streams their own identity.
  int? _localSharingRequestId;
  int? _localSharingResponderId;

  /// Nested map: every responder point grouped by request.
  Map<int, Map<int, LiveResponderLocation>> get locationsByRequest =>
      Map<int, Map<int, LiveResponderLocation>>.unmodifiable(
        _locationsByRequest.map(
          (requestId, points) => MapEntry(
            requestId,
            Map<int, LiveResponderLocation>.unmodifiable(points),
          ),
        ),
      );

  /// All responder points for one request (empty when none).
  Map<int, LiveResponderLocation> locationsForRequest(int requestId) =>
      Map<int, LiveResponderLocation>.unmodifiable(
        _locationsByRequest[requestId] ?? const <int, LiveResponderLocation>{},
      );

  /// Requests with at least one actively streaming responder.
  Set<int> get activelySharingRequestIds =>
      Set<int>.unmodifiable(_activelySharingByRequest.keys
          .where((requestId) => _activelySharingByRequest[requestId]!.isNotEmpty));

  int? get localSharingRequestId => _localSharingRequestId;
  int? get localSharingResponderId => _localSharingResponderId;

  /// Any responder is currently streaming for this request.
  bool isActivelySharing(int requestId) {
    final responders = _activelySharingByRequest[requestId];
    return responders != null && responders.isNotEmpty;
  }

  /// Whether one specific responder is streaming for this request.
  bool isResponderActivelySharing(int requestId, int responderId) =>
      _activelySharingByRequest[requestId]?.contains(responderId) ?? false;

  /// The latest point of one responder on one request. This pair-keyed
  /// accessor is the authoritative multi-responder API.
  LiveResponderLocation? locationFor(int requestId, int responderId) =>
      _locationsByRequest[requestId]?[responderId];

  /// Convenience accessor for genuinely single-responder contexts: the only
  /// tracked point of [requestId].
  ///
  /// Returns null when the request has no point at all AND when more than
  /// one responder is tracked - an arbitrary responder is never returned,
  /// so a multi-responder emergency can not silently degrade into a
  /// single-responder view. Call [locationFor] with the explicit responder
  /// id whenever the responder is known.
  LiveResponderLocation? singleLocationFor(int requestId) {
    final points = _locationsByRequest[requestId];
    if (points == null || points.length != 1) return null;
    return points.values.first;
  }

  void beginRemoteSharing({required int requestId, required int responderId}) {
    if (requestId <= 0 || responderId <= 0) return;
    final responders =
        _activelySharingByRequest.putIfAbsent(requestId, () => <int>{});
    if (responders.add(responderId)) notifyListeners();
  }

  /// Store one responder's live point (responder.location.update). Never
  /// touches any other responder's entry.
  void applyUpdate(LiveResponderLocation location) {
    if (location.requestId <= 0 || location.responderId <= 0) return;
    _activelySharingByRequest
        .putIfAbsent(location.requestId, () => <int>{})
        .add(location.responderId);
    _locationsByRequest
        .putIfAbsent(location.requestId, () => <int, LiveResponderLocation>{})
        [location.responderId] = location.asLive();
    notifyListeners();
  }

  /// Stop one responder's stream (responder.location.stop). Only that
  /// responder's entry is affected: their last coordinate stays visible as
  /// last-known, every other responder keeps streaming untouched.
  ///
  /// Without [responderId] (legacy callers) every responder of the request
  /// stops and all points become last-known.
  void stopSharing(int requestId, {int? responderId}) {
    var changed = false;

    void markStale(LiveResponderLocation point) {
      if (!point.isLive) return;
      _locationsByRequest[requestId]?[point.responderId] = point.asNotLive();
      changed = true;
    }

    if (responderId != null) {
      final removed = _activelySharingByRequest[requestId]?.remove(responderId);
      if (removed == true) changed = true;
      if (_localSharingRequestId == requestId &&
          _localSharingResponderId == responderId) {
        _localSharingRequestId = null;
        _localSharingResponderId = null;
        changed = true;
      }
      final point = _locationsByRequest[requestId]?[responderId];
      if (point != null) markStale(point);
    } else {
      final responders = _activelySharingByRequest.remove(requestId);
      if (responders != null && responders.isNotEmpty) changed = true;
      if (_localSharingRequestId == requestId) {
        _localSharingRequestId = null;
        _localSharingResponderId = null;
        changed = true;
      }
      final points = _locationsByRequest[requestId];
      if (points != null) {
        for (final point in points.values.toList(growable: false)) {
          markStale(point);
        }
      }
    }
    if (changed) notifyListeners();
  }

  /// Fully remove one responder's point for a request (no last-known trace).
  void remove(int requestId, int responderId) {
    var changed = false;
    final points = _locationsByRequest[requestId];
    if (points != null && points.remove(responderId) != null) {
      changed = true;
      if (points.isEmpty) _locationsByRequest.remove(requestId);
    }
    final responders = _activelySharingByRequest[requestId];
    if (responders != null && responders.remove(responderId)) {
      changed = true;
      if (responders.isEmpty) _activelySharingByRequest.remove(requestId);
    }
    if (_localSharingRequestId == requestId &&
        _localSharingResponderId == responderId) {
      _localSharingRequestId = null;
      _localSharingResponderId = null;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  void beginLocalSharing(int requestId, {int? responderId}) {
    if (requestId <= 0) return;
    final changed = _localSharingRequestId != requestId ||
        _localSharingResponderId != responderId ||
        !isResponderActivelySharing(requestId, responderId ?? 0);
    _localSharingRequestId = requestId;
    _localSharingResponderId = responderId;
    _activelySharingByRequest
        .putIfAbsent(requestId, () => <int>{})
        .add(responderId ?? 0);
    if (changed) notifyListeners();
  }

  void endLocalSharing([int? requestId]) {
    final target = requestId ?? _localSharingRequestId;
    if (target == null) return;
    stopSharing(target, responderId: _localSharingResponderId);
  }

  /// A disconnected socket cannot carry live telemetry. GPS streaming is
  /// stopped by the page and every existing point becomes last-known.
  void markConnectionLost() {
    var changed = _activelySharingByRequest.isNotEmpty ||
        _localSharingRequestId != null;
    _activelySharingByRequest.clear();
    _localSharingRequestId = null;
    _localSharingResponderId = null;

    for (final points in _locationsByRequest.values) {
      for (final entry in points.entries.toList(growable: false)) {
        if (!entry.value.isLive) continue;
        points[entry.key] = entry.value.asNotLive();
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  /// Merge PostgreSQL's throttled responder coordinates after a REST resync.
  /// A currently-live socket coordinate always wins over the persisted point.
  ///
  /// Multi-responder: every ACTIVE assignment responder's persisted point is
  /// merged independently; points of responders who no longer participate
  /// (no ACTIVE assignment, no unfinished allocation, not the legacy lead)
  /// are dropped so the REST snapshot repairs any missed lifecycle change.
  void reconcile(Iterable<EmergencyRequest> requests) {
    final openRequests = <int, EmergencyRequest>{
      for (final request in requests)
        if (request.isOpen) request.id: request,
    };
    var changed = false;

    // 1. Terminal (or vanished) requests lose all tracking state.
    for (final requestId in _locationsByRequest.keys.toList(growable: false)) {
      if (openRequests.containsKey(requestId)) continue;
      _locationsByRequest.remove(requestId);
      _activelySharingByRequest.remove(requestId);
      _forgetLocalSharingFor(requestId);
      changed = true;
    }

    for (final requestId
        in _activelySharingByRequest.keys.toList(growable: false)) {
      if (openRequests.containsKey(requestId)) continue;
      _activelySharingByRequest.remove(requestId);
      _forgetLocalSharingFor(requestId);
      changed = true;
    }

    // 2. Per request: keep only participating responders' points and merge
    //    every participant's persisted coordinate.
    for (final request in openRequests.values) {
      final points = _locationsByRequest[request.id];

      if (points != null) {
        for (final responderId in points.keys.toList(growable: false)) {
          if (request.participatesAsResponder(responderId)) continue;
          points.remove(responderId);
          changed = true;
        }
        if (points.isEmpty) _locationsByRequest.remove(request.id);
      }

      final activeResponders = _activelySharingByRequest[request.id];
      if (activeResponders != null) {
        for (final responderId
            in activeResponders.toList(growable: false)) {
          if (request.participatesAsResponder(responderId)) continue;
          activeResponders.remove(responderId);
          changed = true;
        }
        if (activeResponders.isEmpty) {
          _activelySharingByRequest.remove(request.id);
        }
      }

      for (final summary in _participatingResponderSummaries(request)) {
        if (summary.latitude == null || summary.longitude == null) continue;

        final existing = _locationsByRequest[request.id]?[summary.id];
        if (existing?.isLive == true) continue;

        final persisted = LiveResponderLocation(
          requestId: request.id,
          responderId: summary.id,
          latitude: summary.latitude!,
          longitude: summary.longitude!,
          updatedAt:
              summary.lastActiveAt ?? request.updatedAt ?? request.createdAt,
          isLive: false,
        );

        if (!_sameLocation(existing, persisted)) {
          _locationsByRequest
              .putIfAbsent(request.id, () => <int, LiveResponderLocation>{})
              [summary.id] = persisted;
          changed = true;
        }
      }
    }

    if (changed) notifyListeners();
  }

  /// Terminal requests must not retain either active or last-known tracking
  /// for ANY responder of that request.
  void removeRequest(int requestId) {
    final removedLocation = _locationsByRequest.remove(requestId) != null;
    final removedActive = _activelySharingByRequest.remove(requestId) != null;
    final removedLocal = _localSharingRequestId == requestId;
    if (removedLocal) {
      _localSharingRequestId = null;
      _localSharingResponderId = null;
    }
    if (removedLocation || removedActive || removedLocal) notifyListeners();
  }

  /// Alias of [removeRequest] for the Phase F multi-responder vocabulary.
  void clearRequest(int requestId) => removeRequest(requestId);

  /// Persisted (throttled) coordinates of every responder the backend
  /// snapshot still associates with the request. Same participation contract
  /// as Phase E / [EmergencyRequest.participatesAsResponder]:
  ///   * ACTIVE assignment holders,
  ///   * (allocation-only participants keep any live/last-known point they
  ///     already have - the allocation payload carries no coordinates, so
  ///     there is nothing to merge for them),
  ///   * the legacy acceptedBy lead (pair-scoped rule: only when the lead
  ///     has no assignment row of their own).
  Iterable<UserSummary> _participatingResponderSummaries(
    EmergencyRequest request,
  ) sync* {
    final seen = <int>{};
    for (final assignment in request.activeAssignments) {
      final responder = assignment.responder;
      if (responder == null || !seen.add(responder.id)) continue;
      yield responder;
    }

    final lead = request.acceptedBy;
    if (lead != null &&
        request.isLegacyAcceptedBy(lead.id) &&
        seen.add(lead.id)) {
      yield lead;
    }
  }

  void _forgetLocalSharingFor(int requestId) {
    if (_localSharingRequestId == requestId) {
      _localSharingRequestId = null;
      _localSharingResponderId = null;
    }
  }

  bool _sameLocation(
    LiveResponderLocation? left,
    LiveResponderLocation right,
  ) {
    return left != null &&
        left.requestId == right.requestId &&
        left.responderId == right.responderId &&
        left.latitude == right.latitude &&
        left.longitude == right.longitude &&
        left.updatedAt == right.updatedAt &&
        left.isLive == right.isLive;
  }
}
