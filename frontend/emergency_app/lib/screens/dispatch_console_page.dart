import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../Services/api_service.dart';
import '../Services/socket_service.dart';
import '../models/eras_models.dart';
import '../state/live_location_store.dart';
import '../theme/app_theme.dart';
import '../widgets/allocation_dialog.dart';
import '../widgets/board_panel.dart';
import '../widgets/common_widgets.dart';
import '../widgets/connection_status.dart';
import '../widgets/log_panel.dart';
import '../widgets/new_request_panel.dart';
import '../widgets/resource_panels.dart';
import '../widgets/responder_status_panel.dart';
import '../widgets/sector_map.dart';
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
  Timer? inventoryDebounce;
  Timer? compatibleDebounce;
  StreamSubscription<RealtimeEvent>? realtimeEventsSubscription;
  StreamSubscription<SocketConnectionState>? socketStateSubscription;
  StreamSubscription<Position>? locationSubscription;

  /// Request-scoped responder positions (live and last known). Socket.IO
  /// events and REST reconciliation both feed this single store.
  final LiveLocationStore locationStore = LiveLocationStore();

  /// Bumped whenever data that the map draws actually changed, so the painter
  /// repaints on real changes instead of on every frame.
  int mapRevision = 0;

  SocketConnectionState connection = SocketService.instance.state;

  /// Availability exactly as the backend computed it. Never set locally.
  ResponderAvailability? myAvailability;

  int? sharingRequestId;

  /// Set while live sharing is interrupted by a lost realtime connection, so
  /// it can resume automatically once the connection is back.
  int? pausedShareRequestId;

  Map<int, LiveResponderLocation> get liveLocations => locationStore.snapshot;

  String? get role => ApiService.currentRole;
  bool get isRequester => role == 'REQUESTER';
  bool get isResponder => role == 'RESPONDER';
  bool get isAdmin => role == 'ADMIN';

  @override
  void initState() {
    super.initState();

    realtimeEventsSubscription =
        SocketService.instance.events.listen(_handleRealtimeEvent);
    socketStateSubscription =
        SocketService.instance.connectionStates.listen(_handleConnectionState);
    SocketService.instance.connect();
    refreshAll();

    clockTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) {
        if (!mounted) return;
        final current = DateTime.now();
        // A live point that stopped arriving becomes "last known" instead of
        // pretending the responder is still being tracked.
        if (locationStore.expireStale(current)) mapRevision++;
        setState(() => now = current);
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
      loadMyAvailability(silent: true);
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
    inventoryDebounce?.cancel();
    compatibleDebounce?.cancel();
    realtimeEventsSubscription?.cancel();
    socketStateSubscription?.cancel();
    // GPS must never outlive this page.
    locationSubscription?.cancel();
    locationSubscription = null;
    super.dispose();
  }

  // -------------------------------------------------------------------
  // REALTIME
  // -------------------------------------------------------------------

  /// Connection lifecycle. The REST board keeps working in every state; only
  /// the push channel and the GPS stream react here.
  void _handleConnectionState(SocketConnectionState state) {
    if (!mounted) return;

    final wasDegraded = connection.isDegraded;
    setState(() => connection = state);

    if (state.connected) {
      // Socket.IO can miss events while disconnected. REST is the recovery
      // source of truth before the next push event is consumed.
      refreshAll(silent: true);
      if (isResponder) loadMyAvailability(silent: true);
      if (wasDegraded) _resumePausedLocationSharing();
      return;
    }

    // No push channel: nothing on the map may keep claiming live tracking,
    // and GPS is paused instead of streaming into a dead socket.
    if (locationStore.markAllLastKnown()) {
      mapRevision++;
      setState(() {});
    }
    _pauseLocationSharingForTransport();
  }

  Future<void> _handleRealtimeEvent(RealtimeEvent event) async {
    if (!mounted) return;

    switch (event.name) {
      case 'socket.invalidated':
        showToast(event.payload['message']?.toString() ??
            'Your realtime session was invalidated. Please sign in again.');
        await logout();
        return;

      case 'socket.error':
        // Authorization errors are actionable during development but do not
        // replace the REST board with a client-side error state.
        return;

      case 'responder.location.start':
        // The start event carries no coordinate; the first update does.
        return;

      case 'responder.location.update':
        final location = LiveResponderLocation.fromJson(event.payload);
        if (location.requestId <= 0) return;
        if (locationStore.applyLiveUpdate(location)) {
          mapRevision++;
          if (mounted) setState(() {});
        }
        return;

      case 'responder.location.stop':
        final requestId = _asEventInt(event.payload['requestId']);
        if (requestId == null) return;
        if (requestId == sharingRequestId) {
          await _stopLocalLocationSharing(requestId);
        }
        if (locationStore.markLastKnown(requestId)) mapRevision++;
        if (mounted) setState(() {});
        return;

      case 'responder.availability':
        _applyAvailabilityEvent(event.payload);
        return;

      case 'request.created':
        // Dart switch cases share one scope, so each case uses its own names.
        final createdId = _asEventInt(event.payload['requestId']);
        if (createdId != null) {
          SocketService.instance.subscribeToRequest(createdId);
        }
        final created = _requestFromPayload(event.payload['request']);
        // Responder compatibility is computed by the backend, so a new
        // request still needs one REST read - debounced so a burst of
        // creations does not trigger a burst of reloads.
        if (isResponder || created == null || !_applyRequestSnapshot(created)) {
          _scheduleCompatibleRefresh();
        } else if (mounted) {
          setState(() {});
        }
        return;

      case 'request.updated':
        final updated = _requestFromPayload(event.payload['request']);
        if (updated == null) {
          await loadRequests(silent: true);
          return;
        }

        final applied = _applyRequestSnapshot(updated);
        if (!updated.isOpen && updated.id == sharingRequestId) {
          await _stopLocalLocationSharing(updated.id);
        }
        if (applied && mounted) setState(() {});
        return;

      case 'allocation.updated':
        final patched = _applyAllocationPayload(event.payload);
        // A delivered/cancelled allocation changes responder inventory and
        // catalog availability; those are REST reads, debounced.
        _scheduleInventoryRefresh();
        if (patched && mounted) setState(() {});
        return;

      default:
        return;
    }
  }

  // -------------------------------------------------------------------
  // TARGETED STATE UPDATES
  // -------------------------------------------------------------------

  EmergencyRequest? _requestFromPayload(dynamic value) {
    if (value is! Map) return null;
    final json = Map<String, dynamic>.from(value);
    if (_asEventInt(json['id']) == null) return null;
    return EmergencyRequest.fromJson(json);
  }

  bool _placeRequest(
    List<EmergencyRequest> list,
    EmergencyRequest request, {
    required bool keep,
  }) {
    final index = list.indexWhere((item) => item.id == request.id);

    if (!keep) {
      if (index < 0) return false;
      list.removeAt(index);
      return true;
    }

    if (index >= 0) {
      list[index] = request;
    } else {
      list.add(request);
      list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    }
    return true;
  }

  EmergencyRequest? _knownRequest(int id) =>
      firstWhereOrNull(openRequests, (item) => item.id == id) ??
      firstWhereOrNull(pendingCompatible, (item) => item.id == id) ??
      firstWhereOrNull(logEntries, (item) => item.id == id);

  /// Apply one committed request snapshot to the lists this role owns.
  /// Returns false when the snapshot is not relevant for this user, in which
  /// case nothing is touched and no reload is needed either.
  bool _applyRequestSnapshot(EmergencyRequest snapshot) {
    // Realtime payloads carry a slimmer requester/responder object than REST;
    // merging keeps the contact details already loaded instead of blanking
    // them on every push update.
    final request = snapshot.withDetailsFrom(_knownRequest(snapshot.id));
    final userId = ApiService.currentUserId;
    final isMine = isAdmin ||
        (isRequester && request.requester?.id == userId) ||
        (isResponder && request.acceptedBy?.id == userId);
    final wasPending =
        pendingCompatible.any((item) => item.id == request.id);
    final known = isMine ||
        wasPending ||
        openRequests.any((item) => item.id == request.id) ||
        logEntries.any((item) => item.id == request.id);

    if (!known) return false;

    var changed = false;
    changed |= _placeRequest(openRequests, request, keep: isMine && request.isOpen);
    changed |= _placeRequest(logEntries, request, keep: isMine && !request.isOpen);

    if (isResponder) {
      // A pending request that somebody else accepted (or that closed) simply
      // leaves the compatible list - no reload required.
      final stillOffered = wasPending &&
          request.status == RequestStatus.pending &&
          request.acceptedBy == null;
      changed |= _placeRequest(pendingCompatible, request, keep: stillOffered);
    }

    if (!request.isOpen) {
      if (locationStore.removeForRequest(request.id)) changed = true;
    } else if (locationStore.seedLastKnownFor(request)) {
      changed = true;
    }

    if (changed) mapRevision++;
    return changed;
  }

  bool _applyAllocationPayload(Map<String, dynamic> payload) {
    final allocationJson = payload['allocation'];
    if (allocationJson is! Map) return false;

    final allocation =
        AllocationLine.fromJson(Map<String, dynamic>.from(allocationJson));
    if (allocation.requestId <= 0) return false;

    var changed = false;
    for (final list in <List<EmergencyRequest>>[
      openRequests,
      pendingCompatible,
      logEntries,
    ]) {
      final index =
          list.indexWhere((item) => item.id == allocation.requestId);
      if (index < 0) continue;
      list[index] = list[index].withAllocation(allocation);
      changed = true;
    }

    return changed;
  }

  void _applyAvailabilityEvent(Map<String, dynamic> payload) {
    final responderId = _asEventInt(payload['responderId']);
    if (responderId == null) return;

    final status = payload['responderStatus']?.toString() ??
        payload['currentResponderStatus']?.toString();

    var changed = false;

    // Responder directory entry: a status-only broadcast is enough for this.
    if (status != null) {
      final index =
          responders.indexWhere((responder) => responder.id == responderId);
      if (index >= 0 && responders[index].status != status) {
        final current = responders[index];
        responders[index] = BackendResponder(
          id: current.id,
          name: current.name,
          email: current.email,
          status: status,
          phone: current.phone,
          location: current.location,
          latitude: current.latitude,
          longitude: current.longitude,
          lastActiveAt: current.lastActiveAt,
        );
        changed = true;
      }
    }

    // My own availability card: only the payload that really carries the
    // workload detail may replace the counts.
    if (responderId == ApiService.currentUserId) {
      if (ResponderAvailability.hasWorkloadDetail(payload)) {
        myAvailability = ResponderAvailability.fromJson(payload);
        changed = true;
      } else if (status != null && myAvailability != null) {
        myAvailability = myAvailability!.copyWithStatus(status);
        changed = true;
      } else if (status != null) {
        // No baseline yet: read the authoritative numbers over REST.
        loadMyAvailability(silent: true);
      }
    }

    if (changed && mounted) setState(() {});
  }

  void _scheduleInventoryRefresh() {
    if (!isResponder) return;
    inventoryDebounce?.cancel();
    inventoryDebounce = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      loadMyInventory(silent: true);
      loadResources(silent: true);
      loadMyAvailability(silent: true);
    });
  }

  void _scheduleCompatibleRefresh() {
    compatibleDebounce?.cancel();
    compatibleDebounce = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      loadRequests(silent: true);
    });
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

    if (!silent) setState(() => loading = true);

    await loadResources(silent: silent);
    await loadRequests(silent: silent);
    await loadResponders(silent: silent);

    if (isResponder) {
      await loadMyInventory(silent: silent);
      await loadMyAvailability(silent: true);
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

        // The REST resynchronization also carries the latest throttled
        // PostgreSQL coordinate. Socket.IO then replaces it with live GPS
        // updates when sharing is active - a live point is never downgraded
        // by this reconciliation.
        locationStore.syncWithOpenRequests(open);
        mapRevision++;
      });

      // Room authorization is checked again by the backend. Pending responder
      // requests are not subscribed until acceptance, while requester/admin
      // rooms are safe to subscribe for their own/current views.
      for (final request in <EmergencyRequest>[...open, ...closed]) {
        SocketService.instance.subscribeToRequest(request.id);
      }
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
        mapRevision++;
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

  /// Availability is read, never written, by the app: the backend recomputes
  /// it from persisted work (lifecycle service) and this is the read model.
  Future<void> loadMyAvailability({bool silent = false}) async {
    if (!isResponder) return;

    try {
      final data = await ApiService.getMyResponderAvailability();
      if (!mounted || data.isEmpty) return;

      setState(() {
        myAvailability = ResponderAvailability.fromJson(data);
      });
    } catch (error) {
      if (!silent) {
        showToast('Failed to load your availability: ${_clean(error)}');
      }
    }
  }

  List<EmergencyRequest> _parseRequests(List<dynamic> data) {
    return data
        .map((item) =>
            EmergencyRequest.fromJson(Map<String, dynamic>.from(item as Map)))
        .toList();
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

      return Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      ).timeout(const Duration(seconds: 5));
    } catch (_) {
      // A requester can still create an emergency with the selected sector if
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
      final emergencyPosition = await _tryReadEmergencyPosition();
      await ApiService.createRequest(
        emergencyType: payload.emergencyType,
        description: payload.description,
        location: payload.location,
        priority: payload.priority,
        latitude: emergencyPosition?.latitude,
        longitude: emergencyPosition?.longitude,
        requiredResources: payload.requiredResources,
      );

      showToast('Emergency request created');

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

      await stopLocationSharing(sharingRequestId);
      if (!mounted) return;
      setState(() {
        sharingRequestId = request.id;
        pausedShareRequestId = null;
      });
      SocketService.instance.startLocationSharing(request.id);

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

      final settings = const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      );
      locationSubscription = Geolocator.getPositionStream(
        locationSettings: settings,
      ).listen((position) {
        final requestId = sharingRequestId;
        if (requestId == null) return;
        SocketService.instance.updateLocation(
          requestId: requestId,
          latitude: position.latitude,
          longitude: position.longitude,
        );
      });
      showToast('Live responder location sharing started');
    } catch (error) {
      if (sharingRequestId == request.id) await stopLocationSharing(request.id);
      showToast('Location sharing failed: ${_clean(error)}');
    }
  }

  /// Cancel the GPS stream locally. Used for completion, cancellation,
  /// logout, dispose and transport loss: the device never keeps streaming
  /// positions that nothing is listening to.
  Future<void> _stopLocalLocationSharing(int? requestId) async {
    await locationSubscription?.cancel();
    locationSubscription = null;
    final activeRequestId = requestId ?? sharingRequestId;
    if (activeRequestId == sharingRequestId) {
      sharingRequestId = null;
      pausedShareRequestId = null;
      if (mounted) setState(() {});
    }
  }

  Future<void> stopLocationSharing(int? requestId) async {
    final activeRequestId = requestId ?? sharingRequestId;
    await _stopLocalLocationSharing(activeRequestId);
    if (activeRequestId != null) {
      SocketService.instance.stopLocationSharing(activeRequestId);
      if (locationStore.markLastKnown(activeRequestId)) {
        mapRevision++;
        if (mounted) setState(() {});
      }
    }
  }

  /// The realtime transport went away while sharing was active. GPS is
  /// stopped (no point streaming into a dead socket) but the intent is
  /// remembered so it can resume on reconnect.
  void _pauseLocationSharingForTransport() {
    final activeRequestId = sharingRequestId;
    if (activeRequestId == null) return;

    locationSubscription?.cancel();
    locationSubscription = null;
    if (!mounted) return;
    setState(() => pausedShareRequestId = activeRequestId);
  }

  Future<void> _resumePausedLocationSharing() async {
    final requestId = pausedShareRequestId ?? sharingRequestId;
    if (requestId == null) return;

    final request = firstWhereOrNull(openRequests, (r) => r.id == requestId);
    // Only resume for an emergency that is still open and still assigned to
    // this responder; the backend would reject anything else anyway.
    if (request == null ||
        !request.isOpen ||
        request.acceptedBy?.id != ApiService.currentUserId) {
      await _stopLocalLocationSharing(requestId);
      return;
    }

    pausedShareRequestId = null;
    await startLocationSharing(request);
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
    // Order matters: stop GPS first, then drop the socket, then the session.
    await stopLocationSharing(sharingRequestId);
    inventoryDebounce?.cancel();
    compatibleDebounce?.cancel();
    locationStore.clear();
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
          statusIndicator:
              ConnectionStatusPill(state: connection, compact: true),
          clock: clockLabel,
          pending: pendingCount,
          active: activeCount,
          completed: closedCount,
          title: viewTitle,
          onRefresh: refreshAll,
          onLogout: logout,
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
                    statusIndicator: ConnectionStatusPill(state: connection),
                    title: viewTitle,
                    subtitle: viewSubtitle,
                    pending: pendingCount,
                    active: activeCount,
                    completed: closedCount,
                    loading: loading,
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

    // Degraded realtime is stated once, at the top, and the REST board below
    // keeps working exactly as before.
    children.add(
      ConnectionNotice(
        state: connection,
        onRetry: () => refreshAll(silent: false),
      ),
    );

    if (activeView == ConsoleView.board) {
      children.addAll(_boardChildren(isMobile));
    }

    if (activeView == ConsoleView.newRequest && isRequester) {
      children.add(
        NewRequestPanel(
          resources: resources,
          locations: kDistricts.map((d) => d.name).toList(),
          submitting: submitting,
          onSubmit: submitRequest,
          onReload: loadResources,
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
        ResponderAvailabilityCard(
          availability: myAvailability,
          connection: connection,
        ),
      );

      children.add(const SizedBox(height: 18));

      children.add(
        BoardPanel(
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
          liveLocations: liveLocations,
          isMobile: isMobile,
          detailed: true,
        ),
      );

      children.add(const SizedBox(height: 18));

      children.add(
        LocationSharingPanel(
          requests: openRequests,
          currentUserId: ApiService.currentUserId,
          sharingRequestId: sharingRequestId,
          liveLocations: liveLocations,
          connection: connection,
          onStart: startLocationSharing,
          onStop: stopLocationSharing,
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
          liveLocations: liveLocations,
          isMobile: isMobile,
        ),
      );
    } else {
      children.add(
        BoardPanel(
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
          liveLocations: liveLocations,
          isMobile: isMobile,
          detailed: isRequester,
        ),
      );
    }

    children.add(const SizedBox(height: 18));

    children.add(
      Panel(
        title: 'SECTOR MAP',
        hint: 'Districts, responders and open requests',
        trailing: ConnectionStatusPill(state: connection, compact: true),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              // Content-driven, but height-capped so the map never pushes the
              // request board far below the fold on wide desktop layouts.
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final maxHeight = isMobile ? 190.0 : 230.0;
                  final ratio = isMobile ? 360 / 200 : 640 / 260;
                  final width = constraints.maxWidth;
                  final height =
                      (width / ratio).clamp(140.0, maxHeight).toDouble();

                  return SizedBox(
                    height: height,
                    width: double.infinity,
                    child: CustomPaint(
                      painter: SectorMapPainter(
                        districts: kDistricts,
                        responders: responders,
                        requests: [...openRequests, ...pendingCompatible],
                        liveLocations: liveLocations,
                        repaintKey: mapRevision + locationStore.revision,
                      ),
                    ),
                  );
                },
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Wrap(
                spacing: 12,
                runSpacing: 6,
                children: [
                  LegendItem(color: AppColors.teal, label: 'Available'),
                  LegendItem(color: AppColors.blue, label: 'Busy / assigned'),
                  LegendItem(color: AppColors.textFaint, label: 'Offline'),
                  LegendItem(color: AppColors.red, label: 'Emergency location'),
                  LegendItem(color: AppColors.amber, label: 'Pending request'),
                  LegendItem(color: AppColors.teal, label: 'Live responder'),
                  LegendItem(
                      color: AppColors.textFaint, label: 'Last known position'),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    return children;
  }
}
