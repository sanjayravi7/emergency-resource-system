import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../models/eras_models.dart';
import '../services/direct_connection_service.dart';
import '../services/url_launcher_adapter.dart';
import '../theme/app_theme.dart';
import 'common_widgets.dart';

/// Marker categories used by the operational Google Map. These are deliberately
/// data-driven: every position comes from EmergencyRequest latitude/longitude
/// or an authorized Socket.IO responder location update.
enum OperationalMapMarkerKind {
  activeRequest,
  pendingRequest,
  liveResponder,
  lastKnownResponder,
}

class OperationalMapMarkerSnapshot {
  const OperationalMapMarkerSnapshot({
    required this.id,
    required this.kind,
    required this.position,
    required this.title,
    required this.snippet,
    required this.requestId,
    this.responderId,
  });

  final String id;
  final OperationalMapMarkerKind kind;
  final LatLng position;
  final String title;
  final String snippet;
  final int requestId;
  final int? responderId;

  MarkerId get markerId => MarkerId(id);
  bool get isResponder => responderId != null;
  bool get isRequest => responderId == null;
  bool get isLiveResponder => kind == OperationalMapMarkerKind.liveResponder;

  double get _hue => switch (kind) {
        OperationalMapMarkerKind.activeRequest => BitmapDescriptor.hueRed,
        OperationalMapMarkerKind.pendingRequest => BitmapDescriptor.hueYellow,
        OperationalMapMarkerKind.liveResponder => BitmapDescriptor.hueGreen,
        OperationalMapMarkerKind.lastKnownResponder => BitmapDescriptor.hueAzure,
      };

  Marker toMarker() => Marker(
        markerId: markerId,
        position: position,
        icon: BitmapDescriptor.defaultMarkerWithHue(_hue),
        infoWindow: InfoWindow(title: title, snippet: snippet),
      );
}

class OperationalMapMarkerBuilder {
  const OperationalMapMarkerBuilder();

  List<OperationalMapMarkerSnapshot> buildSnapshots({
    required Iterable<EmergencyRequest> requests,
    required Map<int, LiveResponderLocation> liveLocations,
  }) {
    final openRequests = <int, EmergencyRequest>{
      for (final request in requests)
        if (request.isOpen) request.id: request,
    };

    final snapshots = <OperationalMapMarkerSnapshot>[];

    for (final request in openRequests.values) {
      if (!request.hasPreciseLocation) continue;

      final isPending = request.status == RequestStatus.pending;
      snapshots.add(
        OperationalMapMarkerSnapshot(
          id: 'request-${request.id}',
          kind: isPending
              ? OperationalMapMarkerKind.pendingRequest
              : OperationalMapMarkerKind.activeRequest,
          position: LatLng(request.latitude!, request.longitude!),
          requestId: request.id,
          title: isPending
              ? '${request.displayId} · PENDING REQUEST'
              : '${request.displayId} · EMERGENCY',
          snippet: _requestSnippet(request),
        ),
      );
    }

    for (final entry in liveLocations.entries) {
      final request = openRequests[entry.key];
      if (request == null) continue;

      final live = entry.value;
      final responderName = request.acceptedBy?.id == live.responderId
          ? request.acceptedBy!.name
          : 'Responder #${live.responderId}';
      final assignedResources = request.activeAllocations
          .where((allocation) => allocation.responderId == live.responderId)
          .map((allocation) => allocation.resourceName)
          .toSet()
          .join(', ');

      snapshots.add(
        OperationalMapMarkerSnapshot(
          id: 'responder-${request.id}-${live.responderId}',
          kind: live.isLive
              ? OperationalMapMarkerKind.liveResponder
              : OperationalMapMarkerKind.lastKnownResponder,
          position: LatLng(live.latitude, live.longitude),
          requestId: request.id,
          responderId: live.responderId,
          title: live.isLive
              ? 'LIVE responder · $responderName'
              : 'LAST KNOWN responder · $responderName',
          snippet: _responderSnippet(
            request: request,
            live: live,
            assignedResources: assignedResources,
          ),
        ),
      );
    }

    snapshots.sort((left, right) => left.id.compareTo(right.id));
    return snapshots;
  }

