import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../Services/api_service.dart';
import '../Services/live_location_store.dart';
import '../Services/socket_service.dart';
import '../models/eras_models.dart';
import '../services/location_service.dart';
import '../theme/app_theme.dart';
import '../widgets/allocation_dialog.dart';
import '../widgets/board_panel.dart';
import '../widgets/common_widgets.dart';
import '../widgets/log_panel.dart';
import '../widgets/new_request_panel.dart';
import '../widgets/operational_google_map.dart';
import '../widgets/operational_status.dart';
import '../widgets/resource_panels.dart';
import 'login_screen.dart';
import 'responder_readiness_page.dart';

/// Single place where the app talks to the backend.
///
/// Every mutation is followed by an explicit reload of the affected data, so
/// the UI always shows what PostgreSQL contains. A push transport (Socket.IO)
/// could later call the very same reload methods.
class DispatchConsolePage extends StatefulWidget {
  const DispatchConsolePage({super.key, this.readinessSuccess = false});

  final bool readinessSuccess;

  @override
  State<DispatchConsolePage> createState() => _DispatchConsolePageState();
}

class _DispatchConsolePageState extends State<DispatchConsolePage> {
  final List<BackendResource> resources = <BackendResource>[];
  final List<BackendResponder> responders = <BackendResponder>[];
  final List<BackendResponderResource> myInventory =
      <BackendResponderResource>[];

  /// Open requests relevant to the signed in user.
  final List<EmergencyRequest> openRequests = <EmergencyRequest>[];

  /// PENDING requests a responder is able to serve (compatible list).
  final List<EmergencyRequest> pendingCompatible = <EmergencyRequest>[];

  /// Completed / cancelled requests.
  final List<EmergencyRequest> logEntries = <EmergencyRequest>[];

  ConsoleView activeView = ConsoleView.board;
  bool loading = false;
  bool submitting = false;
  DateTime now = DateTime.now();

  Timer? clockTimer;
  Timer? refreshTimer;
  Timer? heartbeatTimer;
  StreamSubscription<RealtimeEvent>? realtimeEventsSubscription;
  StreamSubscription<SocketConnectionState>? socketStateSubscription;
  StreamSubscription<Position>? locationSubscription;
  final LiveLocationStore locationStore = LiveLocationStore();
  final Set<int> _subscribedRequestIds = <int>{};
  RealtimeConnectionStatus connectionStatus = RealtimeConnectionStatus.offline;
  bool _hasConnectedOnce = false;
  bool _needsReconnectReconciliation = false;

  String? get role => ApiService.currentRole;
  bool get isRequester => role == 'REQUESTER';
  bool get isResponder => role == 'RESPONDER';
  bool get isAdmin => role == 'ADMIN';

