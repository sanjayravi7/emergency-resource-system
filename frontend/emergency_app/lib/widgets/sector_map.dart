import 'dart:math';

import 'package:flutter/material.dart';

import '../models/eras_models.dart';
import '../theme/app_theme.dart';

/// Sector overview. Districts are display coordinates only; the responders and
/// the requests plotted on them come from PostgreSQL (matched on the
/// `location` column).
class SectorMapPainter extends CustomPainter {
  SectorMapPainter({
    required this.districts,
    required this.responders,
    required this.requests,
  });

  final List<District> districts;
  final List<BackendResponder> responders;
  final List<EmergencyRequest> requests;

  @override
  void paint(Canvas canvas, Size size) {
    final scaleX = size.width / 640;
    final scaleY = size.height / 260;
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

    // Responders grouped by the district their `location` matches.
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

    // Open requests at their location.
    for (final request in requests) {
      if (!request.isOpen) continue;

      final district = firstWhereOrNull(
        districts,
        (d) => d.name.toLowerCase() == request.location.toLowerCase(),
      );

      if (district == null) continue;

      final p = mapPoint(district.point);

      final color = request.status == RequestStatus.pending
          ? AppColors.amber
          : AppColors.blue;

      canvas.drawCircle(
        p,
        9,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = color.withValues(alpha: .6),
      );

      canvas.drawCircle(p, 4, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(covariant SectorMapPainter old) => true;
}
