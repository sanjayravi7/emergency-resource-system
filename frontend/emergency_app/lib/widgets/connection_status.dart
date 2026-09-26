import 'package:flutter/material.dart';

import '../Services/socket_service.dart';
import '../theme/app_theme.dart';

/// CONNECTED / RECONNECTING / OFFLINE indicator.
///
/// Intentionally transport agnostic: no socket id, transport name, url or
/// retry counter is ever shown. When the indicator is not CONNECTED the app
/// keeps working through REST (polling + manual refresh), which is what the
/// tooltip explains.
class ConnectionStatusPill extends StatelessWidget {
  const ConnectionStatusPill({
    super.key,
    required this.state,
    this.compact = false,
  });

  final SocketConnectionState state;
  final bool compact;

  Color get _color => switch (state.status) {
        RealtimeStatus.connected => AppColors.teal,
        RealtimeStatus.reconnecting => AppColors.amber,
        RealtimeStatus.offline => AppColors.textFaint,
      };

  Color get _background => switch (state.status) {
        RealtimeStatus.connected => AppColors.tealDim,
        RealtimeStatus.reconnecting => AppColors.amberDim,
        RealtimeStatus.offline => AppColors.surface2,
      };

  IconData get _icon => switch (state.status) {
        RealtimeStatus.connected => Icons.bolt_rounded,
        RealtimeStatus.reconnecting => Icons.sync_rounded,
        RealtimeStatus.offline => Icons.cloud_off_rounded,
      };

  String get _tooltip => switch (state.status) {
        RealtimeStatus.connected => 'Live updates are active.',
        RealtimeStatus.reconnecting =>
          'Reconnecting. The board keeps refreshing from the database.',
        RealtimeStatus.offline =>
          'No live updates. The board still refreshes from the database.',
      };

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: state.message == null ? _tooltip : '$_tooltip\n${state.message}',
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 7 : 9,
          vertical: compact ? 2 : 3,
        ),
        decoration: BoxDecoration(
          color: _background,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_icon, size: compact ? 11 : 12, color: _color),
            const SizedBox(width: 5),
            Text(
              state.label,
              style: monoStyle(
                size: compact ? 9.5 : 10.5,
                color: _color,
                weight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Inline strip shown above the board while realtime is degraded, so the user
/// knows why nothing is moving on its own - and that the data on screen is
/// still real database data.
class ConnectionNotice extends StatelessWidget {
  const ConnectionNotice({super.key, required this.state, this.onRetry});

  final SocketConnectionState state;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    if (!state.isDegraded) return const SizedBox.shrink();

    final reconnecting = state.status == RealtimeStatus.reconnecting;
    final color = reconnecting ? AppColors.amber : AppColors.textDim;
    final background =
        reconnecting ? AppColors.amberDim : AppColors.surface2;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Icon(
            reconnecting ? Icons.sync_rounded : Icons.cloud_off_rounded,
            size: 15,
            color: color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              reconnecting
                  ? 'Reconnecting to live updates. The board still refreshes from the database.'
                  : 'Live updates are offline. The board still refreshes from the database.',
              style: TextStyle(fontSize: 12, color: color),
            ),
          ),
          if (onRetry != null)
            TextButton(
              onPressed: onRetry,
              style: TextButton.styleFrom(
                foregroundColor: color,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 30),
              ),
              child: const Text('Refresh now', style: TextStyle(fontSize: 12)),
            ),
        ],
      ),
    );
  }
}
