import 'dart:math';

import 'package:flutter/material.dart';

import '../models/eras_models.dart';
import '../theme/app_theme.dart';

/// Sector overview. Districts are display coordinates only; the responders and
/// the requests plotted on them come from PostgreSQL. When real latitude /
/// longitude values are available, the painter projects those received
/// coordinates into the existing sector-map canvas instead of creating a
/// second map system.
class SectorMapPainter extends CustomPainter {
  SectorMapPainter({
    required this.districts,
    required this.responders,
    required this.requests,
    this.liveLocations = const <int, LiveResponderLocation>{},
    this.repaintKey = 0,
  });

  final List<District> districts;
  final List<BackendResponder> responders;
  final List<EmergencyRequest> requests;

  /// Changes only when the data behind the map changed (a request/responder
  /// reload or an accepted live-location update). Socket.IO events that do
  /// not move a marker therefore do not repaint the canvas.
  final int repaintKey;

  /// Active responder telemetry keyed by requestId. The server authorizes and
  /// emits one request room at a time, so a responder serving more than one
  /// emergency is rendered as separate room-scoped points.
  final Map<int, LiveResponderLocation> liveLocations;

  @override
  void paint(Canvas canvas, Size size) {
    final scaleX = size.width / 640;
    final scaleY = size.height / 260;
    final markerScale = max(.8, min(scaleX, scaleY));
    Offset mapPoint(Offset p) => Offset(p.dx * scaleX, p.dy * scaleY);

    final linePaint = Paint()
      ..color = const Color(0xFFC7CEE2).withValues(alpha: .35)
      ..strokeWidth = 1;

    for (var i = 0; i < districts.length; i++) {
      for (var j = i + 1; j < districts.length; j++) {
        canvas.drawLine(
            mapPoint(districts[i].point), mapPoint(districts[j].point), linePaint);
      }
    }

    final textPainter = TextPainter(
        textDirection: TextDirection.ltr, textAlign: TextAlign.center);

    for (final d in districts) {
      final p = mapPoint(d.point);
      canvas.drawCircle(p, 3, Paint()..color = AppColors.textFaint);
      textPainter.text = TextSpan(
          text: d.name, style: monoStyle(size: 9, color: AppColors.textDim));
      textPainter.layout();
      textPainter.paint(
          canvas, Offset(p.dx - textPainter.width / 2, p.dy - 20));
    }

    final openRequests = requests.where((request) => request.isOpen).toList();
    final requestById = <int, EmergencyRequest>{
      for (final request in openRequests) request.id: request,
    };
    final activeLiveLocations = <int, LiveResponderLocation>{
      for (final entry in liveLocations.entries)
        if (requestById.containsKey(entry.key)) entry.key: entry.value,
    };
    final geoProjector = _GeoProjector.from(
      size: size,
      requests: openRequests,
      liveLocations: activeLiveLocations.values,
    );

    // Responders grouped by the district their `location` matches. This keeps
    // the existing map functionality intact for responders that are not
    // actively sharing request-scoped GPS.
    final byDistrict = <String, List<BackendResponder>>{};

    for (final responder in responders) {
      final location = responder.location;
      if (location == null) continue;

      final match = firstWhereOrNull(
        districts,
        (d) => d.name.toLowerCase() == location.toLowerCase(),
      );

      if (match == null) continue;

      byDistrict.putIfAbsent(match.name, () => <BackendResponder>[]).add(responder);
    }

    byDistrict.forEach((name, grouped) {
      final district = firstWhereOrNull(districts, (d) => d.name == name);
      if (district == null) return;

      final base = mapPoint(district.point);

      for (var i = 0; i < grouped.length; i++) {
        final angle = (i / grouped.length) * pi * 2;
        final p = Offset(
          base.dx + cos(angle) * 16 * scaleX,
          base.dy + sin(angle) * 16 * scaleY + 16 * scaleY,
        );

        canvas.drawCircle(
          p,
          4,
          Paint()..color = responderStatusColor(grouped[i].status),
        );
      }
    });

    // Open emergency/request locations. Real DB coordinates are preferred;
    // otherwise the pre-existing sector/district plotting remains unchanged.
    final requestPoints = <int, Offset>{};
    for (final request in openRequests) {
      final point = _requestPoint(request, geoProjector, mapPoint);
      if (point == null) continue;
      requestPoints[request.id] = point;
      _drawEmergencyMarker(canvas, point, request, markerScale);
    }

    // Room-scoped live responder locations. These points are never derived
    // from a district label; they use only the coordinates received from the
    // authenticated Socket.IO event or the throttled PostgreSQL resync value.
    for (final entry in activeLiveLocations.entries) {
      final request = requestById[entry.key];
      final live = entry.value;
      final responderPoint = geoProjector?.project(live.latitude, live.longitude);
      if (request == null || responderPoint == null) continue;

      final emergencyPoint = requestPoints[request.id];
      if (emergencyPoint != null) {
        final linkPaint = Paint()
          ..color = (live.isLive ? AppColors.teal : AppColors.textFaint)
              .withValues(alpha: live.isLive ? .55 : .35)
          ..strokeWidth = live.isLive ? 1.4 : 1.0;

        if (live.isLive) {
          canvas.drawLine(emergencyPoint, responderPoint, linkPaint);
        } else {
          _drawDashedLine(canvas, emergencyPoint, responderPoint, linkPaint);
        }
      }

      _drawResponderMarker(canvas, responderPoint, live, markerScale);
    }
  }

