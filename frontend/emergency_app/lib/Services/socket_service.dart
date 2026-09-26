import 'dart:async';

import 'package:socket_io_client/socket_io_client.dart' as io;

import 'api_service.dart';

/// A small typed boundary around Socket.IO. HTTP remains the only path that
/// mutates ERAS state; this service only receives committed snapshots and
/// sends authenticated location telemetry.
class RealtimeEvent {
  const RealtimeEvent(this.name, this.payload);

  final String name;
  final Map<String, dynamic> payload;
}

enum RealtimeConnectionStatus { connected, reconnecting, offline }

class SocketConnectionState {
  const SocketConnectionState({required this.status, this.message});

  final RealtimeConnectionStatus status;
  final String? message;

  bool get connected => status == RealtimeConnectionStatus.connected;

  String get label => switch (status) {
    RealtimeConnectionStatus.connected => 'CONNECTED',
    RealtimeConnectionStatus.reconnecting => 'RECONNECTING',
    RealtimeConnectionStatus.offline => 'OFFLINE',
  };
}

class SocketService {
  SocketService._();

  static final SocketService instance = SocketService._();

  io.Socket? _socket;
  final StreamController<RealtimeEvent> _events =
      StreamController<RealtimeEvent>.broadcast();
  final StreamController<SocketConnectionState> _connection =
      StreamController<SocketConnectionState>.broadcast();
  bool _disposed = false;
  bool _manualDisconnect = false;
  SocketConnectionState _currentConnection = const SocketConnectionState(
    status: RealtimeConnectionStatus.offline,
  );

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
  SocketConnectionState get currentConnection => _currentConnection;
  bool get isConnected => _socket?.connected == true;

  /// Calling connect repeatedly is safe. The singleton retains exactly one
  /// Socket.IO object and therefore one listener graph for the active login.
  void connect() {
    if (_disposed || ApiService.token == null) return;
    _manualDisconnect = false;

    if (_socket != null) {
      if (!_socket!.connected) {
        _setConnection(
          const SocketConnectionState(
            status: RealtimeConnectionStatus.reconnecting,
          ),
        );
        _socket!.connect();
      }
      return;
    }

    _setConnection(
      const SocketConnectionState(
        status: RealtimeConnectionStatus.reconnecting,
      ),
    );

    final socket = io.io(
      _serverUrl(),
      io.OptionBuilder()
          .setTransports(<String>['websocket'])
          .setAuth(<String, dynamic>{'token': ApiService.token})
          // Never reuse a cached Manager from a previous authenticated user.
          .enableForceNew()
          .enableReconnection()
          .setReconnectionAttempts(10)
          .setReconnectionDelay(1000)
          .disableAutoConnect()
          .build(),
    );
    _socket = socket;

    socket.onConnect((_) {
      _setConnection(
        const SocketConnectionState(status: RealtimeConnectionStatus.connected),
      );
    });
    socket.onDisconnect((reason) {
      _setConnection(
        SocketConnectionState(
          status: _manualDisconnect
              ? RealtimeConnectionStatus.offline
              : RealtimeConnectionStatus.reconnecting,
          message: reason?.toString(),
        ),
      );
    });
    socket.onConnectError((error) {
      _setConnection(
        SocketConnectionState(
          status: RealtimeConnectionStatus.reconnecting,
          message: error?.toString(),
        ),
      );
    });
    socket.onReconnectAttempt((_) {
      _setConnection(
        const SocketConnectionState(
          status: RealtimeConnectionStatus.reconnecting,
        ),
      );
    });
    socket.onReconnect((_) {
      _setConnection(
        const SocketConnectionState(status: RealtimeConnectionStatus.connected),
      );
    });
    socket.onReconnectFailed((_) {
      _setConnection(
        const SocketConnectionState(
          status: RealtimeConnectionStatus.offline,
          message:
              'Realtime connection unavailable. REST refresh remains active.',
        ),
      );
    });

    for (final name in _serverEventNames) {
      socket.on(name, (dynamic value) {
        if (_disposed || !identical(_socket, socket)) return;
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
    _manualDisconnect = true;
    final socket = _socket;
    _socket = null;
    if (socket != null) {
      for (final name in _serverEventNames) {
        socket.off(name);
      }
      // dispose() disconnects and removes transport/reconnect listeners too;
      // this prevents listener duplication across logout/login cycles.
      socket.dispose();
    }
    _setConnection(
      const SocketConnectionState(status: RealtimeConnectionStatus.offline),
    );
  }

  void dispose() {
    _disposed = true;
    disconnect();
    _events.close();
    _connection.close();
  }

  void subscribeToRequest(int requestId) {
    if (requestId <= 0) return;
    _socket?.emit('request.subscribe', <String, dynamic>{
      'requestId': requestId,
    });
  }

  void unsubscribeFromRequest(int requestId) {
    if (requestId <= 0) return;
    _socket?.emit('request.unsubscribe', <String, dynamic>{
      'requestId': requestId,
    });
  }

  Future<bool> startLocationSharing(int requestId) async {
    final socket = _socket;
    if (!isConnected || socket == null || requestId <= 0) return false;

    final completer = Completer<bool>();
    socket.emitWithAck(
      'responder.location.start',
      <String, dynamic>{'requestId': requestId},
      ack: (dynamic response) {
        if (completer.isCompleted) return;
        completer.complete(response is Map && response['ok'] == true);
      },
    );
    return completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => false,
    );
  }

  void updateLocation({
    required int requestId,
    required double latitude,
    required double longitude,
  }) {
    if (!isConnected || requestId <= 0) return;
    _socket?.emit('responder.location.update', <String, dynamic>{
      'requestId': requestId,
      'latitude': latitude,
      'longitude': longitude,
    });
  }

  void stopLocationSharing(int requestId) {
    if (!isConnected || requestId <= 0) return;
    _socket?.emit('responder.location.stop', <String, dynamic>{
      'requestId': requestId,
    });
  }

  void _setConnection(SocketConnectionState state) {
    if (_disposed) return;
    if (_currentConnection.status == state.status &&
        _currentConnection.message == state.message) {
      return;
    }
    _currentConnection = state;
    _connection.add(state);
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
