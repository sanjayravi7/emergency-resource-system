/// Thin adapter over the `url_launcher` package.
///
/// This is the single place in ERAS that depends on the package, so widget
/// tests can inject a fake [ExternalUrlLauncher] and never open Google Maps.
library;

import 'package:url_launcher/url_launcher.dart';

import 'direct_connection_service.dart';

class UrlLauncherAdapter implements ExternalUrlLauncher {
  const UrlLauncherAdapter();

  @override
  Future<bool> launch(Uri url) => launchUrl(
        url,
        mode: LaunchMode.externalApplication,
        webOnlyWindowName: '_blank',
      );
}

/// Default launcher used by the operational map.
const ExternalUrlLauncher defaultExternalUrlLauncher = UrlLauncherAdapter();
