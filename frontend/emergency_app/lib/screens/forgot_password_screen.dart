import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/api_service.dart';
import '../services/email_validation.dart';
import '../widgets/auth_motion.dart';
import '../widgets/auth_shell.dart';
import '../widgets/auth_visuals.dart';
import 'login_screen.dart';

/// Forgot password, driven entirely by the backend flow:
///
///   1. request  -> ERAS emails a crypto-random 6-digit code (10 min TTL,
///      single use, hashed at rest, request + attempt rate limited),
///   2. verify   -> the code is checked without consuming it, so the user can
///      go on to choose a new password,
///   3. reset    -> the code is consumed and the password replaced.
///
/// The backend answers generically at every step, so this screen can never be
/// used to discover which addresses have ERAS accounts (an unknown address
/// still reaches step 2 and simply never receives a code).
class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

enum _ResetStep { requestCode, verifyCode, newPassword }

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final TextEditingController email = TextEditingController();
  final TextEditingController code = TextEditingController();
  final TextEditingController password = TextEditingController();
  final TextEditingController confirm = TextEditingController();

  _ResetStep step = _ResetStep.requestCode;
  bool loading = false;
  bool obscurePassword = true;
  String? error;
  String? notice;

  @override
  void dispose() {
    email.dispose();
    code.dispose();
    password.dispose();
    confirm.dispose();
    super.dispose();
  }

  String _clean(Object e) =>
      e.toString().replaceFirst('Exception: ', '').trim();

  Future<void> requestCode() async {
    FocusScope.of(context).unfocus();
    if (!isValidEmail(email.text)) {
      setState(() => error = 'Enter a valid email address');
      return;
    }

    setState(() {
      loading = true;
      error = null;
      notice = null;
    });

    try {
      final response = await ApiService.requestPasswordReset(email.text);
      if (!mounted) return;
      setState(() {
        step = _ResetStep.verifyCode;
        notice = response['message']?.toString() ??
            'If the address belongs to an ERAS account, a reset code is on '
                'the way. It expires in 10 minutes.';
      });
    } catch (e) {
      if (mounted) setState(() => error = _clean(e));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> verifyCode() async {
    FocusScope.of(context).unfocus();
    final value = code.text.trim();
    if (value.length != 6 || int.tryParse(value) == null) {
      setState(() => error = 'Enter the 6-digit code from the email.');
      return;
    }

    setState(() {
      loading = true;
      error = null;
      notice = null;
    });

    try {
      await ApiService.verifyPasswordResetCode(
        email: email.text,
        code: value,
      );
      if (!mounted) return;
      setState(() {
        step = _ResetStep.newPassword;
        notice = 'Code confirmed. Choose a new password.';
      });
    } catch (e) {
      if (mounted) setState(() => error = _clean(e));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> resetPassword() async {
    FocusScope.of(context).unfocus();
    if (password.text.length < 6) {
      setState(() => error = 'Use at least 6 characters');
      return;
    }
    if (password.text != confirm.text) {
      setState(() => error = 'Passwords do not match');
      return;
    }

    setState(() {
      loading = true;
      error = null;
      notice = null;
    });

    try {
      await ApiService.resetPassword(
        email: email.text,
        code: code.text,
        password: password.text,
        confirmPassword: confirm.text,
      );
      if (!mounted) return;
      setState(() {
        step = _ResetStep.requestCode;
        notice = 'Password updated. Sign in with your new password.';
        password.clear();
        confirm.clear();
        code.clear();
      });
    } catch (e) {
      if (mounted) setState(() => error = _clean(e));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final skin = AuthSkin.of(context);

    return AuthShell(
      child: AuthPanel(
        key: const ValueKey('auth-forgot-password-card'),
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
              'RESET YOUR PASSWORD',
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
              _stepDescription,
              textAlign: TextAlign.center,
              style:
                  TextStyle(fontSize: 12.5, height: 1.45, color: skin.textDim),
            ),
            const SizedBox(height: 18),
            if (step == _ResetStep.requestCode) ..._emailStep(skin),
            if (step == _ResetStep.verifyCode) ..._codeStep(skin),
            if (step == _ResetStep.newPassword) ..._passwordStep(skin),
            if (notice != null) ..._message(skin.teal, notice!),
            if (error != null) ..._message(skin.red, error!),
            const SizedBox(height: 14),
            const AuthDividerLabel(),
            const SizedBox(height: 10),
            TextButton(
              key: const ValueKey('back-to-login'),
              onPressed: () => Navigator.pushReplacement(
                context,
                MaterialPageRoute<void>(builder: (_) => const LoginScreen()),
              ),
              child: Text(
                'Back to sign in',
                style: TextStyle(fontSize: 12.5, color: skin.blue),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String get _stepDescription {
    switch (step) {
      case _ResetStep.requestCode:
        return 'Enter the email address of your ERAS account. ERAS emails a '
            '6-digit reset code that expires after 10 minutes.';
      case _ResetStep.verifyCode:
        return 'Enter the 6-digit code ERAS emailed you. Codes are single use '
            'and expire after 10 minutes.';
      case _ResetStep.newPassword:
        return 'Choose a new password for your ERAS account. Signing in with '
            'the old password stops working immediately.';
    }
  }

  List<Widget> _emailStep(AuthSkin skin) => <Widget>[
        FocusGlow(
          glowColor: skin.blue,
          child: TextFormField(
            key: const ValueKey('reset-email'),
            controller: email,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.done,
            decoration: authFieldDecoration(
              context,
              label: 'Email',
              icon: Icons.mail_outline,
            ),
            onFieldSubmitted: (_) => requestCode(),
          ),
        ),
        const SizedBox(height: 16),
        AuthPrimaryButton(
          label: 'Email me a code',
          onPressed: loading ? null : requestCode,
          loading: loading,
          arrow: true,
        ),
      ];

  List<Widget> _codeStep(AuthSkin skin) => <Widget>[
        FocusGlow(
          glowColor: skin.blue,
          child: TextFormField(
            key: const ValueKey('reset-code'),
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
            onFieldSubmitted: (_) => verifyCode(),
          ),
        ),
        const SizedBox(height: 16),
        AuthPrimaryButton(
          label: 'Confirm code',
          onPressed: loading ? null : verifyCode,
          loading: loading,
          arrow: true,
        ),
        const SizedBox(height: 6),
        TextButton(
          key: const ValueKey('resend-reset-code'),
          onPressed: loading ? null : requestCode,
          child: Text(
            'Send a new code',
            style: TextStyle(fontSize: 12.5, color: skin.blue),
          ),
        ),
      ];

  List<Widget> _passwordStep(AuthSkin skin) => <Widget>[
        FocusGlow(
          glowColor: skin.blue,
          child: TextFormField(
            key: const ValueKey('reset-password'),
            controller: password,
            obscureText: obscurePassword,
            textInputAction: TextInputAction.next,
            decoration: authFieldDecoration(
              context,
              label: 'New password',
              icon: Icons.lock_outline,
              helperText: 'At least 6 characters',
              suffixIcon: IconButton(
                tooltip: 'Show or hide password',
                onPressed: () =>
                    setState(() => obscurePassword = !obscurePassword),
                icon: Icon(
                  obscurePassword
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        FocusGlow(
          glowColor: skin.blue,
          child: TextFormField(
            key: const ValueKey('reset-password-confirm'),
            controller: confirm,
            obscureText: obscurePassword,
            textInputAction: TextInputAction.done,
            decoration: authFieldDecoration(
              context,
              label: 'Confirm new password',
              icon: Icons.lock_reset_outlined,
            ),
            onFieldSubmitted: (_) => resetPassword(),
          ),
        ),
        const SizedBox(height: 16),
        AuthPrimaryButton(
          label: 'Update password',
          onPressed: loading ? null : resetPassword,
          loading: loading,
          arrow: true,
        ),
      ];

  List<Widget> _message(Color color, String text) => <Widget>[
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(11),
          decoration: BoxDecoration(
            color: color.withValues(alpha: .1),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: color.withValues(alpha: .2)),
          ),
          child: Text(text, style: TextStyle(fontSize: 12.5, color: color)),
        ),
      ];
}
