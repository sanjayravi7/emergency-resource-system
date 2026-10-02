import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/api_service.dart';
import '../widgets/auth_motion.dart';
import '../widgets/auth_shell.dart';
import '../widgets/auth_visuals.dart';
import 'login_screen.dart';

/// First-login email verification (email/password accounts only).
///
/// Flow: register -> 6-digit code sent to the ERAS mailbox -> this screen ->
/// code confirmed -> console. Google accounts never reach it: Google already
/// verified the mailbox.
///
/// Copy rules honoured here:
///   * ERAS-branded, never presented as Google/Firebase mail,
///   * the resend action is rate limited by the backend and always answers
///     generically, so it cannot be used to discover registered addresses,
///   * "Refresh status" re-reads the account from the server instead of
///     trusting local state,
///   * the user is never locked out of looking at their own account: signing
///     out is always one tap away and no password is ever asked for again.
class EmailVerificationScreen extends StatefulWidget {
  const EmailVerificationScreen({super.key, this.email});

  /// Optional pre-fill (the address the account was created with).
  final String? email;

  @override
  State<EmailVerificationScreen> createState() =>
      _EmailVerificationScreenState();
}

class _EmailVerificationScreenState extends State<EmailVerificationScreen> {
  final TextEditingController code = TextEditingController();

  bool verifying = false;
  bool refreshing = false;
  bool resending = false;
  String? error;
  String? notice;

  @override
  void dispose() {
    code.dispose();
    super.dispose();
  }

  String get emailLabel =>
      widget.email ?? ApiService.currentUserEmail ?? 'your ERAS email';

  Future<void> verify() async {
    final value = code.text.trim();
    if (value.length != 6 || int.tryParse(value) == null) {
      setState(() => error = 'Enter the 6-digit code from the email.');
      return;
    }

    setState(() {
      verifying = true;
      error = null;
      notice = null;
    });

    try {
      await ApiService.verifyEmail(value);
      if (!mounted) return;
      setState(() => notice = 'Email verified. Welcome to ERAS.');
      _showToast('Email verified');
    } catch (e) {
      if (mounted) {
        setState(() => error = _clean(e));
      }
    } finally {
      if (mounted) setState(() => verifying = false);
    }
  }

  Future<void> resend() async {
    setState(() {
      resending = true;
      error = null;
      notice = null;
    });

    try {
      final response = await ApiService.resendVerification(email: widget.email);
      if (!mounted) return;
      setState(() {
        notice = response['message']?.toString() ??
            'If the address belongs to an ERAS account, a new code is on the '
                'way.';
      });
    } catch (e) {
      if (mounted) setState(() => error = _clean(e));
    } finally {
      if (mounted) setState(() => resending = false);
    }
  }

  Future<void> refreshStatus() async {
    setState(() {
      refreshing = true;
      error = null;
    });

    try {
      await ApiService.fetchMe();
      if (!mounted) return;
      if (ApiService.emailVerified == true) {
        setState(() => notice = 'Your email is verified.');
        _showToast('Email verified');
      } else {
        setState(() =>
            error = 'This email is not verified yet. Check your inbox for the '
                'ERAS code.');
      }
    } catch (e) {
      if (mounted) setState(() => error = _clean(e));
    } finally {
      if (mounted) setState(() => refreshing = false);
    }
  }

  String _clean(Object e) =>
      e.toString().replaceFirst('Exception: ', '').trim();

  void _showToast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(behavior: SnackBarBehavior.floating, content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final skin = AuthSkin.of(context);

    return AuthShell(
      child: AuthPanel(
        key: const ValueKey('auth-verification-card'),
        hoverLift: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  color: skin.tealDim,
                  shape: BoxShape.circle,
                ),
                child: const Center(
                  child: AuthShield(size: 30, outlined: true),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'VERIFY YOUR EMAIL',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 22,
                height: 1.2,
                fontWeight: FontWeight.w800,
                letterSpacing: .4,
                color: skin.text,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'ERAS sent a 6-digit verification code to $emailLabel. '
              'Enter it below to finish setting up your account.',
              textAlign: TextAlign.center,
              style:
                  TextStyle(fontSize: 12.5, height: 1.45, color: skin.textDim),
            ),
            const SizedBox(height: 18),
            FocusGlow(
              glowColor: skin.blue,
              child: TextFormField(
                key: const ValueKey('verification-code'),
                controller: code,
                keyboardType: TextInputType.number,
                inputFormatters: <TextInputFormatter>[
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(6),
                ],
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 8,
                ),
                decoration: authFieldDecoration(
                  context,
                  label: '6-digit code',
                  icon: Icons.password_outlined,
                ),
                onFieldSubmitted: (_) => verify(),
              ),
            ),
            const SizedBox(height: 16),
            AuthPrimaryButton(
              label: 'Verify email',
              onPressed: verifying ? null : verify,
              loading: verifying,
              arrow: true,
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              key: const ValueKey('refresh-verification'),
              onPressed: refreshing ? null : refreshStatus,
              icon: refreshing
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh, size: 16),
              label: const Text('Refresh verification status'),
            ),
            const SizedBox(height: 6),
            TextButton(
              key: const ValueKey('resend-verification'),
              onPressed: resending ? null : resend,
              child: Text(
                resending ? 'Sending…' : 'Resend the code',
                style: TextStyle(fontSize: 12.5, color: skin.blue),
              ),
            ),
            if (notice != null) ..._message(skin.teal, notice!),
            if (error != null) ..._message(skin.red, error!),
            const SizedBox(height: 6),
            const AuthDividerLabel(),
            const SizedBox(height: 12),
            Text(
              'ERAS only asks for this once per account. Google sign-in '
              'accounts are verified by Google and skip this step.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, height: 1.4, color: skin.textDim),
            ),
            const SizedBox(height: 10),
            TextButton(
              key: const ValueKey('verification-sign-out'),
              onPressed: () async {
                await ApiService.logout();
                if (!context.mounted) return;
                Navigator.pushAndRemoveUntil(
                  context,
                  MaterialPageRoute<void>(builder: (_) => const LoginScreen()),
                  (route) => false,
                );
              },
              child: Text(
                'Sign out',
                style: TextStyle(fontSize: 12.5, color: skin.textDim),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _message(Color color, String text) => <Widget>[
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(11),
          decoration: BoxDecoration(
            color: color.withValues(alpha: .1),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: color.withValues(alpha: .2)),
          ),
          child: Text(
            text,
            style: TextStyle(fontSize: 12.5, color: color),
          ),
        ),
      ];
}