  Offset? _requestPoint(
    EmergencyRequest request,
    _GeoProjector? geoProjector,
    Offset Function(Offset) mapPoint,
  ) {
    if (request.latitude != null && request.longitude != null) {
      final projected = geoProjector?.project(request.latitude!, request.longitude!);
      if (projected != null) return projected;
    }

    final district = firstWhereOrNull(
      districts,
      (d) => d.name.toLowerCase() == request.location.toLowerCase(),
    );

    return district == null ? null : mapPoint(district.point);
  }

  void _drawEmergencyMarker(
    Canvas canvas,
    Offset p,
    EmergencyRequest request,
    double scale,
  ) {
    final color = request.status == RequestStatus.pending
        ? AppColors.amber
        : AppColors.red;
    final radius = 9.0 * scale;

    canvas.drawCircle(
      p,
      radius + 4,
      Paint()..color = color.withValues(alpha: .14),
    );
    canvas.drawCircle(
      p,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = color.withValues(alpha: .75),
    );
    canvas.drawCircle(p, 4.5 * scale, Paint()..color = color);
    _drawMapIcon(canvas, Icons.warning_rounded, p.translate(0, -18 * scale), color,
        14 * scale);

    // The emergency marker is labelled with the request it belongs to, so a
    // map with several open emergencies stays readable.
    final idPainter = TextPainter(
      textDirection: TextDirection.ltr,
      text: TextSpan(
        text: request.displayId,
        style: monoStyle(size: 8.5 * scale, color: color),
      ),
    )..layout();
    idPainter.paint(
      canvas,
      Offset(p.dx - idPainter.width / 2, p.dy + radius + 3 * scale),
    );
  }

