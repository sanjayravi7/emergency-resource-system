/// Owns the single "responder → emergency" road route shown on the operational
/// Google Map.
///
/// Responsibilities:
///   * Part F — decide whether a route may exist at all (assigned responder,
///     active request, both coordinate pairs present).
///   * Part E — throttle route recalculation so a high frequency Socket.IO GPS
///     stream never turns into a high frequency Routes API bill.
///   * Keep the previous route visible while a new one is being computed, and
///     surface failures without removing markers or the old route.
///
/// This class contains no Google types and no widgets, so it is fully unit
/// testable with a fake [RouteService].
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/eras_models.dart';
import 'location_service.dart' show GeoPoint;
import 'route_service.dart';

/// Minimum wall-clock gap between two Routes API requests for the same
/// emergency.
const Duration kRouteMinimumInterval = Duration(seconds: 15);

/// Minimum responder movement (metres) before the road route is recomputed.
///
/// Part E allows "15 s" OR "100 m", "whichever provides the safer request
/// volume": requiring **both** is strictly safer than either alone, so a
/// steady-state recalculation needs 15 s *and* 100 m. A changed emergency (or
/// a first route, or a retry after a failure) bypasses the movement rule — see
/// [ActiveRouteController.shouldRequestRoute].
const double kRouteMinimumMovementMeters = 100;

/// The pair of coordinates a route may be computed for.
@immutable
class RouteTarget {
  const RouteTarget({
    required this.requestId,
    required this.responderId,
    required this.origin,
    required this.destination,
    required this.responderIsLive,
  });

  final int requestId;
  final int responderId;

  /// Responder's latest live (or last known) position.
  final GeoPoint origin;

  /// The emergency request coordinates.
  final GeoPoint destination;

  /// Whether [origin] came from an active Socket.IO stream.
  final bool responderIsLive;

  @override
  bool operator ==(Object other) =>
      other is RouteTarget &&
      other.requestId == requestId &&
      other.responderId == responderId &&
      other.origin == origin &&
      other.destination == destination;

  @override
  int get hashCode => Object.hash(requestId, responderId, origin, destination);
}

/// Part F: picks the one emergency that may show a road route.
///
/// A route is allowed only when
///   * the request is still active (not completed/cancelled),
///   * the request has latitude + longitude,
///   * a responder accepted the request, and
///   * that same responder has a current or last-known coordinate.
///
/// Returns null when no request qualifies. Live responders win over
/// last-known ones; ties are resolved by request id so the choice is stable.
RouteTarget? selectRouteTarget({
  required Iterable<EmergencyRequest> requests,
  required Map<int, LiveResponderLocation> liveLocations,
}) {
  final candidates = <RouteTarget>[];

  for (final request in requests) {
    if (!request.isOpen) continue;
    if (!request.hasPreciseLocation) continue;

    final responder = request.acceptedBy;
    if (responder == null) continue;

    final live = liveLocations[request.id];
    if (live == null) continue;
    if (live.responderId != responder.id) continue;

    candidates.add(
      RouteTarget(
        requestId: request.id,
        responderId: responder.id,
        origin: GeoPoint(live.latitude, live.longitude),
        destination: GeoPoint(request.latitude!, request.longitude!),
        responderIsLive: live.isLive,
      ),
    );
  }

  if (candidates.isEmpty) return null;

  candidates.sort((left, right) {
    if (left.responderIsLive != right.responderIsLive) {
      return left.responderIsLive ? -1 : 1;
    }
    return left.requestId.compareTo(right.requestId);
  });

  return candidates.first;
}

