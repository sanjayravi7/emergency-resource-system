/// RESPONDER CONTACT PRIVACY (security requirement, not a cosmetic one).
///
/// Non-admin roles - REQUESTER and RESPONDER - must never receive a responder's
/// email address or mobile number. The backend enforces this by OMITTING the
/// fields entirely (`backend/src/domain/privacy.js`); these widget tests are the
/// second layer, proving the Flutter surfaces cannot render contact details
/// even if a payload still carried them (defence in depth for direct widget
/// tests and any future serializer mistake).
///
/// ADMIN keeps contact visibility: that is an explicit, documented exception.
/// Visibility is not the same as rendering it in full, though - every surface
/// masks another person's email address through `email_privacy.dart`, so an
/// administrator identifies a responder by name and id, not by their personal
/// address. Phone numbers stay visible because dispatch needs them.
library;

import 'package:dispatch_console_flutter/models/eras_models.dart';
import 'package:dispatch_console_flutter/services/api_service.dart';
import 'package:dispatch_console_flutter/services/email_privacy.dart';
import 'package:dispatch_console_flutter/theme/app_theme.dart';
import 'package:dispatch_console_flutter/widgets/board_panel.dart';
import 'package:dispatch_console_flutter/widgets/resource_panels.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const String _leadPhone = '555-0101';
const String _secondPhone = '555-0102';
const String _responderEmail = 'responder@example.com';

EmergencyRequest _multiResponderRequest() {
  Map<String, dynamic> responder(int id, String name, String phone) =>
      <String, dynamic>{
        'id': id,
        'name': name,
        'phone': phone,
        'email': _responderEmail,
        'responderStatus': 'BUSY',
      };

  return EmergencyRequest.fromJson(<String, dynamic>{
    'id': 42,
    'emergencyType': 'Medical',
    'description': 'Privacy check',
    'location': 'Thrissur, Kerala',
    'priority': 'HIGH',
    'status': 'IN_PROGRESS',
    'createdAt': '2026-09-26T09:00:00.000Z',
    'updatedAt': '2026-09-26T10:00:00.000Z',
    'acceptedAt': '2026-09-26T09:05:00.000Z',
    'requester': <String, dynamic>{
      'id': 5,
      'name': 'Asha Nair',
      // The REQUESTER's own contact is part of the dispatch contract and stays.
      'email': 'asha@example.com',
      'phone': '+919999999999',
    },
    'acceptedBy': responder(9, 'Lead Responder', _leadPhone),
    'assignments': <dynamic>[
      <String, dynamic>{
        'id': 1,
        'requestId': 42,
        'responderId': 9,
        'status': 'ACTIVE',
        'responder': responder(9, 'Lead Responder', _leadPhone),
      },
      <String, dynamic>{
        'id': 2,
        'requestId': 42,
        'responderId': 11,
        'status': 'ACTIVE',
        'responder': responder(11, 'Second Responder', _secondPhone),
      },
    ],
    'allocations': <dynamic>[],
    'requiredResources': <dynamic>[],
  });
}

BackendResponder _responderRow() => BackendResponder.fromJson(<String, dynamic>{
      'id': 9,
      'name': 'Lead Responder',
      'email': _responderEmail,
      'phone': _leadPhone,
      'responderStatus': 'AVAILABLE',
      'isActive': true,
    });

Widget _host(Widget child) => MaterialApp(
      theme: erasTheme(Brightness.light),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void _setRole(String? role) {
  ApiService.token = null;
  ApiService.currentRole = role;
  ApiService.currentUserId = role == 'RESPONDER' ? 9 : 5;
  ApiService.currentUserName = 'Privacy Test';
}

void main() {
  tearDown(() {
    ApiService.token = null;
    ApiService.currentRole = null;
    ApiService.currentUserId = null;
    ApiService.currentUserName = null;
  });

  group('dispatch board', () {
    testWidgets('REQUESTER never sees responder phone numbers', (tester) async {
      tester.view.physicalSize = const Size(1400, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      _setRole('REQUESTER');

      await tester.pumpWidget(_host(BoardPanel(
        title: 'Active emergencies',
        hint: 'Requests being handled',
        requests: <EmergencyRequest>[_multiResponderRequest()],
        role: 'REQUESTER',
        currentUserId: 5,
        emptyMessage: 'No active emergencies',
      )));
      await tester.pump();

      expect(find.text(_leadPhone), findsNothing);
      expect(find.text(_secondPhone), findsNothing);
      expect(find.text(_responderEmail), findsNothing);
      // Responder identity still renders: privacy must not hide who is coming.
      expect(find.text('Lead Responder'), findsWidgets);
      expect(find.text('Second Responder'), findsOneWidget);
      // The requester's own contact is not responder data and stays visible.
      expect(find.text('+919999999999'), findsWidgets);
    });

    testWidgets('RESPONDER never sees another responder phone number',
        (tester) async {
      tester.view.physicalSize = const Size(1400, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      _setRole('RESPONDER');

      await tester.pumpWidget(_host(BoardPanel(
        title: 'My assignments',
        hint: 'Requests being handled',
        requests: <EmergencyRequest>[_multiResponderRequest()],
        role: 'RESPONDER',
        currentUserId: 9,
        emptyMessage: 'No active emergencies',
      )));
      await tester.pump();

      expect(find.text(_leadPhone), findsNothing);
      expect(find.text(_secondPhone), findsNothing);
      expect(find.text('Second Responder'), findsOneWidget);
    });

    testWidgets('ADMIN keeps responder contact details', (tester) async {
      tester.view.physicalSize = const Size(1400, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      _setRole('ADMIN');

      await tester.pumpWidget(_host(BoardPanel(
        title: 'All emergencies',
        hint: 'Requests being handled',
        requests: <EmergencyRequest>[_multiResponderRequest()],
        role: 'ADMIN',
        currentUserId: 1,
        emptyMessage: 'No active emergencies',
      )));
      await tester.pump();

      expect(find.text(_leadPhone), findsOneWidget);
      expect(find.text(_secondPhone), findsOneWidget);
    });
  });

  group('responder directory', () {
    testWidgets('a non-admin directory row has no email or phone',
        (tester) async {
      _setRole('REQUESTER');

      await tester.pumpWidget(_host(BackendRespondersPanel(
        responders: <BackendResponder>[_responderRow()],
        isMobile: false,
      )));
      await tester.pump();

      expect(find.text('Lead Responder  •  ID 9'), findsOneWidget);
      expect(find.text(_responderEmail), findsNothing);
      expect(find.text(_leadPhone), findsNothing);
    });

    testWidgets('the ADMIN directory row masks the email, keeps the phone',
        (tester) async {
      _setRole('ADMIN');

      await tester.pumpWidget(_host(BackendRespondersPanel(
        responders: <BackendResponder>[_responderRow()],
        isMobile: false,
      )));
      await tester.pump();

      // ADMIN is allowed to receive the address, but the directory still shows
      // it partially masked: identification needs the name and the id.
      expect(find.text(_responderEmail), findsNothing);
      expect(find.text(maskEmail(_responderEmail)), findsOneWidget);
      // Operational contact is untouched by email masking.
      expect(find.text(_leadPhone), findsOneWidget);
    });
  });
}
