/// Registration role-selection tests.
///
/// Public registration asks "How would you like to use ERAS?" and offers
/// exactly two options: I NEED HELP (REQUESTER) and I'M WILLING TO HELP
/// (RESPONDER). ADMIN is never a public option, the form cannot be submitted
/// without a selection, and the chosen role is sent to the backend so it is
/// persisted on the User record in PostgreSQL.
library;

import 'dart:convert';
import 'dart:ui' show Tristate;

import 'package:dispatch_console_flutter/screens/email_verification_screen.dart';
import 'package:dispatch_console_flutter/screens/login_screen.dart';
import 'package:dispatch_console_flutter/screens/register_screen.dart';
import 'package:dispatch_console_flutter/services/api_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const ValueKey<String> requesterCardKey = ValueKey<String>(
  'role-card-REQUESTER',
);
const ValueKey<String> responderCardKey = ValueKey<String>(
  'role-card-RESPONDER',
);
const ValueKey<String> requesterSelectedTagKey = ValueKey<String>(
  'role-selected-tag-REQUESTER',
);
const ValueKey<String> responderSelectedTagKey = ValueKey<String>(
  'role-selected-tag-RESPONDER',
);

http.Response _jsonResponse(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

/// Records the registration payload and replies like the real backend
/// (201 + token + user, matching POST /api/auth/register).
class _RecordingApi {
  Map<String, dynamic>? registerBody;
  int registerStatus = 201;
  String? registerErrorMessage;

  MockClient get client => MockClient((request) async {
        if (request.url.path == '/api/auth/register') {
          registerBody = jsonDecode(request.body) as Map<String, dynamic>;
          if (registerStatus != 201) {
            return _jsonResponse(
              {
                'success': false,
                'message': registerErrorMessage ?? 'Registration failed',
              },
              registerStatus,
            );
          }
          return _jsonResponse({
            'success': true,
            'message': 'Registration successful',
            'data': {
              'user': {
                'id': 41,
                'name': registerBody!['name'],
                'email': registerBody!['email'],
                'role': registerBody!['role'],
                'responderStatus': 'OFFLINE',
                // A fresh email/password account is unverified: the backend
                // also returns `verificationRequired: true`.
                'emailVerified': false,
              },
              'verificationRequired': true,
              'verificationCodeIssued': true,
              'emailDelivered': null,
              'emailRequestAccepted': true,
              'emailDeliveryAccepted': true,
              'emailDeliveryConfirmed': false,
              'emailDeliveryStatus': 'accepted',
              'emailDeliveryResult': 'accepted',
              'token': 'test-registration-token',
            },
          }, 201);
        }
        return _jsonResponse({'success': false, 'message': 'Not found'}, 404);
      });
}

Future<void> _fillForm(WidgetTester tester) async {
  await tester.enterText(
    find.widgetWithText(TextFormField, 'Full name'),
    'Role Test User',
  );
  await tester.enterText(
    find.widgetWithText(TextFormField, 'Email'),
    'role.user@example.com',
  );
  await tester.enterText(
    find.widgetWithText(TextFormField, 'Phone number (optional)'),
    '9876543210',
  );
  await tester.enterText(
    find.widgetWithText(TextFormField, 'Password'),
    'Test123456',
  );
  await tester.enterText(
    find.widgetWithText(TextFormField, 'Confirm password'),
    'Test123456',
  );
  await tester.pump();
}

/// Scrolls [finder] into the viewport, then taps it.
///
/// The registration form is taller than the default 800x600 test surface, so
/// the submit button (and, once the page has been scrolled, the role cards)
/// can sit outside the visible area. Tapping such a widget directly derives
/// an offset that hit-tests nothing, which is exactly what a real user avoids
/// by scrolling first.
Future<void> _tapAfterScroll(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
}

Future<void> _submit(WidgetTester tester) async {
  await _tapAfterScroll(tester, find.text('Create account'));
}

void main() {
  setUp(() {
    // Each test starts without a session; registration is what creates one.
    ApiService.token = null;
    ApiService.currentRole = null;
    ApiService.currentUserId = null;
    ApiService.currentUserName = null;
    ApiService.currentUserEmail = null;
    ApiService.emailVerified = null;
  });

  tearDown(() {
    ApiService.token = null;
    ApiService.currentRole = null;
    ApiService.currentUserId = null;
    ApiService.currentUserName = null;
    ApiService.currentUserEmail = null;
    ApiService.emailVerified = null;
  });

  testWidgets('registration page renders with ERAS identity', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: RegisterScreen()));
    await tester.pump();

    expect(find.text('ERAS'), findsOneWidget);
    expect(
      find.text('Emergency Resource Allocation System'),
      findsOneWidget,
    );
    expect(find.text('CREATE ACCOUNT'), findsOneWidget);
    expect(
      find.text('How would you like to use ERAS?'),
      findsOneWidget,
    );
    expect(find.text('Create account'), findsOneWidget);

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
  });

  testWidgets('two role cards are visible', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: RegisterScreen()));
    await tester.pump();

    expect(find.text('I NEED HELP'), findsOneWidget);
    expect(find.text('Request emergency assistance'), findsOneWidget);
    expect(find.text("I'M WILLING TO HELP"), findsOneWidget);
    expect(find.text('Provide emergency assistance'), findsOneWidget);
    expect(find.byKey(requesterCardKey), findsOneWidget);
    expect(find.byKey(responderCardKey), findsOneWidget);

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
  });

  testWidgets('ADMIN is not offered as a public registration option',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: RegisterScreen()));
    await tester.pump();

    expect(find.text('ADMIN'), findsNothing);
    expect(find.text('Admin'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('role-card-ADMIN')),
      findsNothing,
    );
    // Exactly the two public role cards exist.
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget.key is ValueKey<String> &&
            (widget.key as ValueKey<String>).value.startsWith('role-card-'),
      ),
      findsNWidgets(2),
    );

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
  });

  testWidgets('REQUESTER card can be selected', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: RegisterScreen()));
    await tester.pump();

    expect(find.byKey(requesterSelectedTagKey), findsNothing);

    await tester.tap(find.byKey(requesterCardKey));
    await tester.pump();

    expect(find.byKey(requesterSelectedTagKey), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('role-selected-check-REQUESTER')),
      findsOneWidget,
    );
    expect(
      find.text(
        "You'll use ERAS to request emergency resources and assistance.",
      ),
      findsOneWidget,
    );

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
  });

  testWidgets('RESPONDER card can be selected', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: RegisterScreen()));
    await tester.pump();

    expect(find.byKey(responderSelectedTagKey), findsNothing);

    await tester.tap(find.byKey(responderCardKey));
    await tester.pump();

    expect(find.byKey(responderSelectedTagKey), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('role-selected-check-RESPONDER')),
      findsOneWidget,
    );
    expect(
      find.text(
        "You'll use ERAS to receive eligible emergencies and provide assistance.",
      ),
      findsOneWidget,
    );

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
  });

  testWidgets('selecting one role deselects the other (single choice)',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: RegisterScreen()));
    await tester.pump();

    await tester.tap(find.byKey(requesterCardKey));
    await tester.pump();
    expect(find.byKey(requesterSelectedTagKey), findsOneWidget);
    expect(find.byKey(responderSelectedTagKey), findsNothing);

    await tester.tap(find.byKey(responderCardKey));
    await tester.pump();
    expect(find.byKey(requesterSelectedTagKey), findsNothing);
    expect(find.byKey(responderSelectedTagKey), findsOneWidget);

    // The explanation text follows the current selection.
    expect(
      find.text(
        "You'll use ERAS to request emergency resources and assistance.",
      ),
      findsNothing,
    );
    expect(
      find.text(
        "You'll use ERAS to receive eligible emergencies and provide assistance.",
      ),
      findsOneWidget,
    );

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
  });

  testWidgets('role cards expose selected semantics for assistive tech',
      (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(const MaterialApp(home: RegisterScreen()));
    await tester.pump();

    await tester.tap(find.byKey(requesterCardKey));
    await tester.pump();

    final requesterNode = tester.semantics.find(find.byKey(requesterCardKey));
    expect(requesterNode.flagsCollection.isSelected, Tristate.isTrue);

    final responderNode = tester.semantics.find(find.byKey(responderCardKey));
    expect(responderNode.flagsCollection.isSelected, Tristate.isFalse);

    handle.dispose();
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
  });

  testWidgets('registration cannot submit without a role selection',
      (tester) async {
    final api = _RecordingApi();

    await http.runWithClient<Future<void>>(
      () async {
        await tester.pumpWidget(const MaterialApp(home: RegisterScreen()));
        await tester.pump();

        await _fillForm(tester);
        await _submit(tester);
        await tester.pump(const Duration(milliseconds: 200));

        expect(
          find.text('Choose how you want to use ERAS.'),
          findsOneWidget,
        );
        // Nothing was sent to the backend.
        expect(api.registerBody, isNull);
        expect(find.byType(LoginScreen), findsNothing);

        // Selecting a role clears the error.
        await _tapAfterScroll(tester, find.byKey(requesterCardKey));
        expect(
          find.text('Choose how you want to use ERAS.'),
          findsNothing,
        );

        await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      },
      () => api.client,
    );
  });

  testWidgets(
      'REQUESTER registration sends role=REQUESTER and opens the ERAS email '
      'verification step', (tester) async {
    final api = _RecordingApi();

    await http.runWithClient<Future<void>>(
      () async {
        await tester.pumpWidget(const MaterialApp(home: RegisterScreen()));
        await tester.pump();

        await tester.tap(find.byKey(requesterCardKey));
        await tester.pump();
        await _fillForm(tester);
        await _submit(tester);

        // Backend responds 201 with the ERAS session; first-login email
        // verification is the next step for a password account.
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();

        expect(find.byType(EmailVerificationScreen), findsOneWidget);
        expect(find.byType(RegisterScreen), findsNothing);
        expect(find.textContaining('email provider accepted'), findsOneWidget);
        expect(find.textContaining('Delivery may take a few minutes'),
            findsOneWidget);
        expect(find.textContaining('r•••@example.com'), findsOneWidget);
        expect(api.registerBody, isNotNull);
        expect(api.registerBody!['role'], 'REQUESTER');
        expect(api.registerBody!['name'], 'Role Test User');
        expect(api.registerBody!['email'], 'role.user@example.com');
        // The session issued by registration is what verification uses.
        expect(ApiService.token, 'test-registration-token');

        await tester.pumpWidget(const MaterialApp(home: SizedBox()));
        await tester.pump(const Duration(milliseconds: 100));
      },
      () => api.client,
    );
  });

  testWidgets('RESPONDER registration sends role=RESPONDER', (tester) async {
    final api = _RecordingApi();

    await http.runWithClient<Future<void>>(
      () async {
        await tester.pumpWidget(const MaterialApp(home: RegisterScreen()));
        await tester.pump();

        await tester.tap(find.byKey(responderCardKey));
        await tester.pump();
        await _fillForm(tester);
        await _submit(tester);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();

        expect(api.registerBody, isNotNull);
        expect(api.registerBody!['role'], 'RESPONDER');
        // A responder verifies the mailbox before the readiness experience.
        expect(find.byType(EmailVerificationScreen), findsOneWidget);

        await tester.pumpWidget(const MaterialApp(home: SizedBox()));
        await tester.pump(const Duration(milliseconds: 100));
      },
      () => api.client,
    );
  });

  testWidgets('duplicate email shows a friendly message and no second account',
      (tester) async {
    final api = _RecordingApi()
      ..registerStatus = 409
      ..registerErrorMessage = 'Email already registered';

    await http.runWithClient<Future<void>>(
      () async {
        await tester.pumpWidget(const MaterialApp(home: RegisterScreen()));
        await tester.pump();

        await tester.tap(find.byKey(requesterCardKey));
        await tester.pump();
        await _fillForm(tester);
        await _submit(tester);
        await tester.pump(const Duration(milliseconds: 300));

        expect(
          find.text('An account with this email already exists.'),
          findsOneWidget,
        );
        expect(find.byType(LoginScreen), findsNothing);

        await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      },
      () => api.client,
    );
  });

  testWidgets('role cards lay out cleanly across phone and desktop widths',
      (tester) async {
    // The default test surface is 800x600 logical pixels.
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(home: RegisterScreen()));
    await tester.pump();

    // Narrow phones stack the cards; no overflow is thrown.
    expect(tester.takeException(), isNull);
    expect(find.byKey(requesterCardKey), findsOneWidget);
    expect(find.byKey(responderCardKey), findsOneWidget);

    // Selecting still works at narrow width. Current Flutter text metrics
    // place the stacked card just below the 800px fold on this surface
    // (also on unmodified main), so bring it into view first - exactly
    // like a real user would (see _tapAfterScroll).
    await _tapAfterScroll(tester, find.byKey(requesterCardKey));
    expect(find.byKey(requesterSelectedTagKey), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
  });

  testWidgets('role selection is keyboard operable (focus + Enter)',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: RegisterScreen()));
    await tester.pump();

    // Tab until the REQUESTER role card holds keyboard focus.
    bool focusInsideCard() {
      final cardElement = find.byKey(requesterCardKey).evaluate().single;
      FocusableActionDetector? detector;
      cardElement.visitAncestorElements((ancestor) {
        final widget = ancestor.widget;
        if (widget is FocusableActionDetector) {
          detector = widget;
          return false;
        }
        return true;
      });
      return detector?.focusNode?.hasFocus ?? false;
    }

    var guard = 0;
    while (!focusInsideCard() && guard < 25) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      guard++;
    }
    expect(focusInsideCard(), isTrue,
        reason: 'REQUESTER card should be reachable by keyboard traversal');

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(find.byKey(requesterSelectedTagKey), findsOneWidget);

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
  });
}
