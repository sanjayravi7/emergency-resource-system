import 'dart:async';

import 'package:flutter/material.dart';

import '../Services/api_service.dart';
import '../models/eras_models.dart';
import '../theme/app_theme.dart';
import '../widgets/allocation_dialog.dart';
import '../widgets/board_panel.dart';
import '../widgets/common_widgets.dart';
import '../widgets/log_panel.dart';
import '../widgets/new_request_panel.dart';
import '../widgets/resource_panels.dart';
import '../widgets/sector_map.dart';
import 'login_screen.dart';

/// Single place where the app talks to the backend.
///
/// Every mutation is followed by an explicit reload of the affected data, so
/// the UI always shows what PostgreSQL contains. A push transport (Socket.IO)
/// could later call the very same reload methods.
class DispatchConsolePage extends StatefulWidget {
  const DispatchConsolePage({super.key});

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

  String? get role => ApiService.currentRole;
  bool get isRequester => role == 'REQUESTER';
  bool get isResponder => role == 'RESPONDER';
  bool get isAdmin => role == 'ADMIN';

  @override
  void initState() {
    super.initState();

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
  }

  @override
  void dispose() {
    clockTimer?.cancel();
    refreshTimer?.cancel();
    super.dispose();
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
    }

    if (!mounted) return;
    if (!silent) setState(() => loading = false);
  }

  Future<void> loadResources({bool silent = false}) async {
    try {
      final data = await ApiService.getResources(includeInactive: isAdmin);

      final loaded = data
          .map((item) =>
              BackendResource.fromJson(Map<String, dynamic>.from(item as Map)))
          .toList();

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

  // -------------------------------------------------------------------
  // MUTATIONS - each one reloads the data it touched
  // -------------------------------------------------------------------

  Future<bool> submitRequest(NewRequestPayload payload) async {
    setState(() => submitting = true);

    try {
      await ApiService.createRequest(
        emergencyType: payload.emergencyType,
        description: payload.description,
        location: payload.location,
        priority: payload.priority,
        latitude: null,
        longitude: null,
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
          'Cancel ${request.displayId}? Only PENDING requests can be cancelled.',
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

    return success;
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
      ),
    );
  }

  EmergencyRequest? findRequest(int id) {
    return firstWhereOrNull(openRequests, (r) => r.id == id) ??
        firstWhereOrNull(pendingCompatible, (r) => r.id == id);
  }

  void logout() {
    ApiService.logout();

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
            title: 'MY INVENTORY',
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
          isMobile: isMobile,
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
          isMobile: isMobile,
        ),
      );
    }

    children.add(const SizedBox(height: 18));

    children.add(
      Panel(
        title: 'SECTOR MAP',
        hint: 'Districts, responders and open requests',
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
                  LegendItem(color: AppColors.amber, label: 'Pending request'),
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
