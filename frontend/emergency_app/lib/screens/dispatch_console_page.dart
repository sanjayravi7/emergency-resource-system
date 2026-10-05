import 'dart:async';

import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../services/live_location_store.dart';
import '../services/google_auth_service.dart';
import '../services/push_notification_service.dart';
import '../services/socket_service.dart';
import '../models/eras_models.dart';
import '../services/location_service.dart';
import '../theme/app_theme.dart';
import '../widgets/admin_user_management_panel.dart';
import '../widgets/auth_motion.dart';
import '../widgets/board_panel.dart';
import '../widgets/common_widgets.dart';
import '../widgets/log_panel.dart';
import '../widgets/location_permission_banner.dart';
import '../widgets/new_request_panel.dart';
import '../widgets/operational_google_map.dart';
import '../widgets/operational_status.dart';
import '../widgets/request_detail_dialog.dart';
import '../widgets/responder_assignment_dialog.dart';
import '../widgets/resource_panels.dart';
import 'login_screen.dart';
import 'responder_readiness_page.dart';

/// Single place where the app talks to the backend.
///
/// Every mutation is followed by an explicit reload of the affected data, so
/// the UI always shows what PostgreSQL contains. A push transport (Socket.IO)
/// could later call the very same reload methods.
class DispatchConsolePage extends StatefulWidget {
  const DispatchConsolePage({
    super.key,
    this.readinessSuccess = false,
    this.checkLocationPermission,
    this.requestLocationPermission,
  });

  final bool readinessSuccess;

  /// Testable permission hooks. Production defaults remain the shared
  /// Geolocator-backed service and no coordinates are synthesized here.
  final Future<LocationPermissionResult> Function()? checkLocationPermission;
  final Future<LocationPermissionResult> Function()? requestLocationPermission;

  @override
  State<DispatchConsolePage> createState() => _DispatchConsolePageState();
}

class _DispatchConsolePageState extends State<DispatchConsolePage> {
  final List<BackendResource> resources = <BackendResource>[];
  final List<BackendResponder> responders = <BackendResponder>[];
  final List<AdminUser> adminUsers = <AdminUser>[];
  final Set<int> _adminUserBusyIds = <int>{};
  final List<BackendResponderResource> myInventory =
      <BackendResponderResource>[];
  final List<ResponderHelpType> myHelpTypes = <ResponderHelpType>[];

  /// Open requests relevant to the signed in user.
  final List<EmergencyRequest> openRequests = <EmergencyRequest>[];

  /// PENDING requests a responder is able to serve (compatible list).
  final List<EmergencyRequest> pendingCompatible = <EmergencyRequest>[];

  /// Completed / cancelled requests.
  final List<EmergencyRequest> logEntries = <EmergencyRequest>[];

  ConsoleView activeView = ConsoleView.board;
  bool loading = false;
  bool adminUsersLoading = false;
  bool submitting = false;

  Timer? refreshTimer;
  Timer? heartbeatTimer;
  StreamSubscription<RealtimeEvent>? realtimeEventsSubscription;
  StreamSubscription<SocketConnectionState>? socketStateSubscription;
  StreamSubscription<GeoPoint>? locationSubscription;
  final LiveLocationStore locationStore = LiveLocationStore();
  final Set<int> _subscribedRequestIds = <int>{};
  RealtimeConnectionStatus connectionStatus = RealtimeConnectionStatus.offline;
  bool locationPermissionGranted = false;
  bool _locationPermissionChecked = false;
  bool _locationPermissionRequestInProgress = false;
  bool _locationStartInProgress = false;
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
    // Immediately after login, inspect permission and request it once when the
    // platform reports a normal promptable denial. This never waits on or
    // blocks the dashboard; Google Maps My Location remains disabled until a
    // real grant is returned.
    unawaited(_initializeLocationPermission());
    refreshAll();

    // The rail / app-bar clock is a self-contained [ErasClock] widget, so the
    // console page no longer rebuilds once per second just to tick the timer.

    // Reliable polling refresh. Replaceable by Socket.IO later without
    // touching the widgets.
    refreshTimer = Timer.periodic(
      const Duration(seconds: 20),
      (_) => refreshAll(silent: true),
    );

