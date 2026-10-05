import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show Factory, kIsWeb;
import 'package:flutter/gestures.dart'
    show EagerGestureRecognizer, OneSequenceGestureRecognizer;
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../models/eras_models.dart';
import '../services/location_service.dart';
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

  // Bitmap descriptors are platform objects. Reuse the four static icons
  // instead of allocating a new descriptor for every marker on every GPS
  // update; only the moving marker's position/state changes.
  static final Map<OperationalMapMarkerKind, BitmapDescriptor> _icons =
      <OperationalMapMarkerKind, BitmapDescriptor>{};

  BitmapDescriptor get _icon => _icons.putIfAbsent(
      kind, () => BitmapDescriptor.defaultMarkerWithHue(_hue));

  double get _hue => switch (kind) {
        OperationalMapMarkerKind.activeRequest => BitmapDescriptor.hueRed,
        OperationalMapMarkerKind.pendingRequest => BitmapDescriptor.hueYellow,
        OperationalMapMarkerKind.liveResponder => BitmapDescriptor.hueGreen,
        OperationalMapMarkerKind.lastKnownResponder =>
          BitmapDescriptor.hueAzure,
      };

  Marker toMarker() => Marker(
        markerId: markerId,
        position: position,
        icon: _icon,
        infoWindow: InfoWindow(title: title, snippet: snippet),
      );
}

class OperationalMapMarkerBuilder {
  const OperationalMapMarkerBuilder();

