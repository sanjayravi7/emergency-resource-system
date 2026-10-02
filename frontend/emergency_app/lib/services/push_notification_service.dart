import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart'
    show debugPrint, defaultTargetPlatform, kIsWeb, visibleForTesting;

import 'api_service.dart';

/// Firebase Cloud Messaging registration for responders.
///
/// Division of labour (mirrors the backend design):
///
///   * Socket.IO stays the realtime channel while the app is connected and in
///     the foreground. This service does NOT handle foreground events.
///   * FCM only covers responders whose app is backgrounded or not currently
///     maintaining a Socket.IO connection. The OS displays the notification
///     the backend sends (title/body), so no client-side display code is
///     needed for that case.
///   * The emergency request row in PostgreSQL remains the source of truth:
///     when the responder opens the app or reconnects, the dispatch console
///     refetches GET /api/requests/compatible, so a missed (or missing) push
///     can never lose a request.
///
/// Every entry point is deliberately defensive: in tests, on builds without a
/// Firebase configuration, on platforms without the plugin, or when the user
/// denies the permission, registration silently becomes a no-op. Push is an
/// add-on transport, never a functional requirement.
class PushNotificationService {
  PushNotificationService._();

  static final PushNotificationService instance = PushNotificationService._();

  /// Optional Web Push VAPID key (--dart-define=ERAS_FCM_VAPID_KEY=...).
  /// When absent on web, registration is skipped: the browser foreground
  /// already receives Socket.IO events, and without a VAPID key the web
  /// token request would fail anyway.
  static const String _webVapidKey = String.fromEnvironment(
    'ERAS_FCM_VAPID_KEY',
  );

  bool _initialized = false;
  bool _enabled = false;
  String? _registeredToken;
  StreamSubscription<String>? _tokenRefreshSubscription;

  /// Whether a working FCM registration exists on this device.
  bool get isEnabled => _enabled;

  /// The FCM token currently registered with the backend, if any.
  String? get registeredToken => _registeredToken;

  /// Whether this platform/build should attempt FCM registration at all.
  ///
  /// Native builds (Android/iOS) always try: a missing Firebase
  /// configuration surfaces as a caught failure inside [startForResponder].
  /// Web only tries when a VAPID key was provided.
  @visibleForTesting
  static bool get isSupportedOnThisPlatform =>
      !kIsWeb || _webVapidKey.isNotEmpty;

  /// Short platform label sent alongside the token (display/debug only).
  @visibleForTesting
  static String platformLabel() {
    if (kIsWeb) return 'web';
    return defaultTargetPlatform.name.toLowerCase();
  }

  /// Best-effort registration for the signed-in responder.
  ///
  /// Never throws: any failure (no Firebase config, missing plugin, denied
  /// permission, backend rejection) simply leaves push disabled while the
  /// rest of the app - including Socket.IO and the compatible-request API -
  /// keeps working unchanged.
  Future<void> startForResponder() async {
    if (_initialized) return;
    if (!ApiService.isResponder || ApiService.token == null) return;
    if (!isSupportedOnThisPlatform) return;

    _initialized = true;

    try {
      if (Firebase.apps.isEmpty) await Firebase.initializeApp();

      final messaging = FirebaseMessaging.instance;
      final permission = await messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      final status = permission.authorizationStatus;
      if (status != AuthorizationStatus.authorized &&
          status != AuthorizationStatus.provisional) {
        return;
      }

      final token = await messaging.getToken(
        vapidKey: kIsWeb && _webVapidKey.isNotEmpty ? _webVapidKey : null,
      );
      if (token == null || token.isEmpty) return;

      await ApiService.registerDeviceToken(token, platform: platformLabel());
      _registeredToken = token;
      _enabled = true;

      // FCM rotates tokens; keep the backend's copy current. A failed
      // refresh leaves the previous registration in place until the next
      // successful one.
      _tokenRefreshSubscription?.cancel();
      _tokenRefreshSubscription = messaging.onTokenRefresh.listen(
        (newToken) async {
          try {
            await ApiService.registerDeviceToken(
              newToken,
              platform: platformLabel(),
            );
            _registeredToken = newToken;
          } catch (error) {
            debugPrint('device token refresh registration failed: $error');
          }
        },
      );
    } catch (error) {
      // A missing Firebase configuration or an unavailable plugin channel
      // (unit tests) lands here. Push stays disabled; nothing else changes.
      debugPrint('push notifications unavailable: $error');
      await _tokenRefreshSubscription?.cancel();
      _tokenRefreshSubscription = null;
    }
  }

  /// Remove this device's registration (responder logout). Best-effort.
  Future<void> stop() async {
    _initialized = false;
    _enabled = false;

    final token = _registeredToken;
    _registeredToken = null;

    await _tokenRefreshSubscription?.cancel();
    _tokenRefreshSubscription = null;

    if (token == null || !ApiService.isResponder || ApiService.token == null) {
      return;
    }

    try {
      await ApiService.unregisterDeviceToken(token);
    } catch (error) {
      // The backend also drops stale tokens (FCM UNREGISTERED reports), so
      // ignoring this failure is safe.
      debugPrint('device token removal failed: $error');
    }
  }
}
