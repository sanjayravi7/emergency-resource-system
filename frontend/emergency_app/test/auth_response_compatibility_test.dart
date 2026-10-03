import 'dart:convert';

import 'package:dispatch_console_flutter/services/api_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  setUp(() {
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

  test('reads current nested auth response and first-signup metadata', () {
    final response = <String, dynamic>{
      'success': true,
      'data': <String, dynamic>{
        'token': 'eras-token',
        'isNewUser': true,
        'welcomeEmailDeliveryResult': 'accepted',
        'user': <String, dynamic>{
          'id': 17,
          'name': 'Asha Menon',
          'email': 'asha@example.com',
          'role': 'REQUESTER',
          'emailVerified': true,
        },
      },
    };

    ApiService.applySession(response);

    expect(ApiService.token, 'eras-token');
    expect(ApiService.currentUserId, 17);
    expect(ApiService.currentUserName, 'Asha Menon');
    expect(ApiService.currentUserEmail, 'asha@example.com');
    expect(ApiService.currentRole, 'REQUESTER');
    expect(ApiService.emailVerified, isTrue);
    expect(ApiService.isNewGoogleUser(response), isTrue);
    expect(
      ApiService.authResponseData(response)['welcomeEmailDeliveryResult'],
      'accepted',
    );
  });

  test('reads flat and legacy data.user auth response shapes', () {
    ApiService.applySession(<String, dynamic>{
      'token': 'legacy-token',
      'id': 21,
      'name': 'Legacy User',
      'email': 'legacy@example.com',
      'role': 'RESPONDER',
      'emailVerified': false,
    });

    expect(ApiService.token, 'legacy-token');
    expect(ApiService.currentUserId, 21);
    expect(ApiService.currentUserName, 'Legacy User');
    expect(ApiService.currentUserEmail, 'legacy@example.com');
    expect(ApiService.currentRole, 'RESPONDER');
    expect(ApiService.emailVerified, isFalse);

    ApiService.applySession(<String, dynamic>{
      'data': <String, dynamic>{
        'token': 'flat-data-token',
        'id': 22,
        'name': 'Flat Data User',
        'email': 'flat@example.com',
        'role': 'REQUESTER',
        'emailVerified': true,
      },
    });

    expect(ApiService.token, 'flat-data-token');
    expect(ApiService.currentUserId, 22);
    expect(ApiService.currentUserName, 'Flat Data User');
    expect(ApiService.currentRole, 'REQUESTER');
    expect(ApiService.emailVerified, isTrue);
  });

  test('fetchMe refreshes a flat legacy user response', () async {
    ApiService.token = 'session-token';
    await http.runWithClient(
      () async {
        await ApiService.fetchMe();
        expect(ApiService.currentUserId, 29);
        expect(ApiService.currentUserName, 'Refreshed User');
        expect(ApiService.currentUserEmail, 'refreshed@example.com');
        expect(ApiService.currentRole, 'RESPONDER');
        expect(ApiService.emailVerified, isTrue);
      },
      () => MockClient((request) async {
        expect(request.url.path, '/api/auth/me');
        expect(request.headers['Authorization'], 'Bearer session-token');
        return http.Response(
          jsonEncode(<String, dynamic>{
            'success': true,
            'id': 29,
            'name': 'Refreshed User',
            'email': 'refreshed@example.com',
            'role': 'RESPONDER',
            'emailVerified': true,
          }),
          200,
        );
      }),
    );
  });

  test('existing Google auth response is not treated as first signup', () {
    expect(
      ApiService.isNewGoogleUser(<String, dynamic>{
        'data': <String, dynamic>{
          'isNewUser': false,
          'created': false,
        },
      }),
      isFalse,
    );
  });
}