  List<OperationalMapMarkerSnapshot> buildSnapshots({
    required Iterable<EmergencyRequest> requests,
    required Map<int, Map<int, LiveResponderLocation>> liveLocations,
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

    // PHASE F: multiple responders may stream locations for the same
    // request. Every (request, responder) pair renders its own marker with
    // a stable id, so one responder's movement never disturbs another's.
    for (final requestEntry in liveLocations.entries) {
      final request = openRequests[requestEntry.key];
      if (request == null) continue;

      for (final responderEntry in requestEntry.value.entries) {
        final responderId = responderEntry.key;
        final live = responderEntry.value;
        // Missed socket events can leave an old point in memory until REST
        // reconciliation. Never render it unless the authoritative request
        // snapshot still grants this responder a participation leg.
        if (!request.participatesAsResponder(responderId) ||
            !isValidCoordinatePair(live.latitude, live.longitude)) {
          continue;
        }
        final responderName = _responderDisplayName(request, responderId);
        final assignedResources = request.activeAllocations
            .where((allocation) => allocation.responderId == responderId)
            .map((allocation) => allocation.resourceName)
            .toSet()
            .join(', ');

        snapshots.add(
          OperationalMapMarkerSnapshot(
            id: 'responder-${request.id}-$responderId',
            kind: live.isLive
                ? OperationalMapMarkerKind.liveResponder
                : OperationalMapMarkerKind.lastKnownResponder,
            position: LatLng(live.latitude, live.longitude),
            requestId: request.id,
            responderId: responderId,
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
    }

    snapshots.sort((left, right) => left.id.compareTo(right.id));
    return snapshots;
  }

  /// Responder display name: from their assignment summary (multi-responder
  /// snapshots), else the legacy acceptedBy lead, else a stable id label.
  String _responderDisplayName(EmergencyRequest request, int responderId) {
    final assignment = firstWhereOrNull(
      request.activeAssignments,
      (row) => row.responderId == responderId,
    );
    final name = assignment?.responder?.name ??
        (request.acceptedBy?.id == responderId
            ? request.acceptedBy!.name
            : null);
    return name ?? 'Responder #$responderId';
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
///
/// PHASE F: each (request, responder) pair draws its OWN line, so the id is
/// pair-specific (see [directConnectionPolylineIdFor]). The constant remains
/// the pre-multi-responder single-line id for compatibility.
const PolylineId kDirectConnectionPolylineId = PolylineId('direct-connection');

/// Unique per-pair polyline id (`direct-connection-<request>-<responder>`).
PolylineId directConnectionPolylineIdFor(
  int requestId,
  int responderId,
) =>
    PolylineId('direct-connection-$requestId-$responderId');

/// Builds the straight connection line between one responder and the
/// emergency. Local map geometry only — no API request. Multiple responders
/// each get their own line with a unique id.
Polyline buildDirectConnectionPolyline(DirectConnection c, [ErasPalette? p]) {
  final palette = p ?? ErasPalette.light;
  return Polyline(
    polylineId: directConnectionPolylineIdFor(c.requestId, c.responderId),
    points: <LatLng>[
      LatLng(c.responder.latitude, c.responder.longitude),
      LatLng(c.emergency.latitude, c.emergency.longitude),
    ],
    color: palette.blue,
    width: 4,
    patterns: <PatternItem>[PatternItem.dash(18), PatternItem.gap(10)],
  );
}

/// Gestures the operational map claims from the page that scrolls around it.
///
/// The map is an Android/iOS platform view inside the Dispatch Board's
/// scrollable page. A platform view only receives a pointer sequence that no
/// Flutter recognizer claims, and the surrounding `ListView` competes with
/// every drag - so without this set the page won each vertical drag and the
/// map could neither be panned with one finger nor pinched to zoom, while taps
/// (which no parent recognizer claims) still worked. That is exactly the
/// reported symptom: the map rendered, but only taps got through.
///
/// `EagerGestureRecognizer` makes the map claim the sequences that land on it,
/// which restores one-finger pan, pinch zoom, double-tap zoom and marker taps.
/// It is deliberately scoped to the map: the "Center"/"Fit pins" controls and
/// the navigation deck are siblings painted above the map in the same `Stack`,
/// so they keep receiving their own taps, and a drag that starts anywhere
/// outside the map still scrolls the board.
final Set<Factory<OneSequenceGestureRecognizer>>
    operationalMapGestureRecognizers = <Factory<OneSequenceGestureRecognizer>>{
  Factory<OneSequenceGestureRecognizer>(() => EagerGestureRecognizer()),
};

class OperationalGoogleMap extends StatefulWidget {
  const OperationalGoogleMap({
    super.key,
    required this.requests,
    required this.liveLocations,
    this.locationPermissionGranted = false,
    this.onRequestLocationPermission,
    this.isMobile = false,
    this.urlLauncher,
  });

  final List<EmergencyRequest> requests;

  /// Multi-responder live points: requestId -> responderId -> latest point.
  final Map<int, Map<int, LiveResponderLocation>> liveLocations;

  /// Google Maps must not enable its My Location layer until the platform
  /// permission has actually been granted by Geolocator.
  final bool locationPermissionGranted;
  final Future<void> Function()? onRequestLocationPermission;
  final bool isMobile;

  /// Opens the external Google Maps Directions URL. Defaults to the
  /// `url_launcher` adapter; injectable so tests never open Google Maps.
  final ExternalUrlLauncher? urlLauncher;

  @override
  State<OperationalGoogleMap> createState() => _OperationalGoogleMapState();
}

class _OperationalGoogleMapState extends State<OperationalGoogleMap> {
  static const _markerBuilder = OperationalMapMarkerBuilder();
  GoogleMapController? _controller;
  bool _initialCameraApplied = false;
  final Set<String> _autoFittedResponderMarkers = <String>{};

  ExternalUrlLauncher get _launcher =>
      widget.urlLauncher ?? defaultExternalUrlLauncher;

  /// Every responder → emergency pair that may show a connection line.
  /// Recomputed from the current board state on every build, so the lines
  /// follow live GPS updates and disappear as soon as a request is
  /// completed/cancelled, a responder stops, or coordinates vanish.
  List<DirectConnection> get _connections => selectDirectConnections(
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
    final p = ErasPalette.of(context);
    if (kIsWeb && !createLocationService().isAvailable) {
      return _mapsUnavailablePanel(p);
    }

    final snapshots = _snapshots;
    final markers = snapshots.map((snapshot) => snapshot.toMarker()).toSet();
    final textOnlyOpenRequests = _textOnlyOpenRequests;
    final connections = _connections;
    // One straight blue line per valid responder → emergency pair.
    final polylines = <Polyline>{
      for (final connection in connections)
        buildDirectConnectionPolyline(connection, p),
    };

    return LayoutBuilder(
      builder: (context, constraints) {
        final isMobileLayout = widget.isMobile ||
            (constraints.hasBoundedWidth && constraints.maxWidth < 600);

        final mapHeight = isMobileLayout
            ? 340.0
            : math.max(340.0, math.min(460.0, constraints.maxWidth * .38));
        // Platform views must receive a real, non-zero width. The fallback is
        // only for an accidentally unbounded parent; it is never a geographic
        // fallback coordinate.
        final mapWidth = constraints.hasBoundedWidth && constraints.maxWidth > 0
            ? constraints.maxWidth
            : math.max(1.0, MediaQuery.of(context).size.width);

        return SizedBox(
          width: mapWidth,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: mapHeight,
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    bottom: Radius.circular(0),
                  ),
                  child: Stack(
                    children: [
                      if (markers.isNotEmpty)
                        GoogleMap(
                          initialCameraPosition: _initialCamera(snapshots),
                          markers: markers,
                          polylines: polylines,
                          // GESTURE FIX: claim the pointer sequences that land
                          // on the map instead of letting the Dispatch Board's
                          // scroll view win them (see
                          // [operationalMapGestureRecognizers]). Pan, pinch
                          // zoom, double-tap zoom and marker taps all depend
                          // on this; scrolling the page from outside the map
                          // is unaffected.
                          gestureRecognizers: operationalMapGestureRecognizers,
                          mapToolbarEnabled: false,
                          // Never ask the Android Maps SDK for its My Location
                          // layer before Geolocator has granted permission.
                          myLocationEnabled: widget.locationPermissionGranted,
                          myLocationButtonEnabled:
                              widget.locationPermissionGranted,
                          zoomControlsEnabled: !isMobileLayout,
                          compassEnabled: true,
                          onMapCreated: (controller) {
                            _controller = controller;
                            unawaited(_applyInitialCamera());
                          },
                        )
                      else
                        Positioned.fill(
                          child: ColoredBox(
                            color: p.dark ? p.inputFill : p.bg,
                            child: const _NoPreciseMarkersOverlay(),
                          ),
                        ),
                      Positioned(
                        left: 10,
                        right: 10,
                        top: 10,
                        child: isMobileLayout
                            ? Align(
                                alignment: Alignment.topLeft,
                                child: SizedBox(
                                  width: double.infinity,
                                  child: _MapControls(
                                    onCenterEmergency: _centerOnEmergency,
                                    onFitPins:
                                        markers.isEmpty ? null : _fitAllPins,
                                    isMobile: true,
                                  ),
                                ),
                              )
                            : _MapOverlayControls(
                                controls: _MapControls(
                                  onCenterEmergency: _centerOnEmergency,
                                  onFitPins:
                                      markers.isEmpty ? null : _fitAllPins,
                                  isMobile: false,
                                ),
                                navigationDeck: connections.isEmpty
                                    ? null
                                    : NavigationDeck(
                                        connections: connections,
                                        onGetDirections: (connection) =>
                                            unawaited(
                                                _openDirections(connection)),
                                      ),
                              ),
                      ),
                      if (markers.isNotEmpty &&
                          !widget.locationPermissionGranted)
                        Positioned(
                          left: 10,
                          right: 10,
                          bottom: 10,
                          child: _LocationPermissionNotice(
                            onRequest: widget.onRequestLocationPermission,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (isMobileLayout && connections.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                  child: NavigationDeck(
                    connections: connections,
                    isMobile: true,
                    onGetDirections: (connection) =>
                        unawaited(_openDirections(connection)),
                  ),
                ),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  isMobileLayout ? 12 : 16,
                  isMobileLayout ? 10 : 10,
                  isMobileLayout ? 12 : 16,
                  12,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: isMobileLayout ? 8 : 12,
                      runSpacing: isMobileLayout ? 6 : 6,
                      children: [
                        LegendItem(
                          color: p.red,
                          label: 'Active emergency',
                        ),
                        LegendItem(
                          color: p.amber,
                          label: 'Pending request',
                        ),
                        LegendItem(
                          color: p.teal,
                          label: 'LIVE responder',
                        ),
                        LegendItem(
                          color: p.blue,
                          label: 'LAST KNOWN responder',
                        ),
                        if (connections.isNotEmpty)
                          LegendItem(
                            color: p.blue,
                            label: 'Direct connection (straight line)',
                          ),
                      ],
                    ),
                    if (textOnlyOpenRequests.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        '${textOnlyOpenRequests.length} open request${textOnlyOpenRequests.length == 1 ? '' : 's'} '
                        'have text-only locations. Precise map pins are unavailable until GPS coordinates are provided.',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: p.textFaint,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _mapsUnavailablePanel(ErasPalette p) => Container(
        key: const Key('operational-map-unavailable'),
        width: double.infinity,
        height: widget.isMobile ? 340 : 380,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: p.surface2,
          border: Border.all(color: p.border),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.map_outlined, color: p.textFaint, size: 28),
              const SizedBox(height: 10),
              Text(
                'Map is temporarily unavailable. Location data is retained.',
                textAlign: TextAlign.center,
                style: TextStyle(color: p.textDim, fontSize: 13),
              ),
            ],
          ),
        ),
      );

  CameraPosition _initialCamera(List<OperationalMapMarkerSnapshot> snapshots) {
    // GoogleMap is only built when a real request/responder coordinate exists.
    // This assertion prevents a synthetic (0,0) camera from ever becoming a
    // silent substitute for a missing location.
    final focus = _emergencyFocus(snapshots) ?? snapshots.first.position;
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

  Future<void> _centerOnEmergency(
      {bool showMessageWhenUnavailable = true}) async {
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
  Future<void> _openDirections(DirectConnection connection) async {
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

class _MapOverlayControls extends StatelessWidget {
  const _MapOverlayControls({
    required this.controls,
    required this.navigationDeck,
  });

  final Widget controls;
  final Widget? navigationDeck;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return SizedBox(
          width: constraints.hasBoundedWidth ? constraints.maxWidth : null,
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.start,
            spacing: 8,
            runSpacing: 8,
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: constraints.maxWidth),
                child: controls,
              ),
              if (navigationDeck != null)
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: constraints.maxWidth),
                  child: navigationDeck!,
                ),
            ],
          ),
        );
      },
    );
  }
}

/// PHASE F: one navigation card per responder → emergency connection.
///
/// A single connection keeps the familiar card (full-width on mobile,
/// compact on desktop). Several connections render as a horizontally
/// scrollable row of fixed-width cards on every surface:
///
///   * the row is laid out in the cross axis by its content, so a card is
///     never clipped vertically and every "Get directions" button stays
///     fully hit-testable,
///   * the cards scroll horizontally when they do not all fit, which keeps
///     narrow (mobile) viewports overflow-free and lets a large responder
///     count remain reachable on desktop,
///   * the deck always paints above the Google Maps platform view, so the
///     map can never cover a card.
///
/// Straight-line distances and the existing Google Maps URL launcher only -
/// no ETA, no road routes, no routing API.
class NavigationDeck extends StatelessWidget {
  const NavigationDeck({
    super.key,
    required this.connections,
    required this.onGetDirections,
    this.isMobile = false,
  });

  /// Width of one card inside the multi-connection scroller.
  static const double cardWidth = 250;

  /// Gap between two cards inside the multi-connection scroller.
  static const double cardSpacing = 8;

  final List<DirectConnection> connections;
  final void Function(DirectConnection connection) onGetDirections;
  final bool isMobile;

  /// Scroll key of the multi-card deck, so tests (and `Scrollable.of`) can
  /// bring any card into view.
  static const Key scrollableKey = Key('navigation-deck-scroll');

  @override
  Widget build(BuildContext context) {
    if (connections.isEmpty) return const SizedBox.shrink();

    if (connections.length == 1) {
      return NavigationInfoCard(
        connection: connections.single,
        isMobile: isMobile,
        onGetDirections: () => onGetDirections(connections.single),
      );
    }

    return SingleChildScrollView(
      key: scrollableKey,
      scrollDirection: Axis.horizontal,
      // The deck is an overlay/inline strip, never the page scroll view.
      primary: false,
      padding: EdgeInsets.zero,
      // Plain Row (no IntrinsicHeight: NavigationInfoCard uses a
      // LayoutBuilder, which cannot answer intrinsic queries). Every card
      // keeps its natural height, so nothing is ever clipped away.
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (var index = 0; index < connections.length; index++) ...<Widget>[
            if (index > 0) const SizedBox(width: cardSpacing),
            SizedBox(
              width: cardWidth,
              child: NavigationInfoCard(
                connection: connections[index],
                onGetDirections: () => onGetDirections(connections[index]),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _MapControls extends StatelessWidget {
  const _MapControls({
    required this.onCenterEmergency,
    this.onFitPins,
    this.isMobile = false,
  });

  final Future<void> Function() onCenterEmergency;
  final Future<void> Function()? onFitPins;
  final bool isMobile;

  @override
  Widget build(BuildContext context) {
    final p = ErasPalette.of(context);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: p.surface.withValues(alpha: .94),
        border: Border.all(color: p.border),
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            blurRadius: 16,
            offset: const Offset(0, 6),
            color: Colors.black.withValues(alpha: p.dark ? .28 : .08),
          ),
        ],
      ),
      child: Padding(
        padding: EdgeInsets.all(isMobile ? 4 : 6),
        child: Wrap(
          spacing: isMobile ? 4 : 6,
          runSpacing: isMobile ? 4 : 6,
          children: [
            TextButton.icon(
              onPressed: () => unawaited(onCenterEmergency()),
              icon: Icon(
                Icons.emergency_share_rounded,
                size: isMobile ? 15 : 16,
              ),
              label: Text(isMobile ? 'Center' : 'Center on emergency'),
              style: TextButton.styleFrom(
                foregroundColor: p.red,
                textStyle: TextStyle(
                  fontSize: isMobile ? 11.5 : 12,
                  fontWeight: FontWeight.w600,
                ),
                padding: EdgeInsets.symmetric(
                  horizontal: isMobile ? 7 : 8,
                  vertical: isMobile ? 6 : 7,
                ),
                minimumSize: isMobile ? const Size(36, 34) : Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
            TextButton.icon(
              onPressed:
                  onFitPins == null ? null : () => unawaited(onFitPins!()),
              icon: Icon(
                Icons.fit_screen_rounded,
                size: isMobile ? 15 : 16,
              ),
              label: const Text('Fit pins'),
              style: TextButton.styleFrom(
                foregroundColor: p.blue,
                textStyle: TextStyle(
                  fontSize: isMobile ? 11.5 : 12,
                  fontWeight: FontWeight.w600,
                ),
                padding: EdgeInsets.symmetric(
                  horizontal: isMobile ? 7 : 8,
                  vertical: isMobile ? 6 : 7,
                ),
                minimumSize: isMobile ? const Size(36, 34) : Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
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
    this.isMobile = false,
  });

  static const double _compactMaxWidth = 250;

  final DirectConnection connection;
  final VoidCallback onGetDirections;
  final bool showDirectDistance;
  final bool isMobile;

  bool _shouldUseExpandedLayout(
    BuildContext context,
    BoxConstraints constraints,
  ) {
    if (isMobile) return true;
    if (constraints.hasBoundedWidth &&
        constraints.maxWidth < _compactMaxWidth) {
      return true;
    }

    final media = MediaQuery.maybeOf(context);
    if (media == null) return false;

    // A narrow browser/mobile viewport is normally taller than it is wide.
    // Combine that shape with this card's own compact footprint instead of a
    // device breakpoint, so tablet/desktop surfaces keep the compact card.
    return media.size.width < media.size.height &&
        (!constraints.hasBoundedWidth ||
            constraints.maxWidth <= _compactMaxWidth * 2);
  }

  @override
  Widget build(BuildContext context) {
    final p = ErasPalette.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final expandedLayout = _shouldUseExpandedLayout(context, constraints);

        return DecoratedBox(
          decoration: BoxDecoration(
            color: p.surface.withValues(alpha: .94),
            border: Border.all(color: p.border),
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                blurRadius: 16,
                offset: const Offset(0, 4),
                color: Colors.black.withValues(alpha: p.dark ? .26 : .06),
              ),
            ],
          ),
          child: Container(
            width: expandedLayout ? double.infinity : null,
            constraints: expandedLayout
                ? const BoxConstraints()
                : const BoxConstraints(maxWidth: _compactMaxWidth),
            padding: EdgeInsets.fromLTRB(
              expandedLayout ? 12 : 12,
              expandedLayout ? 10 : 10,
              expandedLayout ? 12 : 12,
              expandedLayout ? 10 : 8,
            ),
            child: expandedLayout ? _expandedContent(p) : _compactContent(p),
          ),
        );
      },
    );
  }

  Widget _compactContent(ErasPalette p) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _heading(p),
        const SizedBox(height: 6),
        Text(
          'Responder location: '
          '${connection.responderIsLive ? 'LIVE' : 'LAST KNOWN'}',
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            color: p.text,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          'Emergency location: SET',
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            color: p.text,
          ),
        ),
        if (showDirectDistance) ...[
          const SizedBox(height: 4),
          Text(
            'Direct distance: ${connection.directDistanceLabel}',
            style: TextStyle(
              fontSize: 11.5,
              color: p.textDim,
            ),
          ),
          Text(
            'Straight-line only, not a road distance.',
            style: TextStyle(
              fontSize: 10,
              height: 1.3,
              color: p.textFaint,
            ),
          ),
        ],
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerLeft,
          child: _directionsButton(p, expanded: false),
        ),
        Text(
          'Driving directions open in Google Maps.',
          style: TextStyle(
            fontSize: 10,
            height: 1.3,
            color: p.textFaint,
          ),
        ),
      ],
    );
  }

  Widget _expandedContent(ErasPalette p) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _heading(p),
        const SizedBox(height: 6),
        Divider(height: 1, color: p.border),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _mobileFact(
                p: p,
                label: 'Responder location:',
                value: connection.responderIsLive ? 'LIVE' : 'LAST KNOWN',
                valueColor: connection.responderIsLive ? p.teal : p.blue,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _mobileFact(
                p: p,
                label: 'Emergency location:',
                value: 'SET',
                valueColor: p.red,
              ),
            ),
          ],
        ),
        if (showDirectDistance) ...[
          const SizedBox(height: 6),
          _mobileFact(
            p: p,
            label: 'Direct distance:',
            value: connection.directDistanceLabel,
            helpText: 'Straight-line only, not a road distance',
          ),
        ],
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: _directionsButton(p, expanded: true),
        ),
        const SizedBox(height: 4),
        Text(
          'Driving directions open in Google Maps.',
          style: TextStyle(
            fontSize: 10,
            height: 1.25,
            color: p.textFaint,
          ),
        ),
      ],
    );
  }

  Widget _heading(ErasPalette p) {
    return Text(
      'RESPONDER → EMERGENCY',
      style: TextStyle(
        fontSize: 10.5,
        fontWeight: FontWeight.w800,
        letterSpacing: .8,
        color: p.textDim,
      ),
    );
  }

  Widget _mobileFact({
    required ErasPalette p,
    required String label,
    required String value,
    Color? valueColor,
    String? helpText,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: p.textDim,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w800,
            color: valueColor ?? p.text,
          ),
        ),
        if (helpText != null) ...[
          const SizedBox(height: 1),
          Text(
            helpText,
            style: TextStyle(
              fontSize: 10,
              height: 1.25,
              color: p.textFaint,
            ),
          ),
        ],
      ],
    );
  }

  /// GET DIRECTIONS delegates to the shared [DirectionsButton], which owns the
  /// ERAS primary-accent highlight and the hover/press/disabled states.
  Widget _directionsButton(ErasPalette p, {required bool expanded}) =>
      DirectionsButton(expanded: expanded, onPressed: onGetDirections);
}

