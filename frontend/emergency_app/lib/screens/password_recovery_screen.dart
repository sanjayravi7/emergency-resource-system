import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/api_service.dart';
import '../widgets/auth_shell.dart';
import '../widgets/auth_visuals.dart';

class PasswordRecoveryScreen extends StatefulWidget {
  const PasswordRecoveryScreen({super.key, this.initialEmail = ''});

  final String initialEmail;

  @override
  State<PasswordRecoveryScreen> createState() => _PasswordRecoveryScreenState();
}

class _PasswordRecoveryScreenState extends State<PasswordRecoveryScreen> {
  late final TextEditingController email;
  final code = TextEditingController();
  final password = TextEditingController();
  final confirmation = TextEditingController();
  bool codeRequested = false;
  bool complete = false;
  bool loading = false;
  bool resending = false;
  String? error;
  String? notice;

  @override
  void initState() {
    super.initState();
    email = TextEditingController(text: widget.initialEmail);
  }

  Future<void> requestCode({bool resend = false}) async {
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email.text.trim())) {
      setState(() => error = 'Enter a valid email address.');
      return;
    }
    setState(() {
      loading = !resend;
      resending = resend;
      error = null;
      notice = null;
    });
    try {
      await ApiService.requestPasswordReset(email.text.trim());
      if (mounted) {
        setState(() {
          codeRequested = true;
          notice =
              'If the account is eligible, a 6-digit reset code has been sent.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => error = e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) {
        setState(() {
          loading = false;
          resending = false;
        });
      }
    }
  }

  Future<void> resetPassword() async {
    if (!RegExp(r'^\d{6}$').hasMatch(code.text.trim())) {
      setState(() => error = 'Enter the 6-digit code from your email.');
      return;
    }
    if (password.text.length < 6) {
      setState(() {
        error = 'Use at least 6 characters for your new password.';
      });
      return;
    }
    if (password.text != confirmation.text) {
      setState(() => error = 'The passwords do not match.');
      return;
    }

    setState(() {
      loading = true;
      error = null;
      notice = null;
    });
    try {
      await ApiService.confirmPasswordReset(
        email: email.text.trim(),
        code: code.text.trim(),
        newPassword: password.text,
      );
      if (mounted) setState(() => complete = true);
    } catch (e) {
      if (mounted) {
        setState(() => error = e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  void dispose() {
    email.dispose();
    code.dispose();
    password.dispose();
    confirmation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final skin = AuthSkin.of(context);
    return AuthShell(
      child: AuthPanel(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const AuthShield(size: 48, outlined: true),
            const SizedBox(height: 18),
            Text(
              complete ? 'Password updated' : 'Reset your password',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w800,
                color: skin.text,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              complete
                  ? 'Your new password is ready. Return to sign in.'
                  : 'We will send a one-time 6-digit code to your email.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: skin.textDim),
            ),
            if (!complete) ...[
              const SizedBox(height: 24),
              TextField(
                controller: email,
                keyboardType: TextInputType.emailAddress,
                enabled: !codeRequested,
                decoration: authFieldDecoration(
                  context,
                  label: 'Email',
                  icon: Icons.mail_outline_rounded,
                ),
              ),
              if (codeRequested) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: code,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: authFieldDecoration(
                    context,
                    label: '6-digit reset code',
                    icon: Icons.password_rounded,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: password,
                  obscureText: true,
                  decoration: authFieldDecoration(
                    context,
                    label: 'New password',
                    icon: Icons.lock_outline_rounded,
                    helperText: 'At least 6 characters',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: confirmation,
                  obscureText: true,
                  decoration: authFieldDecoration(
                    context,
                    label: 'Confirm new password',
                    icon: Icons.lock_reset_outlined,
                  ),
                ),
              ],
              if (error != null) ...[
                const SizedBox(height: 8),
                Text(error!, style: TextStyle(color: skin.red, fontSize: 13)),
              ],
              if (notice != null) ...[
                const SizedBox(height: 8),
                Text(notice!, style: TextStyle(color: skin.teal, fontSize: 13)),
              ],
              const SizedBox(height: 14),
              AuthPrimaryButton(
                label: codeRequested ? 'Reset password' : 'Send reset code',
                onPressed: loading || resending
                    ? null
                    : () {
                        if (codeRequested) {
                          resetPassword();
                        } else {
                          requestCode();
                        }
                      },
                loading: loading,
              ),
              if (codeRequested)
                TextButton(
                  onPressed: resending || loading
                      ? null
                      : () => requestCode(resend: true),
                  child: Text(resending ? 'Sending…' : 'Send a new code'),
                ),
            ] else ...[
              const SizedBox(height: 24),
              AuthPrimaryButton(
                label: 'Back to sign in',
                onPressed: () {
                  Navigator.of(context).maybePop();
                },
              ),
            ],
            const SizedBox(height: 6),
            if (!complete)
              TextButton(
                onPressed: () {
                  Navigator.of(context).maybePop();
                },
                child: const Text('Return to sign in'),
              ),
          ],
        ),
      ),
    );
  }
}
