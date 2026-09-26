import 'package:flutter/material.dart';

import '../Services/socket_service.dart';
import '../models/eras_models.dart';
import '../theme/app_theme.dart';
import 'common_widgets.dart';
import 'connection_status.dart';

/// AVAILABLE / BUSY exactly as PostgreSQL computed it, with the reason.
///
/// The app never sets this status locally: it renders
/// [ResponderAvailability] which comes from
/// GET /api/responders/me/availability and the authenticated
/// `responder.availability` event.
class ResponderAvailabilityCard extends StatelessWidget {
  const ResponderAvailabilityCard({
    super.key,
    required this.availability,
    required this.connection,
  });

  final ResponderAvailability? availability;
  final SocketConnectionState connection;

  @override
  Widget build(BuildContext context) {
    final current = availability;
    final status = current?.responderStatus ?? 'UNKNOWN';
    final color = switch (status.toUpperCase()) {
      'AVAILABLE' => AppColors.teal,
      'BUSY' => AppColors.blue,
      'OFFLINE' => AppColors.textFaint,
      _ => AppColors.textFaint,
    };

    return Panel(
      title: 'MY AVAILABILITY',
      trailing: ConnectionStatusPill(state: connection, compact: true),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: color.withValues(alpha: .12),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration:
                        BoxDecoration(color: color, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    status.toUpperCase(),
                    style: monoStyle(
                        size: 12, color: color, weight: FontWeight.w700),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    current == null
                        ? 'Loading your availability from the database…'
                        : current.workloadLabel,
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: AppColors.text,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    current == null
                        ? 'Status is always read from the server.'
                        : current.hasUnfinishedWork
                            ? 'You stay BUSY until every reserved or dispatched allocation is delivered.'
                            : 'No reserved or dispatched allocation is waiting on you.',
                    style: const TextStyle(
                        fontSize: 11.5, color: AppColors.textFaint),
                  ),
                  if (current != null && current.hasUnfinishedWork) ...[
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 14,
                      runSpacing: 4,
                      children: [
                        _Counter(
                          label: 'reserved',
                          value: current.reservedAllocations,
                          color: AppColors.amber,
                        ),
                        _Counter(
                          label: 'dispatched',
                          value: current.dispatchedAllocations,
                          color: AppColors.blue,
                        ),
                        _Counter(
                          label: 'active emergencies',
                          value: current.activeRequests,
                          color: AppColors.textDim,
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Counter extends StatelessWidget {
  const _Counter({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$value',
          style: monoStyle(size: 12.5, color: color, weight: FontWeight.w700),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: const TextStyle(fontSize: 11, color: AppColors.textFaint),
        ),
      ],
    );
  }
}

/// Explicit live-location controls for the assigned responder.
///
/// GPS only streams while the responder has pressed Start for an emergency
/// that is still open and assigned to them. Completion, cancellation, logout
/// and a lost realtime connection all stop the stream (the console owns that
/// lifecycle; this panel only renders and triggers it).
class LocationSharingPanel extends StatelessWidget {
  const LocationSharingPanel({
    super.key,
    required this.requests,
    required this.currentUserId,
    required this.sharingRequestId,
    required this.liveLocations,
    required this.connection,
    required this.onStart,
    required this.onStop,
  });

  final List<EmergencyRequest> requests;
  final int? currentUserId;
  final int? sharingRequestId;
  final Map<int, LiveResponderLocation> liveLocations;
  final SocketConnectionState connection;
  final Future<void> Function(EmergencyRequest request) onStart;
  final Future<void> Function(int? requestId) onStop;

  @override
  Widget build(BuildContext context) {
    final assigned = requests
        .where((request) =>
            request.isOpen &&
            request.acceptedBy != null &&
            request.acceptedBy!.id == currentUserId)
        .toList(growable: false);

    return Panel(
      title: 'LIVE LOCATION',
      trailing: ConnectionStatusPill(state: connection, compact: true),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
        child: assigned.isEmpty
            ? const Text(
                'Accept an emergency to share your live location with the requester.',
                style: TextStyle(fontSize: 12.5, color: AppColors.textFaint),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: assigned.map((request) {
                  final live = liveLocations[request.id];
                  final sharing = sharingRequestId == request.id;

                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              request.displayId,
                              style: monoStyle(
                                size: 12.5,
                                color: AppColors.textDim,
                                weight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(width: 8),
                            if (sharing)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: AppColors.tealDim,
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Text(
                                  'SHARING',
                                  style: monoStyle(
                                    size: 9.5,
                                    color: AppColors.teal,
                                    weight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            const Spacer(),
                            sharing
                                ? OutlinedButton.icon(
                                    onPressed: () => onStop(request.id),
                                    icon: const Icon(Icons.location_off_rounded,
                                        size: 14),
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: AppColors.amber,
                                      side: const BorderSide(
                                          color: AppColors.amber),
                                      minimumSize: const Size(0, 32),
                                    ),
                                    label: const Text('Stop Live Location',
                                        style: TextStyle(fontSize: 12)),
                                  )
                                : FilledButton.icon(
                                    onPressed: () => onStart(request),
                                    icon: const Icon(Icons.my_location_rounded,
                                        size: 14),
                                    style: FilledButton.styleFrom(
                                      backgroundColor: AppColors.blue,
                                      minimumSize: const Size(0, 32),
                                    ),
                                    label: const Text('Start Live Location',
                                        style: TextStyle(fontSize: 12)),
                                  ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          live == null
                              ? 'No position shared for this emergency yet.'
                              : '${live.isLive ? 'Live position' : 'Last known position'} · '
                                  '${live.latitude.toStringAsFixed(5)}, ${live.longitude.toStringAsFixed(5)} · '
                                  'updated ${formatRelative(live.updatedAt)}',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: live != null && live.isLive
                                ? AppColors.teal
                                : AppColors.textFaint,
                          ),
                        ),
                        if (sharing && connection.isDegraded)
                          const Padding(
                            padding: EdgeInsets.only(top: 3),
                            child: Text(
                              'Sharing is paused while the live connection is down. It resumes automatically.',
                              style: TextStyle(
                                  fontSize: 11, color: AppColors.amber),
                            ),
                          ),
                      ],
                    ),
                  );
                }).toList(),
              ),
      ),
    );
  }
}