/// GET DIRECTIONS, highlighted with the ERAS primary accent (teal).
///
/// The button is a small public widget (not a private method) so the highlight
/// and its hover / press / disabled states are directly testable and reusable.
/// Every color comes from [ErasPalette], so it keeps the accent in both the
/// light theme and the completed dark theme.
class DirectionsButton extends StatelessWidget {
  const DirectionsButton({
    super.key,
    required this.onPressed,
    this.expanded = true,
    this.label = 'Get directions',
  });

  /// Null renders the disabled state.
  final VoidCallback? onPressed;

  /// Filled accent variant (map card) vs. compact tinted variant (marker popup).
  final bool expanded;

  final String label;

  static const Color _onAccentLight = Colors.white;
  static const Color _onAccentDark = Color(0xFF06231F);

  /// Resolves the accent color for the current pointer state.
  ///
  /// Exposed for tests: the states are exactly Material's `hovered`,
  /// `focused`, `pressed` and `disabled`.
  static Color backgroundColorFor(
    ErasPalette p,
    Set<WidgetState> states, {
    required bool expanded,
  }) {
    if (expanded) {
      if (states.contains(WidgetState.disabled)) {
        return p.dark ? p.surface2 : p.tealDim;
      }
      if (states.contains(WidgetState.pressed)) {
        return Color.lerp(p.teal, p.bg, .34)!;
      }
      if (states.contains(WidgetState.hovered) ||
          states.contains(WidgetState.focused)) {
        return Color.lerp(p.teal, p.bg, .18)!;
      }
      return p.teal;
    }

    if (states.contains(WidgetState.disabled)) return Colors.transparent;
    if (states.contains(WidgetState.pressed)) {
      return Color.lerp(p.tealDim, p.teal, .34)!;
    }
    if (states.contains(WidgetState.hovered) ||
        states.contains(WidgetState.focused)) {
      return Color.lerp(p.tealDim, p.teal, .16)!;
    }
    return p.tealDim;
  }

