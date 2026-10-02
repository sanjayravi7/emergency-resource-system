/// User-facing wording rules.
///
/// The product copy was explicitly reworded, and the database/implementation
/// vocabulary must not leak back into the interface:
///
///   * "No active request in the database." -> "No active request is available."
///   * "Live request state from PostgreSQL"  -> "Live request state"
///   * "Responders registered in the database" -> "Responders registered"
///   * "Responders loaded from PostgreSQL"   -> "Responders data"
///
/// The first group renders the real widgets so the visible text is asserted,
/// and the second group scans the source as a guard against a phrase coming
/// back in a screen that is expensive to render in a unit test (the dispatch
/// console needs a live backend).
library;

import 'dart:io';

import 'package:dispatch_console_flutter/models/eras_models.dart';
import 'package:dispatch_console_flutter/theme/app_theme.dart';
import 'package:dispatch_console_flutter/widgets/board_panel.dart';
import 'package:dispatch_console_flutter/widgets/resource_panels.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child) => MaterialApp(
      theme: erasTheme(Brightness.light),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

/// Every user-visible Dart source file of the app.
List<File> _libFiles() {
  final dir = Directory('lib');
  return dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.endsWith('.dart'))
      .toList();
}

/// Source lines that contain [needle] in a *string literal* (comments are
/// allowed to talk about PostgreSQL, the UI is not).
List<String> _stringLiteralHits(String needle) {
  final hits = <String>[];
  final pattern = RegExp("['\"][^'\"]*${RegExp.escape(needle)}[^'\"]*['\"]");

  for (final file in _libFiles()) {
    final lines = file.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final trimmed = line.trimLeft();
      if (trimmed.startsWith('//') || trimmed.startsWith('///')) continue;
      if (pattern.hasMatch(line)) {
        hits.add('${file.path}:${i + 1}: $line');
      }
    }
  }
  return hits;
}

void main() {
  group('rendered copy', () {
    testWidgets('an empty board says an active request is not available',
        (tester) async {
      await tester.pumpWidget(_host(BoardPanel(
        title: 'Active emergencies',
        hint: 'Requests being handled',
        requests: const <EmergencyRequest>[],
        role: 'REQUESTER',
        emptyMessage: 'No active request is available.',
      )));
      await tester.pump();

      expect(find.text('No active request is available.'), findsOneWidget);
      expect(find.textContaining('database'), findsNothing);
      expect(find.textContaining('PostgreSQL'), findsNothing);
    });

    testWidgets('the responder directory hint is "Responders data"',
        (tester) async {
      await tester.pumpWidget(_host(const BackendRespondersPanel(
        responders: <BackendResponder>[],
      )));
      await tester.pump();

      expect(find.text('Responders data'), findsOneWidget);
      expect(find.textContaining('PostgreSQL'), findsNothing);
      expect(find.textContaining('in the database'), findsNothing);
    });

    testWidgets('empty resource and responder lists avoid the word database',
        (tester) async {
      await tester.pumpWidget(_host(const ResourceCatalogPanel(
        resources: <BackendResource>[],
        isAdmin: false,
      )));
      await tester.pump();

      expect(find.text('No resources found.'), findsOneWidget);
      expect(find.textContaining('database'), findsNothing);
    });
  });

  group('source guard', () {
    test('no UI string still says "from PostgreSQL"', () {
      expect(_stringLiteralHits('from PostgreSQL'), isEmpty);
    });

    test('no UI string still says "in the database"', () {
      expect(_stringLiteralHits('in the database'), isEmpty);
    });

    test('the dispatch board subtitle and the responders subtitle are updated',
        () {
      final page =
          File('lib/screens/dispatch_console_page.dart').readAsStringSync();
      expect(
        page,
        contains("ConsoleView.board => 'Live request state',"),
      );
      expect(
        page,
        contains("ConsoleView.responders => 'Responders registered',"),
      );
      expect(
        page,
        contains("'No active request is available.'"),
      );
    });

    test('no UI string mentions a stale "No active request in the database"',
        () {
      expect(
        _stringLiteralHits('No active request in the database'),
        isEmpty,
      );
    });
  });
}
