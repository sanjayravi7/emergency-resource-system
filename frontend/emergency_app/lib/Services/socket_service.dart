import 'dart:async';

import 'package:socket_io_client/socket_io_client.dart' as IO;

import 'api_service.dart';

/// A small typed boundary around Socket.IO. HTTP remains the only path that
/// mutates ERAS state; this service only receives committed snapshots and
/// sends authenticated location telemetry.
class RealtimeEvent {
  const RealtimeEvent(this.name, this.payload);

  final String name;
  final Map<String, dynamic> payload;
}

/// User facing realtime status. Deliberately transport agnostic: the UI shows
/// CONNECTED / RECONNECTING / OFFLINE and never any socket internals such as
/// transport names, socket ids, urls or attempt counters.
enum RealtimeStatus { connected, reconnecting, offline }

class SocketConnectionState {
  const SocketConnectionState({required this.status, this.message});

  static const SocketConnectionState offline =
      SocketConnectionState(status: RealtimeStatus.offline);

  final RealtimeStatus status;

  /// Short, human readable explanation. Never contains socket internals.
  final String? message;

  bool get connected => status == RealtimeStatus.connected;

  String get label => switch (status) {
        RealtimeStatus.connected => 'CONNECTED',
        RealtimeStatus.reconnecting => 'RECONNECTING',
        RealtimeStatus.offline => 'OFFLINE',
      };

  /// Whether REST remains the only usable data path right now.
  bool get isDegraded => status != RealtimeStatus.connected;
}

class SocketService {
  SocketService._();

  static final SocketService instance = SocketService._();

  IO.Socket? _socket;
  final StreamController<RealtimeEvent> _events =
      StreamController<RealtimeEvent>.broadcast();
  final StreamController<SocketConnectionState> _connection =
      StreamController<SocketConnectionState>.broadcast();
  bool _disposed = false;
  int _failedAttempts = 0;
  SocketConnectionState _state = SocketConnectionState.offline;

  static const int _maxReconnectionAttempts = 10;

  static const List<String> _serverEventNames = <String>[
    'socket.authenticated',
    'socket.error',
    'socket.invalidated',
    'request.created',
    'request.updated',
    'allocation.updated',
    'responder.availability',
    'responder.location.start',
    'responder.location.update',
    'responder.location.stop',
  ];

  Stream<RealtimeEvent> get events => _events.stream;
  Stream<SocketConnectionState> get connectionStates => _connection.stream;

  /// Last published connection state, so a freshly built page can render the
  /// indicator before the next transition arrives.
  SocketConnectionState get state => _state;
  RealtimeStatus get status => _state.status;
  bool get isConnected => _socket?.connected == true;

  void _publish(RealtimeStatus status, {String? message}) {
    if (_disposed) return;
    final next = SocketConnectionState(status: status, message: message);
    if (_state.status == next.status && _state.message == next.message) return;
    _state = next;
    _connection.add(next);
  }

  /// Calling connect repeatedly is safe. The page can rebuild or return from
  /// a reconnect without registering duplicate Socket.IO listeners.
  void connect() {
    if (_disposed || ApiService.token == null) return;
    if (_socket != null) {
      if (!_socket!.connected) _socket!.connect();
      return;
    }

    final socket = IO.io(
      _serverUrl(),
      IO.OptionBuilder()
          .setTransports(<String>['websocket'])
          .setAuth(<String, dynamic>{'token': ApiService.token})
          .enableReconnection()
          .setReconnectionAttempts(_maxReconnectionAttempts)
          .setReconnectionDelay(1000)
          .disableAutoConnect()
          .build(),
    );
    _socket = socket;

    socket.onConnect((_) {
      _failedAttempts = 0;
      _publish(RealtimeStatus.connected);
    });
    socket.onDisconnect((_) {
      // Socket.IO retries on its own, so a dropped connection is a
      // "reconnecting" state for the user, not a hard offline state.
      _publish(
        RealtimeStatus.reconnecting,
        message: 'Reconnecting. Live updates paused, data still loads.',
      );
    });
    socket.onConnectError((_) {
      _failedAttempts += 1;
      if (_failedAttempts >= _maxReconnectionAttempts) {
        _publish(
          RealtimeStatus.offline,
          message: 'Working offline from the last loaded data.',
        );
        return;
      }
      _publish(
        RealtimeStatus.reconnecting,
        message: 'Reconnecting. Live updates paused, data still loads.',
      );
    });

    for (final name in _serverEventNames) {
      socket.on(name, (dynamic value) {
        if (_disposed) return;
        final payload = value is Map
            ? Map<String, dynamic>.from(value)
            : <String, dynamic>{'value': value};
        _events.add(RealtimeEvent(name, payload));
      });
    }

    _publish(
      RealtimeStatus.reconnecting,
      message: 'Connecting to live updates.',
    );
    socket.connect();
  }

  /// Stop the current connection and all listeners. A later login starts a
  /// fresh authenticated socket, so an old user's room can never be reused.
  void disconnect() {
    final socket = _socket;
    _socket = null;
    _failedAttempts = 0;
    if (socket != null) {
      // Dropping the socket after disconnect also drops its listener graph;
      // remove our named event handlers first so a forced logout/deactivation
      // cannot leave stale callbacks around if the package delays teardown.
      for (final name in _serverEventNames) {
        socket.off(name);
      }
      socket.disconnect();
    }
    _publish(RealtimeStatus.offline);
  }

  void dispose() {
    _disposed = true;
    disconnect();
    _events.close();
    _connection.close();
  }

  void subscribeToRequest(int requestId) {
    _socket?.emit('request.subscribe', <String, dynamic>{'requestId': requestId});
  }

  void unsubscribeFromRequest(int requestId) {
    _socket
        ?.emit('request.unsubscribe', <String, dynamic>{'requestId': requestId});
  }

  void startLocationSharing(int requestId) {
    _socket?.emit(
      'responder.location.start',
      <String, dynamic>{'requestId': requestId},
    );
  }

  void updateLocation({
    required int requestId,
    required double latitude,
    required double longitude,
  }) {
    _socket?.emit('responder.location.update', <String, dynamic>{
      'requestId': requestId,
      'latitude': latitude,
      'longitude': longitude,
    });
  }

  void stopLocationSharing(int requestId) {
    _socket?.emit(
      'responder.location.stop',
      <String, dynamic>{'requestId': requestId},
    );
  }

  String _serverUrl() {
    final configured = ApiService.baseUrl;
    if (configured.startsWith('http://') || configured.startsWith('https://')) {
      final uri = Uri.parse(configured);
      final path = uri.path.endsWith('/api')
          ? uri.path.substring(0, uri.path.length - 4)
          : uri.path;
      return uri.replace(path: path.isEmpty ? '/' : path).toString();
    }

    // Flutter web uses same-origin relative REST URLs. Socket.IO must be
    // given the browser origin rather than a sandbox-localhost address.
    return Uri.base.origin;
  }
}