  static Color foregroundColorFor(
    ErasPalette p,
    Set<WidgetState> states, {
    required bool expanded,
  }) {
    if (states.contains(WidgetState.disabled)) return p.textFaint;
    if (expanded) return p.dark ? _onAccentDark : _onAccentLight;
    return p.teal;
  }

  ButtonStyle styleFor(ErasPalette p) {
    return ButtonStyle(
      backgroundColor: WidgetStateProperty.resolveWith(
        (states) => backgroundColorFor(p, states, expanded: expanded),
      ),
      foregroundColor: WidgetStateProperty.resolveWith(
        (states) => foregroundColorFor(p, states, expanded: expanded),
      ),
      iconColor: WidgetStateProperty.resolveWith(
        (states) => foregroundColorFor(p, states, expanded: expanded),
      ),
      overlayColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
      elevation: WidgetStatePropertyAll<double>(expanded ? 1 : 0),
      shadowColor: WidgetStatePropertyAll<Color>(p.teal.withValues(alpha: .35)),
      textStyle: WidgetStatePropertyAll<TextStyle>(
        TextStyle(
          fontSize: expanded ? 13 : 12,
          fontWeight: FontWeight.w800,
          letterSpacing: expanded ? .5 : .2,
        ),
      ),
      padding: WidgetStatePropertyAll<EdgeInsetsGeometry>(
        expanded
            ? const EdgeInsets.symmetric(horizontal: 14, vertical: 12)
            : const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      ),
      minimumSize: WidgetStatePropertyAll<Size>(
        expanded ? const Size.fromHeight(46) : Size.zero,
      ),
      tapTargetSize: expanded
          ? MaterialTapTargetSize.padded
          : MaterialTapTargetSize.shrinkWrap,
      shape: WidgetStatePropertyAll<OutlinedBorder>(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = ErasPalette.of(context);

    return TextButton.icon(
      onPressed: onPressed,
      icon: Icon(Icons.directions_rounded, size: expanded ? 18 : 16),
      label: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      style: styleFor(p),
    );
  }
}

class _LocationPermissionNotice extends StatelessWidget {
  const _LocationPermissionNotice({this.onRequest});

  final Future<void> Function()? onRequest;

  @override
  Widget build(BuildContext context) {
    final p = ErasPalette.of(context);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: p.surface.withValues(alpha: .94),
        border: Border.all(color: p.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        child: Row(
          children: [
            Icon(Icons.location_disabled_outlined, size: 16, color: p.amber),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                'My Location is unavailable until location permission is granted.',
                style: TextStyle(fontSize: 11.5, color: p.textDim),
              ),
            ),
            if (onRequest != null)
              TextButton(
                onPressed: () => unawaited(onRequest!()),
                style: TextButton.styleFrom(
                  foregroundColor: p.teal,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('Allow', style: TextStyle(fontSize: 11.5)),
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
    final p = ErasPalette.of(context);

    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 320),
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: p.surface.withValues(alpha: .94),
          border: Border.all(color: p.border),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.location_off_outlined, color: p.textFaint),
            const SizedBox(height: 6),
            Text(
              'No precise map pins yet',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: p.text,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Requests without latitude/longitude remain text-only and no fake coordinates are generated.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                height: 1.3,
                color: p.textDim,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
