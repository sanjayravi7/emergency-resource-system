/// The installable web app must be branded "ERAS Console".
///
/// Chrome reads the install prompt name from `web/manifest.json`
/// (`name`/`short_name`), and the others come from `web/index.html`. These
/// tests read the shipped files directly so a regression (the old
/// `dispatch_console_flutter` placeholder name) fails the build before it can
/// reach the production bundle.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _legacyProductName = 'dispatch_console_flutter';
const String _browserTitle = 'ERAS — Emergency Resource Allocation System';

Map<String, dynamic> _readManifest() =>
    jsonDecode(File('web/manifest.json').readAsStringSync())
        as Map<String, dynamic>;

String _readIndexHtml() => File('web/index.html').readAsStringSync();

void main() {
  group('web manifest', () {
    test('the install prompt shows ERAS Console', () {
      final manifest = _readManifest();

      expect(manifest['name'], 'ERAS Console');
      expect(manifest['short_name'], 'ERAS Console');
      expect(manifest['short_name'], manifest['name']);
      expect('${manifest['name']}', isNot(contains(_legacyProductName)));
      expect('${manifest['description']}', contains('ERAS'));
      expect('${manifest['description']}', isNot(contains(_legacyProductName)));
    });

    test('the existing PWA behaviour is preserved', () {
      final manifest = _readManifest();

      expect(manifest['start_url'], '.');
      expect(manifest['display'], 'standalone');
      expect(manifest['prefer_related_applications'], isFalse);
      expect(manifest['theme_color'], isNotEmpty);
      expect(manifest['background_color'], isNotEmpty);

      final icons = manifest['icons'] as List<dynamic>;
      expect(icons.length, greaterThanOrEqualTo(2));
      for (final icon in icons) {
        final entry = icon as Map<String, dynamic>;
        final src = entry['src'] as String;
        expect(src, isNotEmpty);
        expect(
          File('web/$src').existsSync(),
          isTrue,
          reason: 'manifest icon $src must exist in the build',
        );
      }
    });
  });

  group('index.html', () {
    test('the browser title is the ERAS product name', () {
      final html = _readIndexHtml();

      expect(html, contains('<title>$_browserTitle</title>'));
      expect(html, isNot(contains(_legacyProductName)));
    });

    test('installed-app metadata and branding stay wired up', () {
      final html = _readIndexHtml();

      expect(
        html,
        contains('name="apple-mobile-web-app-title" content="ERAS Console"'),
      );
      expect(html, contains('rel="manifest" href="manifest.json"'));
      expect(html, contains('rel="icon"'));
      expect(html, contains('name="mobile-web-app-capable" content="yes"'));
    });
  });
}
