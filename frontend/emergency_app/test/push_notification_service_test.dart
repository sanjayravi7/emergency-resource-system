import 'package:dispatch_console_flutter/services/api_service.dart';
import 'package:dispatch_console_flutter/services/push_notification_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Push registration must be an add-on transport, never a functional
/// requirement: with no Firebase configuration available (unit tests, builds
/// without google-services), registering is a silent no-op and every other
/// feature - Socket.IO plus the compatible-request API - keeps working.
void main() {
  group('PushNotificationService', () {
    setUp(() async {
      // The service is a singleton: reset it so no test depends on the
      // execution order of its siblings.
      await PushNotificationService.instance.stop();
      ApiService.token = null;
      ApiService.currentRole = null;
      ApiService.currentUserId = null;
    });

    test('startForResponder is a silent no-op without a Firebase setup',
        () async {
      ApiService.token = 'responder-token';
      ApiService.currentRole = 'RESPONDER';
      ApiService.currentUserId = 11;
      addTearDown(() {
        ApiService.token = null;
        ApiService.currentRole = null;
        ApiService.currentUserId = null;
      });

      // No Firebase app is configured in the test environment. This must
      // neither throw nor leave a "registered" state behind.
      await PushNotificationService.instance.startForResponder();

      expect(PushNotificationService.instance.isEnabled, isFalse);
      expect(PushNotificationService.instance.registeredToken, isNull);
    });

    test('stop() without a previous registration never throws', () async {
      await PushNotificationService.instance.stop();
      expect(PushNotificationService.instance.isEnabled, isFalse);
    });

    test('non-responders never attempt a registration', () async {
      ApiService.token = 'requester-token';
      ApiService.currentRole = 'REQUESTER';
      ApiService.currentUserId = 5;
      addTearDown(() {
        ApiService.token = null;
        ApiService.currentRole = null;
        ApiService.currentUserId = null;
      });

      await PushNotificationService.instance.startForResponder();
      expect(PushNotificationService.instance.isEnabled, isFalse);
    });

    test('platformLabel describes the client for the backend', () {
      final label = PushNotificationService.platformLabel();
      expect(label, isNotEmpty);
      expect(label, matches(RegExp('^[a-z0-9_]+\$')));
    });
  });
}
