/// Dispatch-board display labels.
///
/// Operators see a person-facing label ("User 8") on request cards, dialogs,
/// map markers and toasts instead of the internal DB-8 identifier. This is a
/// display-only change: the request id used by the API and PostgreSQL is
/// untouched.
library;

import 'package:dispatch_console_flutter/models/eras_models.dart';
import 'package:flutter_test/flutter_test.dart';

EmergencyRequest _request(int id) => EmergencyRequest.fromJson(
      <String, dynamic>{'id': id, 'status': 'PENDING'},
    );

void main() {
  test('a request is labelled "User <id>" for the operator', () {
    for (final id in <int>[6, 7, 8]) {
      final request = _request(id);
      expect(request.displayId, 'User $id');
      // The identifier itself - what the API and the database use - is
      // unchanged.
      expect(request.id, id);
    }
  });

  test('the internal DB- style label is never shown', () {
    final request = _request(8);
    expect(request.displayId, 'User 8');
    expect(request.displayId, isNot(contains('DB-')));
  });
}
