import 'dart:async';

import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../widgets/auth_shell.dart';
import '../widgets/auth_visuals.dart';
import 'dispatch_console_page.dart';
import 'responder_readiness_page.dart';

/// One-time ERAS account-complete state used after a newly created Google
/// account is authenticated. Existing Google logins bypass this screen.
class AuthWelcomeScreen extends StatefulWidget {
  const AuthWelcomeScreen({
    super.key,
    this.welcomeEmailDeliveryResult,
  });

  /// `accepted`, `failed`, `unconfigured`, or `not_attempted` from the backend.
  /// This describes the provider request, not final inbox delivery.
  final String? welcomeEmailDeliveryResult;

  @override
  State<AuthWelcomeScreen> createState() => _AuthWelcomeScreenState();
}

class _AuthWelcomeScreenState extends State<AuthWelcomeScreen> {
  Timer? _continueTimer;

  @override
  void initState() {
    super.initState();
    _continueTimer = Timer(const Duration(milliseconds: 1600), _openEras);
  }

  @override
  void dispose() {
    _continueTimer?.cancel();
    super.dispose();
  }

  void _openEras() {
    if (!mounted) return;
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

  String get _firstName {
    final name = ApiService.currentUserName?.trim();
    if (name == null || name.isEmpty) return 'there';
    return name.split(RegExp(r'\s+')).first;
  }

  String? get _emailStatus =>
      switch (widget.welcomeEmailDeliveryResult?.toLowerCase()) {
        'accepted' =>
          'ERAS accepted the welcome email request. Inbox delivery is not confirmed yet.',
        'failed' ||
        'unconfigured' =>
          'Your ERAS account is ready, but the email provider could not accept the welcome message.',
        _ => null,
      };

  @override
  Widget build(BuildContext context) {
    final skin = AuthSkin.of(context);
    return AuthShell(
      child: AuthPanel(
        key: const ValueKey('auth-google-welcome-card'),
        hoverLift: true,
        child: Column(
          key: const ValueKey('auth-google-welcome-state'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: skin.tealDim,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.check_circle_rounded,
                  size: 40,
                  color: skin.teal,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Welcome to ERAS, $_firstName',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 22,
                height: 1.25,
                fontWeight: FontWeight.w800,
                letterSpacing: .3,
                color: skin.text,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Google verified your email. Your ERAS account setup is complete and your account is ready.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13.5,
                height: 1.45,
                color: skin.textDim,
              ),
            ),
            if (_emailStatus != null) ...[
              const SizedBox(height: 10),
              Text(
                _emailStatus!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.4,
                  color: skin.textDim,
                ),
              ),
            ],
            const SizedBox(height: 18),
            Center(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: skin.tealDim,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: skin.teal.withValues(alpha: 0.3)),
                ),
                child: Text(
                  ApiService.currentRole ?? 'REQUESTER',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                    color: skin.teal,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
            TextButton(
              key: const ValueKey('auth-google-welcome-continue'),
              onPressed: _openEras,
              child: const Text('Continue to ERAS'),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(skin.teal),
                  ),
                ),
                const SizedBox(width: 9),
                Text(
                  'Entering ERAS…',
                  style: TextStyle(fontSize: 12, color: skin.textDim),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
