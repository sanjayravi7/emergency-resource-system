import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/api_service.dart';
import '../widgets/auth_shell.dart';
import '../widgets/auth_visuals.dart';

class EmailVerificationScreen extends StatefulWidget {
  const EmailVerificationScreen({super.key, required this.email});

  final String email;

  @override
  State<EmailVerificationScreen> createState() =>
      _EmailVerificationScreenState();
}

class _EmailVerificationScreenState extends State<EmailVerificationScreen> {
  final code = TextEditingController();
  bool loading = false;
  bool resending = false;
  bool verified = false;
  String? error;
  String? notice;

  Future<void> verify() async {
    if (!RegExp(r'^\d{6}$').hasMatch(code.text.trim())) {
      setState(() => error = 'Enter the 6-digit code from your email.');
      return;
    }
    setState(() {
      loading = true;
      error = null;
      notice = null;
    });
    try {
      await ApiService.verifyEmail(widget.email, code.text);
      if (mounted) setState(() => verified = true);
    } catch (e) {
      if (mounted) {
        setState(() => error = e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> resend() async {
    setState(() {
      resending = true;
      error = null;
      notice = null;
    });
    try {
      await ApiService.resendEmailVerification(widget.email);
      if (mounted) {
        setState(() {
          notice =
              'If your account needs verification, a new code has been sent.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => error = e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => resending = false);
    }
  }

  @override
  void dispose() {
    code.dispose();
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
              verified ? 'Email verified' : 'Verify your email',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w800,
                color: skin.text,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              verified
                  ? 'Your ERAS account is ready. Return to sign in.'
                  : 'Enter the 6-digit code sent to ${widget.email}.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: skin.textDim),
            ),
            if (!verified) ...[
              const SizedBox(height: 24),
              TextField(
                controller: code,
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.done,
                maxLength: 6,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: authFieldDecoration(
                  context,
                  label: '6-digit code',
                  icon: Icons.mark_email_read_outlined,
                ),
                onSubmitted: (_) {
                  if (!loading) verify();
                },
              ),
              if (error != null) ...[
                const SizedBox(height: 8),
                Text(error!, style: TextStyle(color: skin.red, fontSize: 13)),
              ],
              if (notice != null) ...[
                const SizedBox(height: 8),
                Text(notice!, style: TextStyle(color: skin.teal, fontSize: 13)),
              ],
              const SizedBox(height: 12),
              AuthPrimaryButton(
                label: 'Verify email',
                onPressed: loading || resending ? null : verify,
                loading: loading,
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: resending || loading ? null : resend,
                child: Text(resending ? 'Sending…' : 'Resend code'),
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
          ],
        ),
      ),
    );
  }
}