    if (isResponder) {
      // Register this device for FCM push so backgrounded responders still
      // hear about new compatible emergencies. Purely additive: on failure it
      // disables itself silently and Socket.IO plus GET /api/requests/
      // compatible keep working.
      unawaited(PushNotificationService.instance.startForResponder());
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
        showToast('You are now available for your selected help types.');
      });
    }
  }

  @override
  void dispose() {
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
        final location = LiveResponderLocation.tryFromJson(event.payload);
        if (location != null) locationStore.applyUpdate(location);
      }
      return;
    }

    if (event.name == 'responder.location.stop') {
      final requestId = _asEventInt(event.payload['requestId']);
      final responderId = _asEventInt(event.payload['responderId']);
      if (requestId == locationStore.localSharingRequestId &&
          (responderId == null ||
              responderId == locationStore.localSharingResponderId ||
              responderId == ApiService.currentUserId)) {
        await _stopLocalLocationSharing(requestId, emitStop: false);
      }
      // Multi-responder: only the stopping responder's point becomes
      // last-known; every other responder's stream is untouched.
      if (requestId != null) {
        locationStore.stopSharing(requestId, responderId: responderId);
        // Lifecycle changes update the board controls/labels once. Subsequent
        // GPS points repaint only the map AnimatedBuilder below.
        if (mounted) setState(() {});
      }
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
        // (no request snapshot). Under multi-responder dispatch `available`
        // means "still joinable" (non-terminal + outstanding quantity), so
        // the pending card is only removed when the backend says the request
        // is no longer joinable.
        final requestId = _asEventInt(event.payload['requestId']);
        final stillJoinable = event.payload['available'] == true;
        if (isResponder && requestId != null && !stillJoinable && mounted) {
          setState(() {
            pendingCompatible.removeWhere((request) => request.id == requestId);
          });
        }

        // PHASE F: a redacted update can still be terminal (COMPLETED /
        // CANCELLED). A terminal request keeps NO live or last-known
        // tracking for ANY of its responders, so the whole request is
        // cleared - not just the responder of a single stop event.
        if (requestId != null && isTerminalRequestPayload(event.payload)) {
          if (requestId == locationStore.localSharingRequestId) {
            await _stopLocalLocationSharing(requestId, emitStop: false);
          }
          locationStore.clearRequest(requestId);
        }

        // A redacted invalidation intentionally carries no private snapshot.
        // REST is authoritative for deciding whether this particular responder
        // gained/lost compatibility (including ACCEPTED requests that remain
        // joinable after another responder accepted first).
        if (isResponder) await loadRequests(silent: true);
      }
      return;
    }

    if (event.name == 'responder.assigned') {
      // Multi-responder assignment confirmation. The backend always includes
      // the fresh request snapshot (with assignments[]); applying it keeps
      // acceptedBy lead semantics and de-duplicates naturally. Without a
      // snapshot, merge the single assignment row into any known request and
      // fall back to a silent REST refresh.
      final rawRequest = event.payload['request'];
      if (rawRequest is Map) {
        await _applyRealtimeRequest(
          EmergencyRequest.fromJson(Map<String, dynamic>.from(rawRequest)),
        );
        return;
      }

      final rawAssignment = event.payload['assignment'];
      final requestId = _asEventInt(event.payload['requestId']);
      if (rawAssignment is Map && requestId != null && mounted) {
        final assignment = ResponderAssignmentLine.fromJson(
          Map<String, dynamic>.from(rawAssignment),
        );
        setState(() {
          _replaceRequestIn(openRequests, requestId,
              (request) => request.withAssignment(assignment));
          _replaceRequestIn(logEntries, requestId,
              (request) => request.withAssignment(assignment));
        });
      }
      await refreshAll(silent: true);
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
      if (isResponder && responderId == ApiService.currentUserId) {
        await loadMyHelpTypes(silent: true);
      }
      return;
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
        // Multi-responder classification mirrors the backend participation
        // rule: ACTIVE assignment, unfinished own allocation, or the legacy
        // acceptedBy lead (payloads without assignment data).
        final mine = request.participatesAsResponder(ApiService.currentUserId);
        if (request.isOpen && mine) {
          openRequests.add(request);
        } else if (request.status == RequestStatus.pending) {
          // request.created is sent only to compatible responders.
          pendingCompatible.add(request);
        } else if (!request.isOpen && mine) {
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
    // The backend authorizes request-room subscriptions for exactly the
    // participation rule (ACTIVE assignment / unfinished allocation / legacy
    // lead), so the client subscribes to the same set.
    final authorizedOpenIds = openRequests
        .where((request) =>
            isAdmin ||
            isRequester ||
            (isResponder &&
                request.participatesAsResponder(ApiService.currentUserId)))
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
    if (isAdmin) await loadAdminUsers(silent: silent);

    if (isResponder) {
      await loadMyHelpTypes(silent: silent);
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
      final data = isAdmin
          ? await ApiService.getAdminResponders()
          : await ApiService.getResponders();

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

  Future<void> loadAdminUsers({bool silent = false}) async {
    if (!isAdmin) return;
    if (!silent && mounted) setState(() => adminUsersLoading = true);

    try {
      final loaded = await ApiService.getAdminUsers();
      if (!mounted) return;
      setState(() {
        adminUsers
          ..clear()
          ..addAll(loaded);
      });
    } catch (error) {
      if (!silent) showToast('Failed to load users: ${_clean(error)}');
    } finally {
      if (!silent && mounted) {
        setState(() => adminUsersLoading = false);
      }
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

  Future<void> loadMyHelpTypes({bool silent = false}) async {
    try {
      final data = await ApiService.getResponderHelpTypes();
      final categories = (data['categories'] as List<dynamic>? ?? <dynamic>[])
          .map((item) => Map<String, dynamic>.from(item as Map))
          .toList();
      final categoryLabelByValue = <String, String>{
        for (final item in categories)
          item['value'].toString(): item['label'].toString(),
      };
      final selected = (data['selected'] as List<dynamic>? ?? <dynamic>[])
          .map((item) => item.toString())
          .toSet();

      final loaded = selected.map((categoryValue) {
        return ResponderHelpType(
          category: categoryValue,
          label: categoryLabelByValue[categoryValue] ?? categoryValue,
          enabled: true,
        );
      }).toList();

      if (!mounted) return;

      setState(() {
        myHelpTypes
          ..clear()
          ..addAll(loaded);
      });
    } catch (error) {
      if (!silent) {
        showToast('Failed to load your help types: ${_clean(error)}');
      }
    }
  }

  List<EmergencyRequest> _parseRequests(List<dynamic> data) {
    final byId = <int, EmergencyRequest>{};
    for (final item in data) {
      if (item is! Map) continue;
      final request =
          EmergencyRequest.fromJson(Map<String, dynamic>.from(item));
      if (request.id > 0) byId[request.id] = request;
    }
    return byId.values.toList(growable: false);
  }

  Future<LocationPermissionResult> _checkLocationPermission() =>
      (widget.checkLocationPermission ?? checkDeviceLocationPermission)();

  Future<LocationPermissionResult> _requestLocationPermission() =>
      (widget.requestLocationPermission ?? ensureDeviceLocationPermission)();

  Future<void> _initializeLocationPermission() async {
    LocationPermissionResult result;
    try {
      result = await _checkLocationPermission();
      if (result.canRequest) {
        // A normal denial is promptable. The permission sheet may remain open,
        // but the console and all non-GPS actions are already usable.
        result = await _requestLocationPermission();
      }
    } catch (_) {
      result = const LocationPermissionResult(
        status: LocationPermissionStatus.unavailable,
        message: 'The device location service is unavailable.',
      );
    }
    if (!mounted) return;
    setState(() {
      locationPermissionGranted = result.isGranted;
      _locationPermissionChecked = true;
    });
  }

  Future<void> _retryLocationPermission() async {
    if (_locationPermissionRequestInProgress) return;
    setState(() => _locationPermissionRequestInProgress = true);
    LocationPermissionResult result;
    try {
      result = await _requestLocationPermission();
    } catch (_) {
      result = const LocationPermissionResult(
        status: LocationPermissionStatus.unavailable,
        message: 'The device location service is unavailable.',
      );
    }
    if (!mounted) return;
    setState(() {
      locationPermissionGranted = result.isGranted;
      _locationPermissionChecked = true;
      _locationPermissionRequestInProgress = false;
    });
    if (result.isDeniedForever ||
        result.status == LocationPermissionStatus.serviceDisabled) {
      unawaited(openDeviceLocationSettings());
    } else if (!result.isGranted) {
      showToast(result.message);
    }
  }

  /// GPS entry point shared by requester and admin emergency creation.
  /// Permission/service checks live in the shared location service so roles
  /// cannot drift into different platform behaviour.
  Future<GeoPoint?> _tryReadEmergencyGeoPoint() async {
    if (!isRequester && !isAdmin) return null;

    LocationPermissionResult permission;
    try {
      permission = await _requestLocationPermission();
    } on LocationServiceException catch (error) {
      final diagnostic = error.diagnosticMessage;
      if (diagnostic != null) debugPrint(diagnostic);
      rethrow;
    } catch (_) {
      final failure = LocationServiceException.forReason(
        LocationFailureReason.unexpectedFailure,
      );
      debugPrint(failure.diagnosticMessage);
      throw failure;
    }
    if (mounted) {
      setState(() {
        locationPermissionGranted = permission.isGranted;
        _locationPermissionChecked = true;
      });
    }

    final permissionFailure = permission.toLocationServiceException();
    if (permissionFailure != null) {
      final diagnostic = permissionFailure.diagnosticMessage;
      if (diagnostic != null) debugPrint(diagnostic);
      throw permissionFailure;
    }

    try {
      final point = await readDeviceLocation();
      if (!isUsableDeviceLocation(point)) {
        final failure = LocationServiceException.forReason(
          LocationFailureReason.providerUnavailable,
        );
        debugPrint(failure.diagnosticMessage);
        throw failure;
      }
      return point;
    } on LocationServiceException catch (error) {
      final diagnostic = error.diagnosticMessage;
      if (diagnostic != null) debugPrint(diagnostic);
      rethrow;
    } catch (_) {
      final failure = LocationServiceException.forReason(
        LocationFailureReason.unexpectedFailure,
      );
      debugPrint(failure.diagnosticMessage);
      throw failure;
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

      if (isAdmin) {
        await ApiService.createAdminRequest(
          emergencyType: payload.emergencyType,
          description: payload.description,
          location: payload.location,
          priority: payload.priority,
          latitude: latitude,
          longitude: longitude,
          requiredResources: payload.requiredResources,
        );
      } else {
        await ApiService.createRequest(
          emergencyType: payload.emergencyType,
          description: payload.description,
          location: payload.location,
          priority: payload.priority,
          latitude: latitude,
          longitude: longitude,
          requiredResources: payload.requiredResources,
        );
      }

      showToast(latitude == null || longitude == null
          ? 'Emergency request created with a text-only location. Precise map pin unavailable.'
          : 'Emergency request created with precise coordinates.');

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

  void viewRequest(EmergencyRequest request) {
    unawaited(showRequestDetailDialog(context, request));
  }

  Future<void> editRequest(EmergencyRequest request) async {
    // The server is authoritative as well; this local gate prevents opening a
    // knowingly immutable snapshot while still handling races on save.
    if (!isRequester || request.status != RequestStatus.pending) return;

    var saving = false;
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          final p = ErasPalette.of(dialogContext);
          return Dialog(
            key: const Key('edit-request-dialog'),
            backgroundColor: p.bg,
            surfaceTintColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: p.cardBorder),
            ),
            insetPadding: const EdgeInsets.all(14),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 900,
                maxHeight: MediaQuery.sizeOf(dialogContext).height * .92,
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: NewRequestPanel(
                  initialRequest: request,
                  panelTitle: 'EDIT ${request.displayId}',
                  submitLabel: 'Save changes',
                  resources: resources,
                  submitting: saving,
                  onReload: () => loadResources(silent: true),
                  onUseCurrentLocation: _tryReadEmergencyGeoPoint,
                  onSubmit: (payload) async {
                    setDialogState(() => saving = true);
                    try {
                      await ApiService.updateMyRequest(
                        requestId: request.id,
                        emergencyType: payload.emergencyType,
                        description: payload.description,
                        location: payload.location,
                        priority: payload.priority,
                        latitude: payload.latitude,
                        longitude: payload.longitude,
                        requiredResources: payload.requiredResources,
                      );
                      if (dialogContext.mounted) {
                        Navigator.of(dialogContext).pop(true);
                      }
                      return true;
                    } catch (error) {
                      showToast('Edit failed: ${_clean(error)}');
                      if (dialogContext.mounted) {
                        setDialogState(() => saving = false);
                      }
                      return false;
                    }
                  },
                ),
              ),
            ),
          );
        },
      ),
    );

    if (saved == true) {
      showToast('${request.displayId} updated');
      await loadRequests();
      await loadResources();
    }
  }

  Future<void> assignRequest(EmergencyRequest request) async {
    if (!isAdmin || request.status != RequestStatus.pending) return;

    // Refresh immediately before selection so the picker does not offer a
    // responder who became BUSY since the last board poll.
    await loadResponders();
    if (!mounted) return;
    final responder = await showDialog<BackendResponder>(
      context: context,
      builder: (_) => ResponderAssignmentDialog(
        request: request,
        responders: responders,
      ),
    );
    if (responder == null) return;

    try {
      await ApiService.assignAdminRequest(
        requestId: request.id,
        responderId: responder.id,
      );
      showToast('${responder.name} assigned to ${request.displayId}');
    } catch (error) {
      showToast('Assignment failed: ${_clean(error)}');
    }
    await loadRequests();
    await loadResponders();
  }

  Future<void> acceptRequest(EmergencyRequest request) async {
    var accepted = false;
    try {
      await ApiService.acceptEmergencyRequest(request.id);
      accepted = true;
      showToast('${request.displayId} accepted');
    } catch (error) {
      showToast('Accept failed: ${_clean(error)}');
    }

    await loadRequests();
    await loadResponders();
    await loadMyInventory();
    await loadMyHelpTypes();

    // AUTOMATIC LIVE LOCATION SHARING: the acceptance is already persisted, so
    // this is deliberately best-effort. A denied permission, a reconnecting
    // socket or a slow GPS fix can never roll the acceptance back; the
    // permission banner, its retry button and the manual START LOCATION button
    // all remain available.
    if (accepted) {
      await _autoStartLiveLocationSharing(request.id);
    }
  }

  /// Starts live location sharing right after this responder accepted an
  /// emergency. No-ops when this device is already sharing the same request,
  /// so a second accept or a rebuilt widget can never open a second watcher.
  Future<void> _autoStartLiveLocationSharing(int requestId) async {
    if (!isResponder) return;
    if (locationStore.localSharingRequestId == requestId) return;
    if (_locationStartInProgress) return;

    final refreshed = findRequest(requestId);
    if (refreshed == null) return;
    if (!refreshed.participatesAsResponder(ApiService.currentUserId)) return;

    await startLocationSharing(refreshed, automatic: true);
  }

  Future<void> startResponse(EmergencyRequest request) async {
    try {
      await ApiService.startEmergencyResponse(request.id);
      showToast('${request.displayId} response started');
    } catch (error) {
      showToast('Start response failed: ${_clean(error)}');
    }

    await loadRequests();
    await loadResponders();
    await loadMyInventory();
    await loadMyHelpTypes();
  }

  Future<void> completeResponse(EmergencyRequest request) async {
    try {
      await ApiService.completeEmergencyResponse(request.id);
      if (locationStore.localSharingRequestId == request.id) {
        await _stopLocalLocationSharing(request.id, emitStop: false);
      }
      showToast('${request.displayId} response completed');
    } catch (error) {
      showToast('Complete response failed: ${_clean(error)}');
    }

    await loadRequests();
    await loadResponders();
    await loadMyInventory();
    await loadMyHelpTypes();
  }

  Future<void> endAssignment(EmergencyRequest request) async {
    try {
      final response = await ApiService.endMyAssignment(request.id);
      final rawRequest = response['request'];
      if (rawRequest is Map) {
        final updated = EmergencyRequest.fromJson(
          Map<String, dynamic>.from(rawRequest),
        );
        if (!updated.participatesAsResponder(ApiService.currentUserId) &&
            locationStore.localSharingRequestId == request.id) {
          await _stopLocalLocationSharing(request.id, emitStop: false);
        }
      }
      showToast('${request.displayId} assignment ended');
    } catch (error) {
      showToast('End assignment failed: ${_clean(error)}');
    }

    await loadRequests();
    await loadResponders();
    await loadMyInventory();
    await loadMyHelpTypes();
  }

  Future<void> cancelRequest(EmergencyRequest request) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final p = ErasPalette.of(context);
        return AlertDialog(
          backgroundColor: p.surface,
          surfaceTintColor: Colors.transparent,
          title: Text(
            'Cancel emergency request?',
            style: TextStyle(color: p.text, fontWeight: FontWeight.w700),
          ),
          content: Text(
            'Cancel ${request.displayId}? The request is not deleted and will '
            'remain in the operational after-action history as CANCELLED.',
            style: TextStyle(fontSize: 13, height: 1.4, color: p.textDim),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              style: TextButton.styleFrom(foregroundColor: p.textDim),
              child: const Text('Keep request'),
            ),
            FilledButton(
              key: const Key('confirm-cancel-request-button'),
              onPressed: () => Navigator.of(context).pop(true),
              style: FilledButton.styleFrom(
                backgroundColor: p.red,
                foregroundColor: Colors.white,
              ),
              child: const Text('Cancel request'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) return;

    try {
      if (isAdmin) {
        await ApiService.cancelAdminRequest(request.id);
      } else {
        await ApiService.cancelMyRequest(request.id);
      }
      showToast('${request.displayId} cancelled');
    } catch (error) {
      showToast('Cancel failed: ${_clean(error)}');
    }

    await loadRequests();
    await loadResources();
    if (isAdmin) await loadResponders();
  }

  /// ADMIN-only removal of a closed after-action entry.
  ///
  /// The confirmation states plainly that the action is irreversible, and that
  /// the security audit record of the deletion itself is KEPT - the operational
  /// history and the security trail are separate by design. The server re-checks
  /// the ADMIN role and requires `confirm: true`, so this dialog is a
  /// convenience, never the security boundary.
  Future<void> deleteLogEntry(EmergencyRequest request) async {
    if (!isAdmin) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final p = ErasPalette.of(context);
        return AlertDialog(
          backgroundColor: p.surface,
          surfaceTintColor: Colors.transparent,
          title: Text(
            'Delete this log entry?',
            style: TextStyle(color: p.text, fontWeight: FontWeight.w700),
          ),
          content: Text(
            'Delete the after-action log entry for ${request.displayId}?\n\n'
            'This is irreversible: the entry disappears from the closed log '
            'immediately and cannot be restored from this console.\n\n'
            'The deletion itself is recorded in the security audit trail '
            '(ADMIN_DELETED_LOG) with your admin account, so the history of the '
            'action is preserved even though the log entry is removed.',
            style: TextStyle(fontSize: 13, height: 1.4, color: p.textDim),
          ),
          actions: [
            TextButton(
              key: const Key('cancel-delete-log-button'),
              onPressed: () => Navigator.of(context).pop(false),
              style: TextButton.styleFrom(foregroundColor: p.textDim),
              child: const Text('Keep entry'),
            ),
            FilledButton(
              key: const Key('confirm-delete-log-button'),
              onPressed: () => Navigator.of(context).pop(true),
              style: FilledButton.styleFrom(
                backgroundColor: p.red,
                foregroundColor: Colors.white,
              ),
              child: const Text('Delete entry'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) return;

    try {
      await ApiService.deleteAdminLog(request.id);
      showToast('${request.displayId} log entry deleted');
    } catch (error) {
      showToast('Delete failed: ${_clean(error)}');
    }

    await loadRequests();
  }

  // ---------------------------------------------------------------------
  // LEGACY allocation backend wrappers (Allocate / Dispatch / Delivered).
  // They are intentionally NOT part of the normal responder workflow, which
  // is Accept -> START RESPONSE -> COMPLETE RESPONSE for every emergency.
  // They remain only for history/compatibility (e.g. a requester confirming
  // receipt of a pre-existing allocation) and are not wired to the
  // responder board.
  // ---------------------------------------------------------------------
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
      builder: (context) {
        final p = ErasPalette.of(context);
        return AlertDialog(
          backgroundColor: p.surface,
          surfaceTintColor: Colors.transparent,
          title: Text(
            'Mark delivered',
            style: TextStyle(color: p.text, fontWeight: FontWeight.w700),
          ),
          content: Text(
            'Mark this resource as delivered?\n\n'
            '${allocation.resourceName} × ${allocation.quantity} will be '
            'marked as delivered and this allocation will be completed.',
            style: TextStyle(fontSize: 13, color: p.textDim),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              style: TextButton.styleFrom(foregroundColor: p.textDim),
              child: const Text('Not yet'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: FilledButton.styleFrom(
                backgroundColor: p.teal,
                foregroundColor: Colors.white,
              ),
              child: const Text('Mark Delivered'),
            ),
          ],
        );
      },
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

  /// Starts (or retries) live location sharing for [request].
  ///
  /// [automatic] is true when the call comes from a successful ACCEPT. In that
  /// case every failure is reported as guidance instead of an error, because
  /// the acceptance itself already stands and is never rolled back here.
  Future<void> startLocationSharing(
    EmergencyRequest request, {
    bool automatic = false,
  }) async {
    if (!isResponder ||
        !request.participatesAsResponder(ApiService.currentUserId) ||
        (request.status != RequestStatus.accepted &&
            request.status != RequestStatus.inProgress)) {
      if (!automatic) {
        showToast(
          'Live location is available after an assigned responder starts the response.',
        );
      }
      return;
    }
    if (connectionStatus != RealtimeConnectionStatus.connected ||
        !SocketService.instance.isConnected) {
      if (!automatic) {
        showToast('Live location requires a connected realtime service.');
      }
      return;
    }
    if (_locationStartInProgress) {
      if (!automatic) showToast('Live location is already starting.');
      return;
    }
    _locationStartInProgress = true;

    try {
      final permission = await _requestLocationPermission();
      if (mounted) {
        setState(() {
          locationPermissionGranted = permission.isGranted;
          _locationPermissionChecked = true;
        });
      }
      if (!permission.isGranted) {
        // A denied permission never undoes the acceptance. The responder sees
        // exactly what is off and how to turn it on.
        showToast(
          automatic
              ? 'Accepted. Turn on location permission to share your live '
                  'location with the requester.'
              : permission.message,
        );
        return;
      }

      // Cancel the old stream before authorizing a new request. This keeps the
      // device on one GPS subscription and one authenticated request room.
      await stopLocationSharing(locationStore.localSharingRequestId);
      final authorized =
          await SocketService.instance.startLocationSharing(request.id);
      if (!authorized) {
        throw Exception(
            'Location sharing was not authorized for this request.');
      }
      locationStore.beginLocalSharing(
        request.id,
        responderId: ApiService.currentUserId,
      );
      if (mounted) setState(() {});

      // Start the existing Socket.IO location stream immediately. The one-shot
      // best-effort initial fix can take longer (especially on a cold GPS), so
      // it must never delay live updates or change responder.start/update/stop.
      locationSubscription = watchDeviceLocation().listen(
        (point) {
          final requestId = locationStore.localSharingRequestId;
          if (requestId == null || !SocketService.instance.isConnected) return;
          SocketService.instance.updateLocation(
            requestId: requestId,
            latitude: point.latitude,
            longitude: point.longitude,
          );
        },
        onError: (Object _) {
          unawaited(stopLocationSharing(request.id));
        },
      );
      unawaited(_sendInitialLocationIfAvailable(request.id));
      showToast('Live responder location sharing started');
    } catch (error) {
      if (locationStore.localSharingRequestId == request.id) {
        await stopLocationSharing(request.id);
      }
      showToast('Location sharing failed: ${_clean(error)}');
    } finally {
      _locationStartInProgress = false;
    }
  }

  Future<void> _sendInitialLocationIfAvailable(int requestId) async {
    try {
      final point = await readDeviceLocation();
      if (!mounted ||
          !isUsableDeviceLocation(point) ||
          locationStore.localSharingRequestId != requestId ||
          !SocketService.instance.isConnected) {
        return;
      }
      SocketService.instance.updateLocation(
        requestId: requestId,
        latitude: point!.latitude,
        longitude: point.longitude,
      );
    } on LocationServiceException catch (error) {
      // An initial one-shot fix is best effort. The live stream remains active
      // and may provide the first coordinate shortly afterward.
      final diagnostic = error.diagnosticMessage;
      if (diagnostic != null) debugPrint(diagnostic);
    } catch (_) {
      // Do not interrupt the established Socket.IO live-location pipeline.
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
    if (mounted) setState(() {});
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

  Future<void> viewAdminUserDetails(AdminUser user) async {
    if (!isAdmin) return;
    final action = await showDialog<AdminUserDetailsAction>(
      context: context,
      builder: (_) => AdminUserDetailsDialog(
        user: user,
        canChangeActive:
            !user.isActive || user.id != ApiService.currentUserId,
      ),
    );
    if (!mounted) return;

    if (action == AdminUserDetailsAction.edit) {
      await editAdminUser(user);
    } else if (action == AdminUserDetailsAction.changeActive) {
      await changeAdminUserActiveState(user);
    }
  }

  Future<void> editAdminUser(AdminUser user) async {
    if (!isAdmin || _adminUserBusyIds.contains(user.id)) return;
    final values = await showDialog<AdminUserEditValues>(
      context: context,
      builder: (_) => AdminUserEditDialog(user: user),
    );
    if (values == null || !mounted) return;

    setState(() => _adminUserBusyIds.add(user.id));
    try {
      await ApiService.updateAdminUser(
        user.id,
        name: values.name,
        phone: values.phone,
      );
      await loadAdminUsers(silent: true);
      showToast('User profile updated');
    } catch (error) {
      showToast('Save failed: ${_clean(error)}');
    } finally {
      if (mounted) setState(() => _adminUserBusyIds.remove(user.id));
    }
  }

  Future<void> changeAdminUserActiveState(AdminUser user) async {
    if (!isAdmin || _adminUserBusyIds.contains(user.id)) return;
    if (user.isActive && user.id == ApiService.currentUserId) {
      showToast('You cannot deactivate your own account.');
      return;
    }

    final activating = !user.isActive;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final p = ErasPalette.of(dialogContext);
        return AlertDialog(
          backgroundColor: p.surface,
          surfaceTintColor: Colors.transparent,
          title: Text(
            activating ? 'Activate this account?' : 'Deactivate this account?',
            style: TextStyle(color: p.text, fontWeight: FontWeight.w700),
          ),
          content: Text(
            activating
                ? 'The user will be able to sign in and use ERAS again.'
                : 'The user will no longer be able to sign in or use ERAS. '
                    'Emergency and allocation history will be preserved.',
            style: TextStyle(fontSize: 13, height: 1.4, color: p.textDim),
          ),
          actions: [
            TextButton(
              key: Key(
                activating
                    ? 'cancel-activate-admin-user-${user.id}'
                    : 'cancel-deactivate-admin-user-${user.id}',
              ),
              onPressed: () => Navigator.of(dialogContext).pop(false),
              style: TextButton.styleFrom(foregroundColor: p.textDim),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: Key(
                activating
                    ? 'confirm-activate-admin-user-${user.id}'
                    : 'confirm-deactivate-admin-user-${user.id}',
              ),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              style: FilledButton.styleFrom(
                backgroundColor: activating ? p.teal : p.amber,
                foregroundColor: Colors.white,
              ),
              child: Text(activating ? 'Activate' : 'Deactivate'),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) return;

    setState(() => _adminUserBusyIds.add(user.id));
    try {
      if (activating) {
        await ApiService.activateAdminUser(user.id);
      } else {
        await ApiService.deactivateAdminUser(user.id);
      }
      await loadAdminUsers(silent: true);
      showToast(activating ? 'User activated' : 'User deactivated');
    } catch (error) {
      showToast('Update failed: ${_clean(error)}');
    } finally {
      if (mounted) setState(() => _adminUserBusyIds.remove(user.id));
    }
  }

  Future<void> deleteAdminUser(AdminUser user) async {
    if (!isAdmin ||
        _adminUserBusyIds.contains(user.id) ||
        user.id == ApiService.currentUserId ||
        !user.history.deletable) {
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final p = ErasPalette.of(dialogContext);
        return AlertDialog(
          backgroundColor: p.surface,
          surfaceTintColor: Colors.transparent,
          title: Text(
            'Delete this account?',
            style: TextStyle(color: p.text, fontWeight: FontWeight.w700),
          ),
          content: Text(
            'Permanently remove ${user.name} (ID ${user.id}) from ERAS? '
            'This cannot be undone. Only accounts with no operational history '
            'may be deleted. The backend will verify the account history again '
            'before removing it.',
            style: TextStyle(fontSize: 13, height: 1.4, color: p.textDim),
          ),
          actions: [
            TextButton(
              key: Key('cancel-delete-admin-user-${user.id}'),
              onPressed: () => Navigator.of(dialogContext).pop(false),
              style: TextButton.styleFrom(foregroundColor: p.textDim),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: Key('confirm-delete-admin-user-${user.id}'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              style: FilledButton.styleFrom(
                backgroundColor: p.red,
                foregroundColor: Colors.white,
              ),
              child: const Text('Delete account'),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) return;

    setState(() => _adminUserBusyIds.add(user.id));
    try {
      // `history.deletable` only controls whether the secondary action is
      // shown. DELETE is still sent to the backend, which transactionally
      // rechecks history and may refuse a stale directory result.
      await ApiService.deleteAdminUser(user.id, confirm: true);
      await loadAdminUsers(silent: true);
      showToast('User deleted');
    } catch (error) {
      if (error is ApiServiceException &&
          error.statusCode == 409 &&
          error.code == 'USER_HAS_HISTORY') {
        showToast(
          'This account cannot be deleted because it has ERAS operational history. '
          'Deactivate it instead.',
        );
      } else {
        showToast('Delete failed: ${_clean(error)}');
      }
    } finally {
      if (mounted) setState(() => _adminUserBusyIds.remove(user.id));
    }
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

  EmergencyRequest? findRequest(int id) {
    return firstWhereOrNull(openRequests, (r) => r.id == id) ??
        firstWhereOrNull(pendingCompatible, (r) => r.id == id);
  }

  Future<void> logout() async {
    await stopLocationSharing(locationStore.localSharingRequestId);
    SocketService.instance.disconnect();
    // Remove this device's FCM registration on the way out (best-effort; the
    // backend drops stale tokens on its own as well).
    if (isResponder) {
      unawaited(PushNotificationService.instance.stop());
    }
    try {
      await ApiService.logout();
    } catch (_) {
      // ApiService clears the local ERAS token in its finally block. A network
      // outage must not prevent provider sign-out or leave this console open.
      debugPrint('Backend logout was unavailable; local session was cleared.');
    }
    await GoogleAuthService.instance.signOut();
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
    final p = ErasPalette.of(context);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: TextStyle(color: p.text, fontSize: 13),
        ),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(milliseconds: 3600),
        backgroundColor: p.surface2,
        elevation: 2,
        shape: Border(left: BorderSide(color: p.teal, width: 4)),
      ),
    );
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
        ConsoleView.newRequest => 'New Emergency',
        ConsoleView.resources => 'Resources',
        ConsoleView.responders => 'Responders',
        ConsoleView.log => 'Closed Log',
        ConsoleView.users => 'User Management',
      };

  String get viewSubtitle => switch (activeView) {
        ConsoleView.board => 'Live request state',
        ConsoleView.newRequest => 'Request any active resource in the catalog',
        ConsoleView.resources => isResponder
            ? 'Help types and optional resource inventory'
            : 'Resource catalog and inventory',
        ConsoleView.responders => 'Responders registered',
        ConsoleView.log => 'Completed and cancelled requests',
        ConsoleView.users => 'Profiles and operational history',
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
    final p = ErasPalette.of(context);
    final width = MediaQuery.of(context).size.width;
    final isMobile = width < 720;
    final items = navItemsForRole(role);

    if (!items.any((item) => item.view == activeView)) {
      activeView = items.first.view;
    }

    if (isMobile) {
      return Scaffold(
        backgroundColor: p.bg,
        appBar: MobileAppBar(
          pending: pendingCount,
          active: activeCount,
          completed: closedCount,
          title: viewTitle,
          onRefresh: refreshAll,
          onLogout: logout,
          connectionStatus: connectionStatus,
          topInset: MediaQuery.of(context).padding.top,
        ),
        body: SafeArea(
          top: false,
          child: RefreshIndicator(
            color: p.teal,
            backgroundColor: p.surface2,
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
      backgroundColor: p.bg,
      body: SafeArea(
        bottom: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Rail(
              items: items,
              activeView: activeView,
              onViewChanged: setView,
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

    if (_locationPermissionChecked && !locationPermissionGranted) {
      children.add(
        LocationPermissionBanner(
          requestInProgress: _locationPermissionRequestInProgress,
          onEnableLocation: _retryLocationPermission,
        ),
      );
    }

    if (activeView == ConsoleView.board) {
      children.addAll(_boardChildren(isMobile));
    }

    if (activeView == ConsoleView.newRequest && (isRequester || isAdmin)) {
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
          ResponderHelpTypesPanel(
            helpTypes: myHelpTypes,
            title: 'MY HELP TYPES',
            onEditHelpTypes: editMyHelpTypes,
          ),
        );
        children.add(const SizedBox(height: 18));
        children.add(
          ResponderResourcesPanel(
            resources: myInventory,
            title: 'RESOURCE INVENTORY',
            onEditInventory: editMyHelpTypes,
          ),
        );
      }
    }

    if (activeView == ConsoleView.users && isAdmin) {
      children.add(
        AdminUserManagementPanel(
          users: adminUsers,
          loading: adminUsersLoading,
          busyUserIds: _adminUserBusyIds,
          currentUserId: ApiService.currentUserId,
          onRefresh: loadAdminUsers,
          onViewDetails: viewAdminUserDetails,
          onEdit: editAdminUser,
          onChangeActive: changeAdminUserActiveState,
          onDelete: deleteAdminUser,
        ),
      );
    }

    if (activeView == ConsoleView.responders) {
      children.add(
        BackendRespondersPanel(responders: responders, isMobile: isMobile),
      );
    }

    if (activeView == ConsoleView.log) {
      children.add(
        LogPanel(
          logEntries: logEntries,
          onViewRequest: viewRequest,
          // Destructive after-action removal is ADMIN-only. Every other role
          // gets no callback at all, so the control is never rendered.
          onDeleteEntry: isAdmin ? deleteLogEntry : null,
          isMobile: isMobile,
        ),
      );
    }

    return AnimatedSwap(
      duration: AuthMotion.normal,
      offset: const Offset(0, 8),
      child: ListView(
        key: ValueKey<ConsoleView>(activeView),
        // Content-driven scrolling area with compact outer padding. Extra
        // bottom space on mobile clears the floating bottom navigation bar.
        padding: EdgeInsets.fromLTRB(
          isMobile ? 12 : 24,
          isMobile ? 12 : 18,
          isMobile ? 12 : 24,
          isMobile ? 84 : 28,
        ),
        children: children,
      ),
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
          onViewRequest: viewRequest,
          // Normal responder workflow for every emergency (resource-free or
          // resource-bearing): Accept -> START RESPONSE -> COMPLETE RESPONSE.
          // The legacy Allocate / Dispatch / Delivered hooks are deliberately
          // NOT wired here, so no allocation control appears on this board.
          onStartResponse: startResponse,
          onCompleteResponse: completeResponse,
          onEndAssignment: endAssignment,
          onStartLocationSharing: startLocationSharing,
          onStopLocationSharing: stopLocationSharing,
          liveLocations: locationStore.locationsByRequest,
          activelySharingRequestIds: locationStore.activelySharingRequestIds,
          sharingRequestId: locationStore.localSharingRequestId,
          connectionStatus: connectionStatus,
          isMobile: isMobile,
        ),
      );

      children.add(const SizedBox(height: 18));
      children.add(
        BoardPanel(
          title: 'COMPATIBLE REQUESTS',
          hint: 'Open work matched against your help types and resources',
          requests: pendingCompatible,
          role: role,
          currentUserId: ApiService.currentUserId,
          emptyTitle: 'NO COMPATIBLE REQUESTS',
          emptyIcon: Icons.inbox_outlined,
          emptyMessage:
              'Open requests appear here when their category matches one of '
              'your help types and any requested resources are compatible.',
          onViewRequest: viewRequest,
          onAccept: acceptRequest,
          connectionStatus: connectionStatus,
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
              ? 'No active requests. Submit one from "New Emergency".'
              : 'No active request is available.',
          onViewRequest: viewRequest,
          onEditRequest: isRequester ? editRequest : null,
          onAssignRequest: isAdmin ? assignRequest : null,
          onCancelRequest: (isRequester || isAdmin) ? cancelRequest : null,
          onConfirmReceipt: isRequester ? confirmReceipt : null,
          liveLocations: locationStore.locationsByRequest,
          activelySharingRequestIds: locationStore.activelySharingRequestIds,
          connectionStatus: connectionStatus,
          isMobile: isMobile,
        ),
      );
    }

    children.add(const SizedBox(height: 18));
    // High-frequency GPS notifications are intentionally scoped to the map.
    // The request board rebuilds only for request/lifecycle changes, not every
    // responder coordinate.
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
            liveLocations: locationStore.locationsByRequest,
            locationPermissionGranted: locationPermissionGranted,
            onRequestLocationPermission: _retryLocationPermission,
            isMobile: isMobile,
          ),
        ),
      ),
    );

    return children;
  }
}
