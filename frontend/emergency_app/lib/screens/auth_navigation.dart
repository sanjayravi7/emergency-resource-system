import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../services/socket_service.dart';
import 'dispatch_console_page.dart';
import 'responder_readiness_page.dart';

void routeAuthenticatedUser(BuildContext context) {
  SocketService.instance.connect();
  if (ApiService.isResponder) {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute<void>(
        builder: (readinessContext) => ResponderReadinessPage(
          onSaved: () {
            Navigator.of(readinessContext).pushReplacement(
              MaterialPageRoute<void>(
                builder: (_) => const DispatchConsolePage(
                  readinessSuccess: true,
                ),
              ),
            );
          },
        ),
      ),
    );
  } else {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute<void>(builder: (_) => const DispatchConsolePage()),
    );
  }
}