  void _drawResponderMarker(
    Canvas canvas,
    Offset p,
    LiveResponderLocation live,
    double scale,
  ) {
    final radius = 10.0 * scale;
    final color = live.isLive ? AppColors.teal : AppColors.textFaint;
    final rect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: p, width: radius * 2.4, height: radius * 2.1),
      Radius.circular(7 * scale),
    );

    if (live.isLive) {
      // Live tracking: solid marker with a halo.
      canvas.drawRRect(
        rect.inflate(5 * scale),
        Paint()..color = color.withValues(alpha: .16),
      );
      canvas.drawRRect(rect, Paint()..color = color);
      _drawMapIcon(canvas, Icons.local_shipping_rounded, p, Colors.white,
          16 * scale);
    } else {
      // Last known position: hollow, outlined marker so a stopped stream can
      // never be mistaken for live tracking.
      canvas.drawRRect(rect, Paint()..color = AppColors.surface);
      canvas.drawRRect(
        rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..color = color,
      );
      _drawMapIcon(canvas, Icons.local_shipping_rounded, p, color, 16 * scale);
    }

    final labelPainter = TextPainter(
      textDirection: TextDirection.ltr,
      text: TextSpan(
        text: live.isLive ? 'LIVE' : 'LAST KNOWN',
        style: monoStyle(size: 8.5 * scale, color: color),
      ),
    )..layout();
    labelPainter.paint(
      canvas,
      Offset(p.dx - labelPainter.width / 2, p.dy + radius + 3 * scale),
    );
  }

  void _drawMapIcon(
    Canvas canvas,
    IconData icon,
    Offset center,
    Color color,
    double size,
  ) {
    final painter = TextPainter(
      textDirection: TextDirection.ltr,
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          color: color,
          fontSize: size,
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
        ),
      ),
    )..layout();

    painter.paint(
      canvas,
      Offset(center.dx - painter.width / 2, center.dy - painter.height / 2),
    );
  }

  /// Dashed connector for a last-known (no longer live) responder point.
  void _drawDashedLine(Canvas canvas, Offset from, Offset to, Paint paint) {
    const dashLength = 5.0;
    const gapLength = 4.0;
    final delta = to - from;
    final distance = delta.distance;
    if (distance <= 0) return;

    final step = delta / distance;
    var travelled = 0.0;
    while (travelled < distance) {
      final end = travelled + dashLength > distance
          ? distance
          : travelled + dashLength;
      canvas.drawLine(
        from + step * travelled,
        from + step * end,
        paint,
      );
      travelled = end + gapLength;
    }
  }

  @override
  bool shouldRepaint(covariant SectorMapPainter old) =>
      old.repaintKey != repaintKey ||
      old.districts.length != districts.length;
}

class _GeoProjector {
  _GeoProjector._({
    required this.size,
    required this.minLatitude,
    required this.maxLatitude,
    required this.minLongitude,
    required this.maxLongitude,
  });

  final Size size;
  final double minLatitude;
  final double maxLatitude;
  final double minLongitude;
  final double maxLongitude;

  static _GeoProjector? from({
    required Size size,
    required Iterable<EmergencyRequest> requests,
    required Iterable<LiveResponderLocation> liveLocations,
  }) {
    final latitudes = <double>[];
    final longitudes = <double>[];

    for (final request in requests) {
      if (request.latitude == null || request.longitude == null) continue;
      latitudes.add(request.latitude!);
      longitudes.add(request.longitude!);
    }

    for (final live in liveLocations) {
      latitudes.add(live.latitude);
      longitudes.add(live.longitude);
    }

    if (latitudes.isEmpty || longitudes.isEmpty) return null;

    var minLatitude = latitudes.reduce(min);
    var maxLatitude = latitudes.reduce(max);
    var minLongitude = longitudes.reduce(min);
    var maxLongitude = longitudes.reduce(max);

    // Degenerate bounds (for example responder and emergency at the same GPS
    // point) still need a viewport. Expanding the viewport does not fabricate a
    // marker coordinate; it only prevents divide-by-zero in the projection.
    if ((maxLatitude - minLatitude).abs() < .0001) {
      minLatitude -= .0001;
      maxLatitude += .0001;
    }
    if ((maxLongitude - minLongitude).abs() < .0001) {
      minLongitude -= .0001;
      maxLongitude += .0001;
    }

    return _GeoProjector._(
      size: size,
      minLatitude: minLatitude,
      maxLatitude: maxLatitude,
      minLongitude: minLongitude,
      maxLongitude: maxLongitude,
    );
  }

  Offset project(double latitude, double longitude) {
    final padding = min(size.width, size.height) * .12;
    final usableWidth = max(1.0, size.width - padding * 2);
    final usableHeight = max(1.0, size.height - padding * 2);
    final longitudeSpan = maxLongitude - minLongitude;
    final latitudeSpan = maxLatitude - minLatitude;

    final x = padding + ((longitude - minLongitude) / longitudeSpan) * usableWidth;
    final y = padding + ((maxLatitude - latitude) / latitudeSpan) * usableHeight;
    return Offset(x.clamp(padding, size.width - padding).toDouble(),
        y.clamp(padding, size.height - padding).toDouble());
  }
}