  String _requestSnippet(EmergencyRequest request) {
    final parts = <String>[
      request.emergencyType,
      request.priority.toUpperCase(),
      request.location,
    ];
    final coordinates = request.coordinateLabel;
    if (coordinates != null) parts.add(coordinates);
    return parts.where((part) => part.trim().isNotEmpty).join(' · ');
  }

  String _responderSnippet({
    required EmergencyRequest request,
    required LiveResponderLocation live,
    required String assignedResources,
  }) {
    final parts = <String>[
      request.displayId,
      if (assignedResources.isNotEmpty) assignedResources,
      formatCoordinatePair(live.latitude, live.longitude),
      'updated ${formatDateTime(live.updatedAt)}',
    ];
    return parts.join(' · ');
  }
}

/// Stable id of the direct responder ↔ emergency connection line.
///
/// This is a simple straight geometric connection between two coordinates.
/// It is NOT a road route: ERAS computes no routing here and calls no routing
/// service. Real driving directions come from the external Google Maps URL.
const PolylineId kDirectConnectionPolylineId = PolylineId('direct-connection');

/// Builds the straight connection line between the responder and the
/// emergency. Local map geometry only — no API request.
Polyline buildDirectConnectionPolyline(DirectConnection connection) {
  return Polyline(
    polylineId: kDirectConnectionPolylineId,
    points: <LatLng>[
      LatLng(connection.responder.latitude, connection.responder.longitude),
      LatLng(connection.emergency.latitude, connection.emergency.longitude),
    ],
    color: AppColors.blue,
    width: 4,
    patterns: <PatternItem>[PatternItem.dash(18), PatternItem.gap(10)],
  );
}

class OperationalGoogleMap extends StatefulWidget {
  const OperationalGoogleMap({
    super.key,
    required this.requests,
    required this.liveLocations,
    this.isMobile = false,
    this.urlLauncher,
  });

  final List<EmergencyRequest> requests;
  final Map<int, LiveResponderLocation> liveLocations;
  final bool isMobile;

  /// Opens the external Google Maps Directions URL. Defaults to the
  /// `url_launcher` adapter; injectable so tests never open Google Maps.
  final ExternalUrlLauncher? urlLauncher;

  @override
  State<OperationalGoogleMap> createState() => _OperationalGoogleMapState();
}

class _OperationalGoogleMapState extends State<OperationalGoogleMap> {
  static const _markerBuilder = OperationalMapMarkerBuilder();
  static const _fallbackCamera = CameraPosition(
    target: LatLng(0, 0),
    zoom: 2,
  );

  GoogleMapController? _controller;
  bool _initialCameraApplied = false;
  final Set<String> _autoFittedResponderMarkers = <String>{};

  ExternalUrlLauncher get _launcher =>
      widget.urlLauncher ?? defaultExternalUrlLauncher;

  /// The single responder → emergency pair that may show a connection line.
  /// Recomputed from the current board state on every build, so the line
  /// follows live GPS updates and disappears as soon as the request is
  /// completed/cancelled, the assignment is removed, or coordinates vanish.
  DirectConnection? get _connection => selectDirectConnection(
        requests: widget.requests,
        liveLocations: widget.liveLocations,
      );

  List<OperationalMapMarkerSnapshot> get _snapshots =>
      _markerBuilder.buildSnapshots(
        requests: widget.requests,
        liveLocations: widget.liveLocations,
      );

  List<EmergencyRequest> get _textOnlyOpenRequests => widget.requests
      .where((request) => request.isOpen && !request.hasPreciseLocation)
      .toList(growable: false);

