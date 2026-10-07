import 'dart:convert';

import 'package:dispatch_console_flutter/models/eras_models.dart';
import 'package:dispatch_console_flutter/screens/dispatch_console_page.dart';
import 'package:dispatch_console_flutter/services/api_service.dart';
import 'package:dispatch_console_flutter/services/location_service.dart';
import 'package:dispatch_console_flutter/services/socket_service.dart';
import 'package:dispatch_console_flutter/theme/app_theme.dart';
import 'package:dispatch_console_flutter/widgets/admin_user_management_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

Map<String, dynamic> _raviJson({
  bool isActive = true,
  bool deletable = false,
  int total = 12,
  String name = 'Ravi',
  String phone = '9876543210',
}) =>
    <String, dynamic>{
      'id': 8,
      'name': name,
      'email': 'ravi.sensitive@example.com',
      'phone': phone,
      'role': 'RESPONDER',
      'isActive': isActive,
      'responderStatus': 'OFFLINE',
      // These are the exact key names returned by the merged backend.
      'history': <String, dynamic>{
        'requests': total == 0 ? 0 : 4,
        'acceptedRequests': total == 0 ? 0 : 1,
        'responderAssignments': total == 0 ? 0 : 2,
        'allocations': total == 0 ? 0 : 2,
        'responderResources': total == 0 ? 0 : 1,
        'responderHelpTypes': total == 0 ? 0 : 2,
        'total': total,
        'deletable': deletable,
      },
    };

AdminUser _ravi({
  bool isActive = true,
  bool deletable = false,
  int total = 12,
}) =>
    AdminUser.fromJson(_raviJson(
      isActive: isActive,
      deletable: deletable,
      total: total,
    ));

Widget _panelHost(Widget child) => MaterialApp(
      theme: erasTheme(Brightness.light),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void _useDesktopViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1440, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

class _FakeBackend {
  _FakeBackend({
    this.isActive = true,
    this.deletable = false,
    this.deleteConflictsWithHistory = false,
  });

  bool isActive;
  bool deletable;
  bool deleteConflictsWithHistory;
  String name = 'Ravi';
  String phone = '9876543210';
  final List<http.Request> requests = <http.Request>[];

  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    final path = request.url.path;

    if (request.method == 'GET' && path == '/api/users') {
      return _json(<String, dynamic>{
        'success': true,
        'users': <Map<String, dynamic>>[
          _raviJson(
            isActive: isActive,
            deletable: deletable,
            total: deletable ? 0 : 12,
            name: name,
            phone: phone,
          ),
        ],
      });
    }
    if (request.method == 'GET' && path == '/api/resources') {
      return _json(
          <String, dynamic>{'success': true, 'resources': <dynamic>[]});
    }
    if (request.method == 'GET' && path == '/api/resources/availability') {
      return _json(
          <String, dynamic>{'success': true, 'resources': <dynamic>[]});
    }
    if (request.method == 'GET' && path == '/api/admin/requests') {
      return _json(<String, dynamic>{'success': true, 'requests': <dynamic>[]});
    }
    if (request.method == 'GET' && path == '/api/admin/responders') {
      return _json(
          <String, dynamic>{'success': true, 'responders': <dynamic>[]});
    }

    if (request.method == 'PATCH' && path == '/api/users/8') {
      final payload = jsonDecode(request.body) as Map<String, dynamic>;
      name = payload['name'] as String;
      if (payload.containsKey('phone')) phone = payload['phone'] as String;
      return _json(<String, dynamic>{
        'success': true,
        'user': _raviJson(
          isActive: isActive,
          deletable: deletable,
          total: deletable ? 0 : 12,
          name: name,
          phone: phone,
        ),
      });
    }
    if (request.method == 'PATCH' && path == '/api/users/8/deactivate') {
      isActive = false;
      return _json(<String, dynamic>{
        'success': true,
        'user': <String, dynamic>{
          'id': 8,
          'name': name,
          'email': 'ravi.sensitive@example.com',
          'role': 'RESPONDER',
          'isActive': false,
        },
      });
    }
    if (request.method == 'PATCH' && path == '/api/users/8/activate') {
      isActive = true;
      return _json(<String, dynamic>{
        'success': true,
        'user': <String, dynamic>{
          'id': 8,
          'name': name,
          'email': 'ravi.sensitive@example.com',
          'role': 'RESPONDER',
          'isActive': true,
        },
      });
    }
    if (request.method == 'DELETE' && path == '/api/users/8') {
      if (deleteConflictsWithHistory) {
        return _json(<String, dynamic>{
          'success': false,
          'code': 'USER_HAS_HISTORY',
          'message': 'The server found operational history.',
        }, 409);
      }
      return _json(<String, dynamic>{
        'success': true,
        'deletedUserId': 8,
      });
    }

    return _json(<String, dynamic>{'success': true});
  }
}

