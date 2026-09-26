import '../models/eras_models.dart';

/// Request-scoped responder positions.
///
/// This is a pure state holder: it never invents a coordinate, never derives a
/// request lifecycle and never talks to the network. It only stores what the
/// backend already sent (a Socket.IO `responder.location.*` event, or the
/// throttled last known point that came back with a REST request payload) and
/// answers "is this point live or last known?".
///
/// Keeping it outside the page widget makes the live-location behaviour
/// testable without a socket, and lets the console apply targeted updates
/// instead of reloading the whole application on every GPS tick.
class LiveLocationStore {
  LiveLocationStore({this.staleAfter = const Duration(seconds: 60)});

  /// A "live" point with no follow-up update for this long is downgraded to
  /// last known, so the map cannot keep claiming live tracking forever.
  final Duration staleAfter;

  final Map<int, LiveResponderLocation> _byRequestId =
      <int, LiveResponderLocation>{};

  int _revision = 0;

  /// Increments on every accepted change. Widgets and the map painter compare
  /// this instead of deep-comparing the map on every frame.
  int get revision => _revision;

  Map<int, LiveResponderLocation> get snapshot =>
      Map<int, LiveResponderLocation>.unmodifiable(_byRequestId);

  int get length => _byRequestId.length;

  bool get isEmpty => _byRequestId.isEmpty;

  LiveResponderLocation? locationFor(int requestId) => _byRequestId[requestId];

  bool hasLiveTracking(int requestId) =>
      _byRequestId[requestId]?.isLive == true;

  /// requestIds that are currently being tracked live.
  List<int> get liveRequestIds => _byRequestId.entries
      .where((entry) => entry.value.isLive)
      .map((entry) => entry.key)
      .toList(growable: false);

  bool _touch(bool changed) {
    if (changed) _revision++;
    return changed;
  }

  /// `responder.location.update` for one request room.
  bool applyLiveUpdate(LiveResponderLocation location) {
    if (location.requestId <= 0) return false;
    _byRequestId[location.requestId] = location;
    return _touch(true);
  }

  /// `responder.location.stop`: the point stays on the map, but as the last
  /// known position instead of a live one.
  bool markLastKnown(int requestId) {
    final existing = _byRequestId[requestId];
    if (existing == null) return false;
    if (!existing.isLive) return false;
    _byRequestId[requestId] = existing.asNotLive();
    return _touch(true);
  }

  /// COMPLETED / CANCELLED request: no tracking of any kind survives.
  bool removeForRequest(int requestId) {
    final removed = _byRequestId.remove(requestId);
    return _touch(removed != null);
  }

  /// REST reconciliation. Closed requests are dropped and each open request
  /// that has a persisted responder coordinate seeds a last-known marker -
  /// but never overwrites an active live point.
  bool syncWithOpenRequests(Iterable<EmergencyRequest> openRequests) {
    var changed = false;
    final openIds = <int>{};

    for (final request in openRequests) {
      if (!request.isOpen) continue;
      openIds.add(request.id);
    }

    final staleKeys = _byRequestId.keys
        .where((requestId) => !openIds.contains(requestId))
        .toList(growable: false);
    for (final requestId in staleKeys) {
      _byRequestId.remove(requestId);
      changed = true;
    }

    for (final request in openRequests) {
      if (_seedLastKnown(request)) changed = true;
    }

    return _touch(changed);
  }

  /// Seed (or refresh) the last known point of a single request from the
  /// throttled coordinate PostgreSQL returned with it. A live point always
  /// wins - REST must never downgrade an active stream.
  bool seedLastKnownFor(EmergencyRequest request) =>
      _touch(_seedLastKnown(request));

  bool _seedLastKnown(EmergencyRequest request) {
    if (!request.isOpen) return false;

    final responder = request.acceptedBy;
    final latitude = responder?.latitude;
    final longitude = responder?.longitude;
    if (responder == null || latitude == null || longitude == null) {
      return false;
    }

    final existing = _byRequestId[request.id];
    if (existing != null && existing.isLive) return false;
    if (existing != null &&
        existing.latitude == latitude &&
        existing.longitude == longitude) {
      return false;
    }

    _byRequestId[request.id] = LiveResponderLocation(
      requestId: request.id,
      responderId: responder.id,
      latitude: latitude,
      longitude: longitude,
      updatedAt: existing?.updatedAt ?? DateTime.now(),
      isLive: false,
    );
    return true;
  }

  /// Downgrade live points that stopped arriving (socket dropped, responder
  /// device asleep, ...). The marker remains visible as last known.
  bool expireStale(DateTime now) {
    var changed = false;
    for (final entry in _byRequestId.entries.toList(growable: false)) {
      final location = entry.value;
      if (!location.isLive) continue;
      if (now.difference(location.updatedAt) < staleAfter) continue;
      _byRequestId[entry.key] = location.asNotLive();
      changed = true;
    }
    return _touch(changed);
  }

  /// Realtime transport is gone: nothing is live any more, but the last known
  /// positions stay on the map.
  bool markAllLastKnown() {
    var changed = false;
    for (final entry in _byRequestId.entries.toList(growable: false)) {
      if (!entry.value.isLive) continue;
      _byRequestId[entry.key] = entry.value.asNotLive();
      changed = true;
    }
    return _touch(changed);
  }

  void clear() {
    if (_byRequestId.isEmpty) return;
    _byRequestId.clear();
    _revision++;
  }
}