  @override
  void didUpdateWidget(covariant OperationalGoogleMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_controller == null) return;

    final oldResponderMarkerIds = _markerBuilder
        .buildSnapshots(
          requests: oldWidget.requests,
          liveLocations: oldWidget.liveLocations,
        )
        .where((snapshot) => snapshot.isResponder)
        .map((snapshot) => snapshot.id)
        .toSet();

    final newResponderMarkers = _snapshots
        .where((snapshot) =>
            snapshot.isResponder &&
            !oldResponderMarkerIds.contains(snapshot.id) &&
            !_autoFittedResponderMarkers.contains(snapshot.id))
        .toList(growable: false);

    if (newResponderMarkers.isEmpty) return;
    _autoFittedResponderMarkers.addAll(
      newResponderMarkers.map((snapshot) => snapshot.id),
    );
    unawaited(_fitAllPins());
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snapshots = _snapshots;
    final markers = snapshots.map((snapshot) => snapshot.toMarker()).toSet();
    final textOnlyOpenRequests = _textOnlyOpenRequests;
    final connection = _connection;
    final polylines = <Polyline>{
      if (connection != null) buildDirectConnectionPolyline(connection),
    };

    return LayoutBuilder(
      builder: (context, constraints) {
        final height = widget.isMobile
            ? 300.0
            : math.max(340.0, math.min(460.0, constraints.maxWidth * .38));

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: height,
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(
                  bottom: Radius.circular(0),
                ),
                child: Stack(
                  children: [
                    GoogleMap(
                      initialCameraPosition: _initialCamera(snapshots),
                      markers: markers,
                      polylines: polylines,
                      mapToolbarEnabled: false,
                      myLocationButtonEnabled: false,
                      zoomControlsEnabled: !widget.isMobile,
                      compassEnabled: true,
                      onMapCreated: (controller) {
                        _controller = controller;
                        unawaited(_applyInitialCamera());
                      },
                    ),
                    Positioned(
                      left: 12,
                      top: 12,
                      child: _MapControls(
                        onCenterEmergency: _centerOnEmergency,
                        // The user keeps full pan/zoom control: the camera is
                        // only moved by these explicit buttons, never by an
                        // incoming responder GPS update.
                        onFitPins: markers.isEmpty ? null : _fitAllPins,
                        onGetDirections:
                            connection == null ? null : _openDirections,
                      ),
                    ),
                    if (connection != null)
                      Positioned(
                        right: 12,
                        top: 12,
                        child: NavigationInfoCard(
                          connection: connection,
                          onGetDirections: () =>
                              unawaited(_openDirections()),
                        ),
                      ),
                    if (markers.isEmpty)
                      const Positioned.fill(
                        child: IgnorePointer(
                          child: _NoPreciseMarkersOverlay(),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 12,
                    runSpacing: 6,
                    children: [
                      const LegendItem(
                        color: AppColors.red,
                        label: 'Active emergency',
                      ),
                      const LegendItem(
                        color: AppColors.amber,
                        label: 'Pending request',
                      ),
                      const LegendItem(
                        color: AppColors.teal,
                        label: 'LIVE responder',
                      ),
                      const LegendItem(
                        color: AppColors.blue,
                        label: 'LAST KNOWN responder',
                      ),
                      if (connection != null)
                        const LegendItem(
                          color: AppColors.blue,
                          label: 'Direct connection (straight line)',
                        ),
                    ],
                  ),
                  if (textOnlyOpenRequests.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      '${textOnlyOpenRequests.length} open request${textOnlyOpenRequests.length == 1 ? '' : 's'} '
                      'have text-only locations. Precise map pins are unavailable until GPS coordinates are provided.',
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: AppColors.textFaint,
                        height: 1.35,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  CameraPosition _initialCamera(List<OperationalMapMarkerSnapshot> snapshots) {
    final focus = _emergencyFocus(snapshots) ??
        (snapshots.isNotEmpty ? snapshots.first.position : null);
    if (focus == null) return _fallbackCamera;
    return CameraPosition(target: focus, zoom: 14);
  }

  Future<void> _applyInitialCamera() async {
    if (_initialCameraApplied) return;
    _initialCameraApplied = true;

    // Let the platform view settle before issuing a bounds update. This is a
    // one-time convenience only; subsequent GPS updates do not force-follow.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (!mounted) return;

    final snapshots = _snapshots;
    final hasResponder = snapshots.any((snapshot) => snapshot.isResponder);
    if (hasResponder && snapshots.length > 1) {
      await _fitAllPins();
    } else {
      await _centerOnEmergency(showMessageWhenUnavailable: false);
    }
  }

  LatLng? _emergencyFocus(List<OperationalMapMarkerSnapshot> snapshots) {
    final activeEmergency = firstWhereOrNull(
      snapshots,
      (snapshot) => snapshot.kind == OperationalMapMarkerKind.activeRequest,
    );
    if (activeEmergency != null) return activeEmergency.position;

    final pendingEmergency = firstWhereOrNull(
      snapshots,
      (snapshot) => snapshot.kind == OperationalMapMarkerKind.pendingRequest,
    );
    return pendingEmergency?.position;
  }

  Future<void> _centerOnEmergency({bool showMessageWhenUnavailable = true}) async {
    final controller = _controller;
    final focus = _emergencyFocus(_snapshots);
    if (controller == null || focus == null) {
      if (showMessageWhenUnavailable && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No emergency has precise coordinates yet.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    await controller.animateCamera(CameraUpdate.newLatLngZoom(focus, 15));
  }

  /// Hands the actual driving directions to Google Maps: a universal Maps
  /// URL that opens the Google Maps app on Android/iOS and the Google Maps
  /// website on desktop/web. No API key and no routing call inside ERAS.
  Future<void> _openDirections() async {
    final connection = _connection;
    if (connection == null) return;

    final opened = await openGoogleMapsDirections(
      connection: connection,
      launcher: _launcher,
    );

    if (opened || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Could not open Google Maps directions.'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// Fits the camera around every precise pin (emergency + responder).
  /// Camera work only: no route or distance calculation happens here.
  Future<void> _fitAllPins() async {
    final controller = _controller;
    if (controller == null) return;

    final positions = _snapshots.map((snapshot) => snapshot.position).toList();
    if (positions.isEmpty) return;
    if (positions.length == 1) {
      await controller.animateCamera(
        CameraUpdate.newLatLngZoom(positions.single, 15),
      );
      return;
    }

    await controller.animateCamera(
      CameraUpdate.newLatLngBounds(_boundsFor(positions), 64),
    );
  }

  LatLngBounds _boundsFor(List<LatLng> positions) {
    var minLatitude = positions.first.latitude;
    var maxLatitude = positions.first.latitude;
    var minLongitude = positions.first.longitude;
    var maxLongitude = positions.first.longitude;

    for (final position in positions.skip(1)) {
      minLatitude = math.min(minLatitude, position.latitude);
      maxLatitude = math.max(maxLatitude, position.latitude);
      minLongitude = math.min(minLongitude, position.longitude);
      maxLongitude = math.max(maxLongitude, position.longitude);
    }

    // Same-point bounds are invalid for Google Maps. Expanding the camera
    // bounds does not fabricate any marker coordinate; it only creates a valid
    // viewport around the true point.
    if ((maxLatitude - minLatitude).abs() < .0001) {
      minLatitude -= .0001;
      maxLatitude += .0001;
    }
    if ((maxLongitude - minLongitude).abs() < .0001) {
      minLongitude -= .0001;
      maxLongitude += .0001;
    }

    return LatLngBounds(
      southwest: LatLng(minLatitude, minLongitude),
      northeast: LatLng(maxLatitude, maxLongitude),
    );
  }
}

class _MapControls extends StatelessWidget {
  const _MapControls({
    required this.onCenterEmergency,
    this.onFitPins,
    this.onGetDirections,
  });

  final Future<void> Function() onCenterEmergency;
  final Future<void> Function()? onFitPins;
  final Future<void> Function()? onGetDirections;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: .94),
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            blurRadius: 16,
            offset: const Offset(0, 6),
            color: Colors.black.withValues(alpha: .08),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            TextButton.icon(
              onPressed: () => unawaited(onCenterEmergency()),
              icon: const Icon(Icons.emergency_share_rounded, size: 16),
              label: const Text('Center on emergency'),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.red,
                textStyle: const TextStyle(fontSize: 12),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
              ),
            ),
            TextButton.icon(
              onPressed:
                  onFitPins == null ? null : () => unawaited(onFitPins!()),
              icon: const Icon(Icons.fit_screen_rounded, size: 16),
              label: const Text('Fit pins'),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.blue,
                textStyle: const TextStyle(fontSize: 12),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
              ),
            ),
            TextButton.icon(
              onPressed: onGetDirections == null
                  ? null
                  : () => unawaited(onGetDirections!()),
              icon: const Icon(Icons.directions_rounded, size: 16),
              label: const Text('Get directions'),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.teal,
                textStyle: const TextStyle(fontSize: 12),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "RESPONDER → EMERGENCY" navigation card.
///
/// It reports only facts ERAS actually knows: whether the responder position
/// is live, that the emergency coordinates are set, and the straight-line
/// distance between the two points. No driving distance and no ETA are
/// computed here — Google Maps provides those once "Get directions" opens.
class NavigationInfoCard extends StatelessWidget {
  const NavigationInfoCard({
    super.key,
    required this.connection,
    required this.onGetDirections,
    this.showDirectDistance = true,
  });

  final DirectConnection connection;
  final VoidCallback onGetDirections;
  final bool showDirectDistance;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: .94),
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            blurRadius: 16,
            offset: const Offset(0, 6),
            color: Colors.black.withValues(alpha: .08),
          ),
        ],
      ),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 250),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'RESPONDER → EMERGENCY',
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w800,
                letterSpacing: .8,
                color: AppColors.textDim,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Responder location: '
              '${connection.responderIsLive ? 'LIVE' : 'LAST KNOWN'}',
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: AppColors.text,
              ),
            ),
            const SizedBox(height: 2),
            const Text(
              'Emergency location: SET',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: AppColors.text,
              ),
            ),
            if (showDirectDistance) ...[
              const SizedBox(height: 4),
              Text(
                'Direct distance: ${connection.directDistanceLabel}',
                style: const TextStyle(
                  fontSize: 11.5,
                  color: AppColors.textDim,
                ),
              ),
              const Text(
                'Straight-line only, not a road distance.',
                style: TextStyle(
                  fontSize: 10,
                  height: 1.3,
                  color: AppColors.textFaint,
                ),
              ),
            ],
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: onGetDirections,
                icon: const Icon(Icons.directions_rounded, size: 16),
                label: const Text('Get directions'),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.teal,
                  textStyle: const TextStyle(fontSize: 12),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ),
            const Text(
              'Driving directions open in Google Maps.',
              style: TextStyle(
                fontSize: 10,
                height: 1.3,
                color: AppColors.textFaint,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoPreciseMarkersOverlay extends StatelessWidget {
  const _NoPreciseMarkersOverlay();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 360),
        margin: const EdgeInsets.all(18),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface.withValues(alpha: .94),
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.location_off_outlined, color: AppColors.textFaint),
            SizedBox(height: 8),
            Text(
              'No precise map pins yet',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: AppColors.text,
              ),
            ),
            SizedBox(height: 4),
            Text(
              'Requests without latitude/longitude remain text-only and no fake coordinates are generated.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.35,
                color: AppColors.textDim,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