  @override
  void initState() {
    super.initState();

    realtimeEventsSubscription =
        SocketService.instance.events.listen(_handleRealtimeEvent);
    connectionStatus = SocketService.instance.currentConnection.status;
    socketStateSubscription = SocketService.instance.connectionStates.listen(
      (state) => unawaited(_handleSocketConnectionState(state)),
    );
    SocketService.instance.connect();
    connectionStatus = SocketService.instance.currentConnection.status;
    refreshAll();

    clockTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) {
        if (!mounted) return;
        setState(() => now = DateTime.now());
      },
    );

    // Reliable polling refresh. Replaceable by Socket.IO later without
    // touching the widgets.
    refreshTimer = Timer.periodic(
      const Duration(seconds: 20),
      (_) => refreshAll(silent: true),
    );

    if (isResponder) {
      // Best-effort activity signal only; a missed request does not flip the
      // responder's status or disturb assigned emergencies.
      ApiService.responderHeartbeat().catchError((_) {});
      heartbeatTimer = Timer.periodic(
        const Duration(seconds: 60),
        (_) => ApiService.responderHeartbeat().catchError((_) {}),
      );
    }

    if (widget.readinessSuccess) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        showToast('You are now available for selected resources.');
      });
    }
  }

  @override
  void dispose() {
    clockTimer?.cancel();
    refreshTimer?.cancel();
    heartbeatTimer?.cancel();
    realtimeEventsSubscription?.cancel();
    socketStateSubscription?.cancel();
    final sharingRequestId = locationStore.localSharingRequestId;
    locationSubscription?.cancel();
    if (sharingRequestId != null && SocketService.instance.isConnected) {
      SocketService.instance.stopLocationSharing(sharingRequestId);
    }
    locationStore.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------
  // REALTIME
  // -------------------------------------------------------------------

  Future<void> _handleSocketConnectionState(
    SocketConnectionState state,
  ) async {
    if (!mounted) return;

    if (!state.connected) {
      if (_hasConnectedOnce) _needsReconnectReconciliation = true;
      _subscribedRequestIds.clear();
      await _stopLocalLocationSharing(
        locationStore.localSharingRequestId,
        emitStop: false,
      );
      locationStore.markConnectionLost();
    }

    if (!mounted) return;
    setState(() => connectionStatus = state.status);

    if (state.connected) {
      final shouldReconcile =
          _hasConnectedOnce && _needsReconnectReconciliation;
      _hasConnectedOnce = true;
      _needsReconnectReconciliation = false;

      // Socket.IO may miss events while disconnected. PostgreSQL/REST is the
      // recovery source of truth, while the first connection uses the initial
      // page load already in progress.
      if (shouldReconcile) await refreshAll(silent: true);
    }
  }

  Future<void> _handleRealtimeEvent(RealtimeEvent event) async {
    if (!mounted) return;

    if (event.name == 'socket.invalidated') {
      showToast(event.payload['message']?.toString() ??
          'Your realtime session was invalidated. Please sign in again.');
      await logout();
      return;
    }

    if (event.name == 'responder.location.start') {
      final requestId = _asEventInt(event.payload['requestId']);
      final responderId = _asEventInt(event.payload['responderId']);
      if (requestId != null && responderId != null) {
        locationStore.beginRemoteSharing(
          requestId: requestId,
          responderId: responderId,
        );
      }
      return;
    }

    if (event.name == 'responder.location.update') {
      final requestId = _asEventInt(event.payload['requestId']);
      final responderId = _asEventInt(event.payload['responderId']);
      if (requestId != null && responderId != null) {
        locationStore.applyUpdate(
          LiveResponderLocation.fromJson(event.payload),
        );
      }
      return;
    }

    if (event.name == 'responder.location.stop') {
      final requestId = _asEventInt(event.payload['requestId']);
      if (requestId == locationStore.localSharingRequestId) {
        await _stopLocalLocationSharing(requestId, emitStop: false);
      }
      if (requestId != null) locationStore.stopSharing(requestId);
      return;
    }

    if (event.name == 'socket.error') {
      // REST remains usable. Socket authorization/rate errors never replace
      // the database-backed board with a client-side lifecycle state.
      return;
    }

    if (event.name == 'request.created' || event.name == 'request.updated') {
      final rawRequest = event.payload['request'];
      if (rawRequest is Map) {
        final request = EmergencyRequest.fromJson(
          Map<String, dynamic>.from(rawRequest),
        );
        await _applyRealtimeRequest(request);
      } else {
        // Unassigned responders receive a deliberately redacted invalidation
        // when a pending request becomes unavailable. It contains no request
        // snapshot and is only used to remove that pending card.
        final requestId = _asEventInt(event.payload['requestId']);
        if (isResponder && requestId != null && mounted) {
          setState(() {
            pendingCompatible.removeWhere((request) => request.id == requestId);
          });
        }
      }
      return;
    }

    if (event.name == 'allocation.updated') {
      _applyRealtimeAllocation(event.payload);
      // Inventory quantities are not part of the allocation event. Reload only
      // that small responder dataset; request.updated carries the fresh request.
      if (isResponder) await loadMyInventory(silent: true);
      return;
    }

    if (event.name == 'responder.availability') {
      final responderId = _asEventInt(event.payload['responderId']);
      final status = event.payload['responderStatus']?.toString();
      final timestamp =
          DateTime.tryParse(event.payload['timestamp']?.toString() ?? '');
      if (responderId == null || status == null || !mounted) return;

      setState(() {
        final index = responders.indexWhere((row) => row.id == responderId);
        if (index >= 0) {
          responders[index] =
              responders[index].withStatus(status, updatedAt: timestamp);
        }
      });
    }
  }

  Future<void> _applyRealtimeRequest(EmergencyRequest request) async {
    final isTerminal = !request.isOpen;
    if (isTerminal && request.id == locationStore.localSharingRequestId) {
      await _stopLocalLocationSharing(request.id, emitStop: false);
    }
    if (!mounted) return;

    setState(() {
      openRequests.removeWhere((row) => row.id == request.id);
      pendingCompatible.removeWhere((row) => row.id == request.id);
      logEntries.removeWhere((row) => row.id == request.id);

      if (isResponder) {
        if (request.isOpen &&
            request.acceptedBy?.id == ApiService.currentUserId) {
          openRequests.add(request);
        } else if (request.status == RequestStatus.pending) {
          // request.created is sent only to compatible responders.
          pendingCompatible.add(request);
        } else if (!request.isOpen &&
            request.acceptedBy?.id == ApiService.currentUserId) {
          logEntries.add(request);
        }
      } else if (request.isOpen) {
        openRequests.add(request);
      } else {
        logEntries.add(request);
      }

      openRequests.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      pendingCompatible.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      logEntries.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    });

    if (isTerminal) {
      locationStore.removeRequest(request.id);
    } else {
      locationStore.reconcile(openRequests);
    }
    _syncRequestSubscriptions();
  }

  void _applyRealtimeAllocation(Map<String, dynamic> payload) {
    final rawAllocation = payload['allocation'];
    if (rawAllocation is! Map || !mounted) return;
    final allocation = AllocationLine.fromJson(
      Map<String, dynamic>.from(rawAllocation),
    );
    final backendRequestStatus = payload['requestStatus']?.toString();

    EmergencyRequest patch(EmergencyRequest request) => request.withAllocation(
          allocation,
          backendRequestStatus: backendRequestStatus,
        );

    setState(() {
      _replaceRequestIn(openRequests, allocation.requestId, patch);
      _replaceRequestIn(pendingCompatible, allocation.requestId, patch);
      _replaceRequestIn(logEntries, allocation.requestId, patch);
    });
  }

  void _replaceRequestIn(
    List<EmergencyRequest> requests,
    int requestId,
    EmergencyRequest Function(EmergencyRequest request) update,
  ) {
    final index = requests.indexWhere((request) => request.id == requestId);
    if (index >= 0) requests[index] = update(requests[index]);
  }

  void _syncRequestSubscriptions() {
    final authorizedOpenIds = openRequests
        .where((request) =>
            isAdmin ||
            isRequester ||
            (isResponder && request.acceptedBy?.id == ApiService.currentUserId))
        .map((request) => request.id)
        .toSet();

    for (final requestId
        in _subscribedRequestIds.difference(authorizedOpenIds).toList()) {
      SocketService.instance.unsubscribeFromRequest(requestId);
      _subscribedRequestIds.remove(requestId);
    }
    for (final requestId
        in authorizedOpenIds.difference(_subscribedRequestIds).toList()) {
      SocketService.instance.subscribeToRequest(requestId);
      _subscribedRequestIds.add(requestId);
    }
  }

  int? _asEventInt(dynamic value) {
    final number = value is num ? value.toInt() : int.tryParse('$value');
    return number != null && number > 0 ? number : null;
  }

  // -------------------------------------------------------------------
  // LOADING
  // -------------------------------------------------------------------

  Future<void> refreshAll({bool silent = false}) async {
    if (!mounted) return;

    // Polling remains the offline data path. Once Socket.IO has exhausted a
    // reconnect cycle, the next regular/manual REST refresh also starts a new
    // best-effort realtime reconnect cycle.
    if (!SocketService.instance.isConnected &&
        connectionStatus == RealtimeConnectionStatus.offline) {
      SocketService.instance.connect();
    }

    if (!silent) setState(() => loading = true);

    await loadResources(silent: silent);
    await loadRequests(silent: silent);
    await loadResponders(silent: silent);

    if (isResponder) {
      await loadMyInventory(silent: silent);
    }

    if (!mounted) return;
    if (!silent) setState(() => loading = false);
  }

  Future<void> loadResources({bool silent = false}) async {
    try {
      final data = await ApiService.getResources(includeInactive: isAdmin);

      var loaded = data
          .map((item) =>
              BackendResource.fromJson(Map<String, dynamic>.from(item as Map)))
          .toList();

      // Merge in live availability ("N responders available" for SERVICE,
      // real inventory for CONSUMABLE) so the requester form never has to
      // guess or hardcode a count. Best-effort: if this call fails the
      // catalog still loads with its own (already correct for CONSUMABLE)
      // numbers.
      try {
        final availabilityData = await ApiService.getResourceAvailability();
        final availabilityRows = availabilityData
            .map((item) => ResourceAvailability.fromJson(
                Map<String, dynamic>.from(item as Map)))
            .toList();
        final availabilityById = <int, ResourceAvailability>{
          for (final row in availabilityRows) row.id: row,
        };
        loaded = loaded
            .map((resource) =>
                resource.withAvailability(availabilityById[resource.id]))
            .toList();
      } catch (_) {
        // Non-fatal: fall back to the plain catalog numbers.
      }

      if (!mounted) return;

      setState(() {
        resources
          ..clear()
          ..addAll(loaded);
      });
    } catch (error) {
      if (!silent) showToast('Failed to load resources: ${_clean(error)}');
    }
  }

  Future<void> loadRequests({bool silent = false}) async {
    try {
      final open = <EmergencyRequest>[];
      final pending = <EmergencyRequest>[];
      final closed = <EmergencyRequest>[];

      if (isResponder) {
        final assigned = _parseRequests(await ApiService.getAssignedRequests());
        final compatible =
            _parseRequests(await ApiService.getCompatibleRequests());

        for (final request in assigned) {
          if (request.isOpen) {
            open.add(request);
          } else {
            closed.add(request);
          }
        }

        pending.addAll(compatible);
      } else {
        final all = isAdmin
            ? _parseRequests(await ApiService.getAdminRequests())
            : _parseRequests(await ApiService.getMyRequests());

        for (final request in all) {
          if (request.isOpen) {
            open.add(request);
          } else {
            closed.add(request);
          }
        }
      }

      open.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      closed.sort((a, b) => b.createdAt.compareTo(a.createdAt));

      if (!mounted) return;

      setState(() {
        openRequests
          ..clear()
          ..addAll(open);

        pendingCompatible
          ..clear()
          ..addAll(pending);

        logEntries
          ..clear()
          ..addAll(closed);
      });

      // REST supplies the latest throttled PostgreSQL coordinate. A currently
      // live socket point wins; closed requests are removed from tracking.
      locationStore.reconcile(open);
      _syncRequestSubscriptions();
    } catch (error) {
      if (!silent) showToast('Failed to load requests: ${_clean(error)}');
    }
  }

  Future<void> loadResponders({bool silent = false}) async {
    try {
      final data = await ApiService.getResponders();

      final loaded = data
          .map((item) =>
              BackendResponder.fromJson(Map<String, dynamic>.from(item as Map)))
          .toList();

      if (!mounted) return;

      setState(() {
        responders
          ..clear()
          ..addAll(loaded);
      });
    } catch (error) {
      if (!silent) showToast('Failed to load responders: ${_clean(error)}');
    }
  }

  Future<void> loadMyInventory({bool silent = false}) async {
    try {
      final data = await ApiService.getResponderResources();

      final loaded = data
          .map((item) => BackendResponderResource.fromJson(
              Map<String, dynamic>.from(item as Map)))
          .toList();

      if (!mounted) return;

      setState(() {
        myInventory
          ..clear()
          ..addAll(loaded);
      });
    } catch (error) {
      if (!silent) {
        showToast('Failed to load your inventory: ${_clean(error)}');
      }
    }
  }

  List<EmergencyRequest> _parseRequests(List<dynamic> data) {
    return data
        .map((item) =>
            EmergencyRequest.fromJson(Map<String, dynamic>.from(item as Map)))
        .toList();
  }

  /// Same GPS read, exposed to the requester form as a plain GeoPoint so the
  /// form never depends on the geolocator plugin types.
  Future<GeoPoint?> _tryReadEmergencyGeoPoint() async {
    final position = await _tryReadEmergencyPosition();
    if (position == null) return null;
    return GeoPoint(position.latitude, position.longitude);
  }

  Future<Position?> _tryReadEmergencyPosition() async {
    if (!isRequester) return null;

    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }

      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      ).timeout(const Duration(seconds: 5));
    } catch (_) {
      // A requester can still create an emergency with a real text location if
      // the browser/device does not provide GPS. No client-side coordinate is
      // fabricated as a substitute.
      return null;
    }
  }

  // -------------------------------------------------------------------
  // MUTATIONS - each one reloads the data it touched
  // -------------------------------------------------------------------

  Future<bool> submitRequest(NewRequestPayload payload) async {
    setState(() => submitting = true);

    try {
      // The coordinates resolved in the form (GPS, selected Google place or
      // tapped map point) are the single source of truth. No silent GPS read
      // is performed here, so a typed-only place never gains coordinates it
      // was not actually verified against.
      final latitude = payload.latitude;
      final longitude = payload.longitude;

      await ApiService.createRequest(
        emergencyType: payload.emergencyType,
        description: payload.description,
        location: payload.location,
        priority: payload.priority,
        latitude: latitude,
        longitude: longitude,
        requiredResources: payload.requiredResources,
      );

      showToast(latitude == null || longitude == null
          ? 'Emergency request created with a text-only location. Precise map pin unavailable.'
          : 'Emergency request created with precise GPS coordinates.');

      await loadRequests();
      await loadResources();

      if (!mounted) return true;

      setState(() {
        submitting = false;
        activeView = ConsoleView.board;
      });

      return true;
    } catch (error) {
      if (mounted) setState(() => submitting = false);
      showToast('Request failed: ${_clean(error)}');
      return false;
    }
  }

  Future<void> acceptRequest(EmergencyRequest request) async {
    try {
      await ApiService.acceptEmergencyRequest(request.id);
      showToast('${request.displayId} accepted');
    } catch (error) {
      showToast('Accept failed: ${_clean(error)}');
    }

    await loadRequests();
    await loadResponders();
    await loadMyInventory();
  }

  Future<void> cancelRequest(EmergencyRequest request) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Cancel request'),
        content: Text(
          'Cancel ${request.displayId}? Reserved or dispatched resources will be released, while delivered resources remain delivered.',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.red),
            child: const Text('Cancel request'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await ApiService.cancelMyRequest(request.id);
      showToast('${request.displayId} cancelled');
    } catch (error) {
      showToast('Cancel failed: ${_clean(error)}');
    }

    await loadRequests();
    await loadResources();
  }

  Future<bool> allocateResource({
    required int requestId,
    required int resourceId,
    required int responderResourceId,
    required int quantity,
  }) async {
    var success = false;

    try {
      await ApiService.createAllocation(
        requestId: requestId,
        responderResourceId: responderResourceId,
        resourceId: resourceId,
        quantity: quantity,
      );

      success = true;
      showToast('Allocated $quantity unit(s)');
    } catch (error) {
      showToast('Allocation failed: ${_clean(error)}');
    }

    await loadRequests();
    await loadMyInventory();
    await loadResources();

    return success;
  }

  Future<bool> cancelAllocation(int allocationId) async {
    var success = false;

    try {
      await ApiService.updateAllocationStatus(
        allocationId: allocationId,
        status: 'CANCELLED',
      );

      success = true;
      showToast('Allocation cancelled');
    } catch (error) {
      showToast('Cancel failed: ${_clean(error)}');
    }

    await loadRequests();
    await loadMyInventory();
    await loadResources();
    await loadResponders();

    return success;
  }

  Future<void> dispatchAllocation(AllocationLine allocation) async {
    try {
      await ApiService.updateAllocationStatus(
        allocationId: allocation.id,
        status: 'DISPATCHED',
      );
      showToast('${allocation.resourceName} dispatched');
    } catch (error) {
      showToast('Dispatch failed: ${_clean(error)}');
    }

    await loadRequests();
    await loadMyInventory();
    await loadResponders();
  }

  /// Responder-side delivery fallback. The requester's "Confirm received"
  /// remains the primary flow, but if they never confirm, the responder can
  /// complete DISPATCHED → DELIVERED themselves. The backend recomputes
  /// availability through the lifecycle service - nothing is forced here.
  Future<void> markAllocationDelivered(AllocationLine allocation) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Mark delivered'),
        content: Text(
          'Mark this resource as delivered?\n\n'
          '${allocation.resourceName} × ${allocation.quantity} will be '
          'marked as delivered and this allocation will be completed.',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Not yet'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.teal),
            child: const Text('Mark Delivered'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await ApiService.updateAllocationStatus(
        allocationId: allocation.id,
        status: 'DELIVERED',
      );
      showToast('${allocation.resourceName} marked as delivered');
    } catch (error) {
      showToast('Delivery failed: ${_clean(error)}');
    }

    await loadRequests();
    await loadMyInventory();
    await loadResponders();
  }

  Future<void> confirmReceipt(AllocationLine allocation) async {
    try {
      await ApiService.confirmAllocationReceived(allocation.id);
      showToast('Resource receipt confirmed');
    } catch (error) {
      showToast('Receipt confirmation failed: ${_clean(error)}');
    }

    await loadRequests();
    await loadResponders();
  }

  Future<void> startLocationSharing(EmergencyRequest request) async {
    if (!isResponder || request.acceptedBy?.id != ApiService.currentUserId) {
      showToast('Only the assigned responder can share this emergency location.');
      return;
    }
    if (connectionStatus != RealtimeConnectionStatus.connected ||
        !SocketService.instance.isConnected) {
      showToast('Live location requires a connected realtime service.');
      return;
    }

    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        throw Exception('Location services are disabled on this device.');
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw Exception('Location permission was not granted.');
      }

      await stopLocationSharing(locationStore.localSharingRequestId);
      final authorized =
          await SocketService.instance.startLocationSharing(request.id);
      if (!authorized) {
        throw Exception('Location sharing was not authorized for this request.');
      }
      locationStore.beginLocalSharing(request.id);

      try {
        final initialPosition = await Geolocator.getCurrentPosition(
          locationSettings:
              const LocationSettings(accuracy: LocationAccuracy.high),
        ).timeout(const Duration(seconds: 5));
        SocketService.instance.updateLocation(
          requestId: request.id,
          latitude: initialPosition.latitude,
          longitude: initialPosition.longitude,
        );
      } catch (_) {
        // The stream below may still provide a fix; do not fabricate one.
      }

      const settings = LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      );
      locationSubscription = Geolocator.getPositionStream(
        locationSettings: settings,
      ).listen(
        (position) {
          final requestId = locationStore.localSharingRequestId;
          if (requestId == null || !SocketService.instance.isConnected) return;
          SocketService.instance.updateLocation(
            requestId: requestId,
            latitude: position.latitude,
            longitude: position.longitude,
          );
        },
        onError: (Object _) {
          unawaited(stopLocationSharing(request.id));
        },
      );
      showToast('Live responder location sharing started');
    } catch (error) {
      if (locationStore.localSharingRequestId == request.id) {
        await stopLocationSharing(request.id);
      }
      showToast('Location sharing failed: ${_clean(error)}');
    }
  }

  Future<void> _stopLocalLocationSharing(
    int? requestId, {
    bool emitStop = false,
  }) async {
    await locationSubscription?.cancel();
    locationSubscription = null;
    final activeRequestId = requestId ?? locationStore.localSharingRequestId;
    if (activeRequestId == null) return;
    locationStore.endLocalSharing(activeRequestId);
    if (emitStop && SocketService.instance.isConnected) {
      SocketService.instance.stopLocationSharing(activeRequestId);
    }
  }

  Future<void> stopLocationSharing(int? requestId) async {
    await _stopLocalLocationSharing(requestId, emitStop: true);
  }

  Future<void> editMyHelpTypes() async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(builder: (_) => const ResponderReadinessPage()),
    );
    if (mounted) await refreshAll(silent: true);
  }

  Future<void> saveResource(BackendResource? existing) async {
    final data = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => ResourceEditorDialog(resource: existing),
    );

    if (data == null) return;

    try {
      if (existing == null) {
        await ApiService.createResource(data);
        showToast('Resource created');
      } else {
        await ApiService.updateResource(existing.id, data);
        showToast('Resource updated');
      }
    } catch (error) {
      showToast('Save failed: ${_clean(error)}');
    }

    await loadResources();
  }

  Future<void> toggleResourceActive(
    BackendResource resource,
    bool isActive,
  ) async {
    try {
      await ApiService.setResourceActive(resource.id, isActive);
      showToast(isActive
          ? '${resource.name} restored'
          : '${resource.name} deactivated');
    } catch (error) {
      showToast('Update failed: ${_clean(error)}');
    }

    await loadResources();
  }

  void openAllocationDialog(EmergencyRequest request) {
    showDialog<void>(
      context: context,
      builder: (context) => AllocationDialog(
        requestId: request.id,
        requestProvider: findRequest,
        inventoryProvider: () => myInventory,
        onAllocate: allocateResource,
        onCancelAllocation: cancelAllocation,
        onDispatchAllocation: dispatchAllocation,
        onMarkDelivered: markAllocationDelivered,
      ),
    );
  }

  EmergencyRequest? findRequest(int id) {
    return firstWhereOrNull(openRequests, (r) => r.id == id) ??
        firstWhereOrNull(pendingCompatible, (r) => r.id == id);
  }

  Future<void> logout() async {
    await stopLocationSharing(locationStore.localSharingRequestId);
    SocketService.instance.disconnect();
    await ApiService.logout();
    if (!mounted) return;

    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(builder: (_) => const LoginScreen()),
    );
  }

  // -------------------------------------------------------------------
  // HELPERS
  // -------------------------------------------------------------------

  String _clean(Object error) =>
      error.toString().replaceFirst('Exception: ', '');

  void showToast(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message,
            style: const TextStyle(color: AppColors.text, fontSize: 13)),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(milliseconds: 3600),
        backgroundColor: AppColors.surface2,
        elevation: 2,
        shape: const Border(left: BorderSide(color: AppColors.teal, width: 4)),
      ),
    );
  }

  String get clockLabel {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
  }

  int get pendingCount => isResponder
      ? pendingCompatible.length
      : openRequests.where((r) => r.status == RequestStatus.pending).length;

  int get activeCount =>
      openRequests.where((r) => r.status != RequestStatus.pending).length;

  int get closedCount => logEntries.length;

  BackendResponder? get currentResponder => firstWhereOrNull(
        responders,
        (responder) => responder.id == ApiService.currentUserId,
      );

  int get unfinishedAllocationCount {
    final requests = <EmergencyRequest>[...openRequests, ...logEntries];
    return requests
        .expand((request) => request.allocations)
        .where((allocation) =>
            allocation.responderId == ApiService.currentUserId &&
            (allocation.status == 'RESERVED' ||
                allocation.status == 'DISPATCHED'))
        .length;
  }

  String get viewTitle => switch (activeView) {
        ConsoleView.board => 'Dispatch Board',
        ConsoleView.newRequest => 'New Request',
        ConsoleView.resources => 'Resources',
        ConsoleView.responders => 'Responders',
        ConsoleView.log => 'Closed Log',
      };

  String get viewSubtitle => switch (activeView) {
        ConsoleView.board => 'Live request state from PostgreSQL',
        ConsoleView.newRequest => 'Request any active resource in the catalog',
        ConsoleView.resources => 'Resource catalog and inventory',
        ConsoleView.responders => 'Responders registered in the database',
        ConsoleView.log => 'Completed and cancelled requests',
      };

  String get roleLabel {
    final name = ApiService.currentUserName;
    final roleText = role ?? 'GUEST';
    return name == null ? roleText : '$name · $roleText';
  }

  void setView(ConsoleView view) => setState(() => activeView = view);

  // -------------------------------------------------------------------
  // BUILD
  // -------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final isMobile = width < 720;
    final items = navItemsForRole(role);

    if (!items.any((item) => item.view == activeView)) {
      activeView = items.first.view;
    }

    if (isMobile) {
      return Scaffold(
        backgroundColor: AppColors.bg,
        appBar: MobileAppBar(
          clock: clockLabel,
          pending: pendingCount,
          active: activeCount,
          completed: closedCount,
          title: viewTitle,
          onRefresh: refreshAll,
          onLogout: logout,
          connectionStatus: connectionStatus,
        ),
        body: SafeArea(
          top: false,
          child: RefreshIndicator(
            onRefresh: refreshAll,
            child: _buildMainContent(isMobile: true),
          ),
        ),
        bottomNavigationBar: BottomNav(
          items: items,
          activeView: activeView,
          onViewChanged: setView,
        ),
      );
    }

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Rail(
              items: items,
              activeView: activeView,
              onViewChanged: setView,
              clock: clockLabel,
              roleLabel: roleLabel,
              onRefresh: refreshAll,
              onLogout: logout,
            ),
            Expanded(
              child: Column(
                children: [
                  DesktopTopBar(
                    title: viewTitle,
                    subtitle: viewSubtitle,
                    pending: pendingCount,
                    active: activeCount,
                    completed: closedCount,
                    loading: loading,
                    connectionStatus: connectionStatus,
                  ),
                  Expanded(child: _buildMainContent(isMobile: false)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMainContent({required bool isMobile}) {
    final children = <Widget>[];

    if (activeView == ConsoleView.board) {
      children.addAll(_boardChildren(isMobile));
    }

    if (activeView == ConsoleView.newRequest && isRequester) {
      children.add(
        NewRequestPanel(
          resources: resources,
          submitting: submitting,
          onSubmit: submitRequest,
          onReload: loadResources,
          onUseCurrentLocation: _tryReadEmergencyGeoPoint,
        ),
      );
    }

    if (activeView == ConsoleView.resources) {
      children.add(
        ResourceCatalogPanel(
          resources: resources,
          isAdmin: isAdmin,
          isMobile: isMobile,
          onCreate: isAdmin ? () => saveResource(null) : null,
          onEdit: isAdmin ? (resource) => saveResource(resource) : null,
          onToggleActive: isAdmin ? toggleResourceActive : null,
        ),
      );

      if (isResponder) {
        children.add(const SizedBox(height: 18));
        children.add(
          ResponderResourcesPanel(
            resources: myInventory,
            title: 'MY HELP TYPES',
            onEditHelpTypes: editMyHelpTypes,
          ),
        );
      }
    }

    if (activeView == ConsoleView.responders) {
      children.add(
        BackendRespondersPanel(responders: responders, isMobile: isMobile),
      );
    }

    if (activeView == ConsoleView.log) {
      children.add(LogPanel(logEntries: logEntries, isMobile: isMobile));
    }

    return ListView(
      // Content-driven scrolling area with compact outer padding. The extra
      // bottom space on mobile only clears the floating bottom navigation bar.
      padding: EdgeInsets.fromLTRB(
        isMobile ? 12 : 24,
        isMobile ? 12 : 18,
        isMobile ? 12 : 24,
        isMobile ? 84 : 28,
      ),
      children: children,
    );
  }

  List<Widget> _boardChildren(bool isMobile) {
    final children = <Widget>[];

    if (isResponder) {
      children.add(
        ResponderAvailabilityBanner(
          responder: currentResponder,
          unfinishedAllocations: unfinishedAllocationCount,
        ),
      );
      children.add(
        AnimatedBuilder(
          animation: locationStore,
          builder: (context, _) => BoardPanel(
            title: 'MY ACTIVE EMERGENCY',
            hint: 'Accepted by you',
            requests: openRequests,
            role: role,
            currentUserId: ApiService.currentUserId,
            emptyTitle: 'NO ACTIVE EMERGENCY',
            emptyIcon: Icons.check_circle_outline,
            emptyMessage:
                'Accept a compatible request below to start working on it.',
            onAllocate: openAllocationDialog,
            onDispatchAllocation: dispatchAllocation,
            onMarkDelivered: markAllocationDelivered,
            onStartLocationSharing: startLocationSharing,
            onStopLocationSharing: stopLocationSharing,
            liveLocations: locationStore.locations,
            activelySharingRequestIds:
                locationStore.activelySharingRequestIds,
            sharingRequestId: locationStore.localSharingRequestId,
            connectionStatus: connectionStatus,
            isMobile: isMobile,
          ),
        ),
      );

      children.add(const SizedBox(height: 18));
      children.add(
        BoardPanel(
          title: 'COMPATIBLE PENDING REQUESTS',
          hint: 'Matched against your available inventory',
          requests: pendingCompatible,
          role: role,
          currentUserId: ApiService.currentUserId,
          emptyTitle: 'NO COMPATIBLE REQUESTS',
          emptyIcon: Icons.inbox_outlined,
          emptyMessage:
              'New pending requests will appear here when your available '
              'inventory matches every required resource.',
          onAccept: acceptRequest,
          connectionStatus: connectionStatus,
          isMobile: isMobile,
        ),
      );
    } else {
      children.add(
        AnimatedBuilder(
          animation: locationStore,
          builder: (context, _) => BoardPanel(
            title: isAdmin ? 'ALL ACTIVE REQUESTS' : 'MY ACTIVE REQUESTS',
            hint: 'Sorted by time received',
            requests: openRequests,
            role: role,
            currentUserId: ApiService.currentUserId,
            emptyMessage: isRequester
                ? 'No active requests. Submit one from "New".'
                : 'No active requests in the database.',
            onCancelRequest: isRequester ? cancelRequest : null,
            onConfirmReceipt: isRequester ? confirmReceipt : null,
            liveLocations: locationStore.locations,
            activelySharingRequestIds:
                locationStore.activelySharingRequestIds,
            connectionStatus: connectionStatus,
            isMobile: isMobile,
          ),
        ),
      );
    }

    children.add(const SizedBox(height: 18));
    children.add(
      AnimatedBuilder(
        animation: locationStore,
        builder: (context, _) => Panel(
          title: 'GOOGLE MAP',
          trailing: ConnectionStatusIndicator(
            status: connectionStatus,
            compact: true,
          ),
          child: OperationalGoogleMap(
            requests: [...openRequests, ...pendingCompatible],
            liveLocations: locationStore.locations,
            isMobile: isMobile,
          ),
        ),
      ),
    );

    return children;
  }
}