class ActiveRouteController extends ChangeNotifier {
  ActiveRouteController({
    required this.routeService,
    this.minimumInterval = kRouteMinimumInterval,
    this.minimumMovementMeters = kRouteMinimumMovementMeters,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final RouteService routeService;
  final Duration minimumInterval;
  final double minimumMovementMeters;
  final DateTime Function() _clock;

  RoutePlan? _route;
  RouteTarget? _target;
  RouteTarget? _lastRequestedTarget;
  DateTime? _lastRequestedAt;
  bool _isUpdating = false;
  String? _errorMessage;
  int _requestToken = 0;
  bool _disposed = false;

  /// The currently displayed route. Stays non-null while a newer route is
  /// being computed and while a recalculation fails.
  RoutePlan? get route => _route;

  /// True while a Routes API request is in flight. The UI shows a subtle
  /// "Updating route…" hint instead of clearing the map.
  bool get isUpdating => _isUpdating;

  /// Non-blocking error text for the last failed attempt (null when the last
  /// attempt succeeded).
  String? get errorMessage => _errorMessage;

  /// The emergency the current route belongs to.
  int? get requestId => _target?.requestId;

  RouteTarget? get target => _target;

  bool get hasRoute => _route != null;

  /// Number of Routes API requests actually issued (diagnostics/tests).
  int get requestCount => _requestCount;
  int _requestCount = 0;

  /// Part E throttle decision.
  ///
  /// Returns true when a new Routes API request is allowed for [target] at
  /// [now].
  bool shouldRequestRoute(RouteTarget target, DateTime now) {
    if (_isUpdating) return false;

    final previous = _lastRequestedTarget;
    final previousAt = _lastRequestedAt;
    if (previous == null || previousAt == null) return true;

    // A different emergency, or an emergency whose coordinates changed, is a
    // different route: recompute immediately.
    if (previous.requestId != target.requestId) return true;
    if (previous.destination != target.destination) return true;

    // Hard floor: never more than one request per [minimumInterval].
    if (now.difference(previousAt) < minimumInterval) return false;

    // No successful route yet (previous attempt failed): retry once per
    // interval even if the responder did not move.
    if (_route == null) return true;

    // Steady state: also require real movement.
    final moved = distanceBetweenMeters(previous.origin, target.origin);
    return moved >= minimumMovementMeters;
  }

  /// Re-evaluates the board state and, when allowed, refreshes the route.
  ///
  /// Safe to call on every Socket.IO location update and every rebuild: the
  /// throttle above decides whether a request actually happens.
  Future<void> sync({
    required Iterable<EmergencyRequest> requests,
    required Map<int, LiveResponderLocation> liveLocations,
  }) {
    final target = selectRouteTarget(
      requests: requests,
      liveLocations: liveLocations,
    );

    if (target == null) {
      _clearRoute();
      return Future<void>.value();
    }

    final previousTarget = _target;
    _target = target;

    // Switching emergencies must never show the old emergency's road route.
    if (previousTarget != null && previousTarget.requestId != target.requestId) {
      _route = null;
      _errorMessage = null;
    }

    if (previousTarget != target) _notify();

    if (!shouldRequestRoute(target, _clock())) {
      return Future<void>.value();
    }

    return _request(target);
  }

  /// Forces a recalculation for the current target, ignoring the throttle.
  /// Used by the manual "retry" affordance.
  Future<void> refresh() {
    final target = _target;
    if (target == null || _isUpdating) return Future<void>.value();
    return _request(target);
  }

  Future<void> _request(RouteTarget target) async {
    final token = ++_requestToken;
    _isUpdating = true;
    _lastRequestedTarget = target;
    _lastRequestedAt = _clock();
    _requestCount++;
    _notify();

    try {
      final plan = await routeService.computeRoute(
        origin: target.origin,
        destination: target.destination,
      );

      // A newer request (or a cleared route) superseded this one.
      if (token != _requestToken || _disposed) return;

      _route = plan;
      _errorMessage = null;
    } catch (error) {
      if (token != _requestToken || _disposed) return;

      // Keep the previous route and the responder marker; only report.
      _errorMessage = error is RouteServiceException
          ? error.message
          : 'Route unavailable: $error';
    } finally {
      if (token == _requestToken && !_disposed) {
        _isUpdating = false;
        _notify();
      }
    }
  }

  /// Terminal (completed/cancelled) or no-longer-routable state: drop the
  /// route, stop recalculating and ignore any in-flight response.
  void _clearRoute() {
    final hadState = _route != null ||
        _target != null ||
        _isUpdating ||
        _errorMessage != null;

    _requestToken++;
    _route = null;
    _target = null;
    _lastRequestedTarget = null;
    _lastRequestedAt = null;
    _isUpdating = false;
    _errorMessage = null;

    if (hadState) _notify();
  }

  /// Notifications are always deferred by one microtask so a listener's
  /// setState can never run inside an ongoing build phase.
  void _notify() {
    scheduleMicrotask(() {
      if (_disposed) return;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _requestToken++;
    super.dispose();
  }
}
