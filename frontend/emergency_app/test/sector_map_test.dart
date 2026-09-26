import 'package:dispatch_console_flutter/models/eras_models.dart';
import 'package:dispatch_console_flutter/widgets/sector_map.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('sector map repaints for live-to-last-known transitions only when changed',
      () {
    final updatedAt = DateTime.utc(2026, 9, 26, 10);
    final live = LiveResponderLocation(
      requestId: 1,
      responderId: 2,
      latitude: 10.5,
      longitude: 76.2,
      updatedAt: updatedAt,
    );
    final unchanged = SectorMapPainter(
      districts: const <District>[District('Old Town', Offset(10, 10))],
      responders: const <BackendResponder>[],
      requests: const <EmergencyRequest>[],
      liveLocations: <int, LiveResponderLocation>{1: live},
    );
    final sameSnapshot = SectorMapPainter(
      districts: const <District>[District('Old Town', Offset(10, 10))],
      responders: const <BackendResponder>[],
      requests: const <EmergencyRequest>[],
      liveLocations: <int, LiveResponderLocation>{1: live},
    );
    final staleSnapshot = SectorMapPainter(
      districts: const <District>[District('Old Town', Offset(10, 10))],
      responders: const <BackendResponder>[],
      requests: const <EmergencyRequest>[],
      liveLocations: <int, LiveResponderLocation>{1: live.asNotLive()},
    );

    expect(sameSnapshot.shouldRepaint(unchanged), isFalse);
    expect(staleSnapshot.shouldRepaint(unchanged), isTrue);
  });
}