Widget _console() => MaterialApp(
      theme: erasTheme(Brightness.light),
      home: DispatchConsolePage(
        checkLocationPermission: () async => const LocationPermissionResult(
          status: LocationPermissionStatus.granted,
          message: 'Location is available.',
        ),
        requestLocationPermission: () async => const LocationPermissionResult(
          status: LocationPermissionStatus.granted,
          message: 'Location is available.',
        ),
      ),
    );

Future<void> _openUsers(WidgetTester tester) async {
  await tester.pumpWidget(_console());
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump(const Duration(milliseconds: 350));
  await tester.tap(find.text('Users'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump(const Duration(milliseconds: 350));
  expect(find.byKey(const Key('admin-user-card-8')), findsOneWidget);
}

void _setAdminSession() {
  ApiService.token = 'admin-session';
  ApiService.currentRole = 'ADMIN';
  ApiService.currentUserId = 1;
  ApiService.currentUserName = 'Administrator';
}

void _clearApiState() {
  ApiService.token = null;
  ApiService.currentRole = null;
  ApiService.currentUserId = null;
  ApiService.currentUserName = null;
  ApiService.currentUserEmail = null;
}

void main() {
  setUpAll(SocketService.instance.dispose);
  setUp(_setAdminSession);
  tearDown(_clearApiState);

  group('ADMIN user navigation and model', () {
    test('ADMIN sees a Users navigation item', () {
      expect(
        navItemsForRole('ADMIN').where((item) => item.label == 'Users'),
        hasLength(1),
      );
      expect(
        navItemsForRole('ADMIN')
            .singleWhere((item) => item.label == 'Users')
            .view,
        ConsoleView.users,
      );
    });

    test('REQUESTER does not see a Users navigation item', () {
      expect(navItemsForRole('REQUESTER').any((item) => item.label == 'Users'),
          isFalse);
    });

    test('RESPONDER does not see a Users navigation item', () {
      expect(navItemsForRole('RESPONDER').any((item) => item.label == 'Users'),
          isFalse);
    });

    test('parses the actual backend history keys without exposing secrets', () {
      final user = AdminUser.fromJson(_raviJson());
      expect(user.id, 8);
      expect(user.name, 'Ravi');
      expect(user.role, 'RESPONDER');
      expect(user.isActive, isTrue);
      expect(user.responderStatus, 'OFFLINE');
      expect(user.history.requests, 4);
      expect(user.history.acceptedRequests, 1);
      expect(user.history.responderAssignments, 2);
      expect(user.history.allocations, 2);
      expect(user.history.responderResources, 1);
      expect(user.history.responderHelpTypes, 2);
      expect(user.history.total, 12);
      expect(user.history.deletable, isFalse);
    });
  });

  group('user list presentation', () {
    testWidgets('renders Ravi, ID, role, active state and history count',
        (tester) async {
      await tester.pumpWidget(_panelHost(AdminUserManagementPanel(
        users: <AdminUser>[_ravi()],
        loading: false,
        busyUserIds: const <int>{},
        currentUserId: 1,
        onRefresh: () {},
        onViewDetails: (_) {},
        onEdit: (_) {},
        onChangeActive: (_) {},
        onDelete: (_) {},
      )));
      await tester.pump();

      expect(find.text('Ravi'), findsOneWidget);
      expect(find.text('ID 8'), findsOneWidget);
      expect(find.text('RESPONDER'), findsOneWidget);
      expect(find.text('ACTIVE'), findsOneWidget);
      expect(find.text('OFFLINE'), findsOneWidget);
      expect(find.text('12 historical records'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('masks user email with the existing privacy helper',
        (tester) async {
      await tester.pumpWidget(_panelHost(AdminUserManagementPanel(
        users: <AdminUser>[_ravi()],
        loading: false,
        busyUserIds: const <int>{},
        currentUserId: 1,
        onRefresh: () {},
        onViewDetails: (_) {},
        onEdit: (_) {},
        onChangeActive: (_) {},
        onDelete: (_) {},
      )));
      await tester.pump();

      expect(find.text('r*************@example.com'), findsOneWidget);
      expect(find.text('ravi.sensitive@example.com'), findsNothing);
    });

    testWidgets('hides Delete when backend history.deletable is false',
        (tester) async {
      await tester.pumpWidget(_panelHost(AdminUserManagementPanel(
        users: <AdminUser>[_ravi(deletable: false)],
        loading: false,
        busyUserIds: const <int>{},
        currentUserId: 1,
        onRefresh: () {},
        onViewDetails: (_) {},
        onEdit: (_) {},
        onChangeActive: (_) {},
        onDelete: (_) {},
      )));
      await tester.pump();

      expect(find.byKey(const Key('delete-admin-user-8')), findsNothing);
      expect(find.byKey(const Key('more-admin-user-8')), findsNothing);
      expect(find.text('Delete'), findsNothing);
    });

    testWidgets('Ravi details show every operational count and safe actions',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: erasTheme(Brightness.light),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => AdminUserDetailsDialog(
                  user: _ravi(),
                  canChangeActive: true,
                ),
              ),
              child: const Text('Open details'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('Open details'));
      await tester.pump();

      expect(find.text('Operational history'), findsOneWidget);
      expect(find.text('Emergencies requested'), findsOneWidget);
      expect(find.text('Emergencies accepted'), findsOneWidget);
      expect(find.text('Assignments'), findsOneWidget);
      expect(find.text('Allocations'), findsOneWidget);
      expect(find.text('Inventory'), findsOneWidget);
      expect(find.text('Help types'), findsOneWidget);
      expect(
        find.text(
          'Preserve account — historical ERAS data is linked to this user.',
        ),
        findsOneWidget,
      );
      expect(find.text('Edit name'), findsOneWidget);
      expect(find.text('Deactivate'), findsOneWidget);
      expect(find.text('Delete'), findsNothing);
      await tester.tap(find.text('Close'));
    });
  });

  testWidgets('edit dialog requires a non-empty trimmed full name',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: erasTheme(Brightness.light),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<AdminUserEditValues>(
              context: context,
              builder: (_) => AdminUserEditDialog(user: _ravi()),
            ),
            child: const Text('Edit'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Edit'));
    await tester.pump();
    await tester.enterText(
        find.byKey(const Key('admin-user-name-field')), '   ');
    await tester.tap(find.byKey(const Key('save-admin-user-button')));
    await tester.pump();

    expect(find.text('Full name is required'), findsOneWidget);
    expect(find.byType(AdminUserEditDialog), findsOneWidget);
  });

  testWidgets(
      'editing a user calls PATCH /api/users/:id with only name and phone',
      (tester) async {
    _useDesktopViewport(tester);
    final backend = _FakeBackend();

    await http.runWithClient<Future<void>>(
      () async {
        await _openUsers(tester);
        await tester.tap(find.byKey(const Key('edit-admin-user-8')));
        await tester.pump();
        await tester.enterText(
          find.byKey(const Key('admin-user-name-field')),
          '  Ravi Narayan  ',
        );
        await tester.enterText(
          find.byKey(const Key('admin-user-phone-field')),
          ' 555 0100 ',
        );
        await tester.tap(find.byKey(const Key('save-admin-user-button')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump(const Duration(milliseconds: 400));

        final patch = backend.requests.singleWhere(
          (request) =>
              request.method == 'PATCH' && request.url.path == '/api/users/8',
        );
        expect(
          jsonDecode(patch.body),
          <String, dynamic>{'name': 'Ravi Narayan', 'phone': '555 0100'},
        );
        expect(find.text('User profile updated'), findsOneWidget);
        await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      },
      () => MockClient(backend.handle),
    );
  });

  testWidgets('deactivation requires confirmation and calls the guarded route',
      (tester) async {
    _useDesktopViewport(tester);
    final backend = _FakeBackend(isActive: true);

    await http.runWithClient<Future<void>>(
      () async {
        await _openUsers(tester);
        await tester.tap(find.byKey(const Key('toggle-admin-user-8')));
        await tester.pump();

        expect(find.text('Deactivate this account?'), findsOneWidget);
        expect(
          find.textContaining('no longer be able to sign in or use ERAS'),
          findsOneWidget,
        );
        expect(
          find.textContaining(
              'Emergency and allocation history will be preserved'),
          findsOneWidget,
        );
        expect(
          backend.requests
              .where((request) => request.url.path.endsWith('/deactivate')),
          isEmpty,
        );

        await tester.tap(
          find.byKey(const Key('confirm-deactivate-admin-user-8')),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump(const Duration(milliseconds: 350));

        expect(
          backend.requests.where((request) =>
              request.method == 'PATCH' &&
              request.url.path == '/api/users/8/deactivate'),
          hasLength(1),
        );
        await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      },
      () => MockClient(backend.handle),
    );
  });

  testWidgets('activation requires confirmation and calls the activate route',
      (tester) async {
    _useDesktopViewport(tester);
    final backend = _FakeBackend(isActive: false);

    await http.runWithClient<Future<void>>(
      () async {
        await _openUsers(tester);
        await tester.tap(find.byKey(const Key('toggle-admin-user-8')));
        await tester.pump();

        expect(find.text('Activate this account?'), findsOneWidget);
        expect(
            find.textContaining('sign in and use ERAS again'), findsOneWidget);
        expect(
          backend.requests
              .where((request) => request.url.path.endsWith('/activate')),
          isEmpty,
        );

        await tester
            .tap(find.byKey(const Key('confirm-activate-admin-user-8')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump(const Duration(milliseconds: 350));

        expect(
          backend.requests.where((request) =>
              request.method == 'PATCH' &&
              request.url.path == '/api/users/8/activate'),
          hasLength(1),
        );
        await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      },
      () => MockClient(backend.handle),
    );
  });

  testWidgets('409 USER_HAS_HISTORY shows the safe deactivation message',
      (tester) async {
    _useDesktopViewport(tester);
    final backend = _FakeBackend(
      deletable: true,
      deleteConflictsWithHistory: true,
    );

    await http.runWithClient<Future<void>>(
      () async {
        await _openUsers(tester);
        await tester.tap(find.byKey(const Key('more-admin-user-8')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        await tester.tap(find.byKey(const Key('delete-admin-user-8')));
        await tester.pump();
        expect(find.text('Delete this account?'), findsOneWidget);
        expect(
            find.textContaining(
                'backend will verify the account history again'),
            findsOneWidget);

        await tester.tap(find.byKey(const Key('confirm-delete-admin-user-8')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));

        expect(
          backend.requests.where((request) =>
              request.method == 'DELETE' && request.url.path == '/api/users/8'),
          hasLength(1),
        );
        expect(
          jsonDecode(backend.requests
              .singleWhere((request) => request.method == 'DELETE')
              .body),
          <String, dynamic>{'confirm': true},
        );
        expect(
          find.text(
            'This account cannot be deleted because it has ERAS operational history. '
            'Deactivate it instead.',
          ),
          findsOneWidget,
        );
        expect(find.textContaining('server found operational history'),
            findsNothing);
        await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      },
      () => MockClient(backend.handle),
    );
  });
}
