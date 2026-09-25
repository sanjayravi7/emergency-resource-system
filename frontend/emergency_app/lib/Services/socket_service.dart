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

class SocketConnectionState {
  const SocketConnectionState({required this.connected, this.message});

  final bool connected;
  final String? message;
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

  Stream<RealtimeEvent> get events => _events.stream;
  Stream<SocketConnectionState> get connectionStates => _connection.stream;
  bool get isConnected => _socket?.connected == true;

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
          .setReconnectionAttempts(10)
          .setReconnectionDelay(1000)
          .disableAutoConnect()
          .build(),
    );
    _socket = socket;

    socket.onConnect((_) {
      _connection.add(const SocketConnectionState(connected: true));
    });
    socket.onDisconnect((_) {
      _connection.add(const SocketConnectionState(
        connected: false,
        message: 'Socket disconnected; REST resynchronization will run.',
      ));
    });
    socket.onConnectError((error) {
      _connection.add(SocketConnectionState(
        connected: false,
        message: error?.toString(),
      ));
    });

    for (final name in <String>[
      'socket.authenticated',
      'socket.error',
      'request.created',
      'request.updated',
      'allocation.updated',
      'responder.availability',
      'responder.location.start',
      'responder.location.update',
      'responder.location.stop',
    ]) {
      socket.on(name, (dynamic value) {
        final payload = value is Map
            ? Map<String, dynamic>.from(value)
            : <String, dynamic>{'value': value};
        _events.add(RealtimeEvent(name, payload));
      });
    }

    socket.connect();
  }

  /// Stop the current connection and all listeners. A later login starts a
  /// fresh authenticated socket, so an old user's room can never be reused.
  void disconnect() {
    final socket = _socket;
    _socket = null;
    if (socket != null) {
      // Dropping the socket after disconnect also drops its listener graph;
      // the next authenticated session creates one clean socket instance.
      socket.disconnect();
    }
    _connection.add(const SocketConnectionState(connected: false));
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
