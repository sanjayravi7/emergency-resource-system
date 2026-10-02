import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../services/google_auth_service.dart';
import '../widgets/auth_motion.dart';
import '../widgets/auth_shell.dart';
import '../widgets/auth_visuals.dart';
import 'auth_navigation.dart';
import 'email_verification_screen.dart';
import 'password_recovery_screen.dart';
import 'register_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final emailController = TextEditingController(),
      passwordController = TextEditingController();
  bool loading = false,
      success = false,
      obscurePassword = true,
      rememberMe = false;
  String? errorMessage;
  Future<void> login() async {
    FocusScope.of(context).unfocus();
    if (emailController.text.trim().isEmpty ||
        passwordController.text.isEmpty) {
      setState(() => errorMessage = 'Please enter email and password');
      return;
    }
    setState(() {
      loading = true;
      errorMessage = null;
    });
    try {
      await ApiService.login(
          emailController.text.trim(), passwordController.text);
      if (!mounted) return;
      // Purely visual confirmation: the check stays visible on the button
      // while the route transition plays. Navigation is not delayed.
      setState(() => success = true);
      routeAuthenticatedUser(context);
    } catch (error) {
      if (mounted) {
        setState(() =>
            errorMessage = error.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> googleLogin() async {
    if (loading) return;
    setState(() {
      loading = true;
      errorMessage = null;
    });
    try {
      final firebaseIdToken =
          await GoogleAuthService.signInAndGetFirebaseIdToken();
      if (firebaseIdToken == null) return;
      await ApiService.googleAuth(firebaseIdToken, intent: 'login');
      if (!mounted) return;
      setState(() => success = true);
      routeAuthenticatedUser(context);
    } catch (error) {
      await GoogleAuthService.clearProviderSession();
      if (error is GoogleSignInCancelled) return;
      if (mounted) {
        setState(() => errorMessage =
            error.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final skin = AuthSkin.of(context);
    return AuthShell(
        child: AuthPanel(
            key: const ValueKey('auth-login-card'),
            hoverLift: true,
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AuthTabs(
                      registerSelected: false,
                      onLoginTap: () {},
                      onRegisterTap: () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                              builder: (_) => const RegisterScreen()))),
                  const SizedBox(height: 22),
                  Center(
                      child: Container(
                          width: 58,
                          height: 58,
                          decoration: BoxDecoration(
                              color: skin.tealDim, shape: BoxShape.circle),
                          child: const Center(
                              child: AuthShield(size: 30, outlined: true)))),
                  const SizedBox(height: 13),
                  Text('Welcome back!',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 24,
                          height: 1.2,
                          fontWeight: FontWeight.w800,
                          color: skin.text)),
                  const SizedBox(height: 5),
                  Text('Sign in to continue to ERAS',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13, color: skin.textDim)),
                  const SizedBox(height: 24),
                  FocusGlow(
                      key: const ValueKey('login-email-glow'),
                      glowColor: skin.blue,
                      child: TextField(
                          key: const ValueKey('login-email'),
                          controller: emailController,
                          keyboardType: TextInputType.emailAddress,
                          textInputAction: TextInputAction.next,
                          decoration: authFieldDecoration(context,
                              label: 'Email',
                              icon: Icons.mail_outline_rounded))),
                  const SizedBox(height: 13),
                  FocusGlow(
                      key: const ValueKey('login-password-glow'),
                      glowColor: skin.blue,
                      child: TextField(
                          key: const ValueKey('login-password'),
                          controller: passwordController,
                          obscureText: obscurePassword,
                          decoration: authFieldDecoration(context,
                              label: 'Password',
                              icon: Icons.lock_outline_rounded,
                              suffixIcon: IconButton(
                                  tooltip: 'Show or hide password',
                                  onPressed: () => setState(
                                      () => obscurePassword = !obscurePassword),
                                  icon: AnimatedSwap(
                                      child: Icon(
                                          obscurePassword
                                              ? Icons.visibility_outlined
                                              : Icons.visibility_off_outlined,
                                          key: ValueKey(obscurePassword))))),
                          onSubmitted: (_) {
                            if (!loading) login();
                          })),
                  const SizedBox(height: 10),
                  Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Row(mainAxisSize: MainAxisSize.min, children: [
                          TogglePulse(
                              trigger: rememberMe,
                              child: SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: Checkbox(
                                      value: rememberMe,
                                      onChanged: (v) => setState(
                                          () => rememberMe = v ?? false)))),
                          const SizedBox(width: 7),
                          Text('Remember me',
                              style: TextStyle(
                                  fontSize: 12.5, color: skin.textDim)),
                        ]),
                        InkWell(
                            onTap: () => Navigator.push(
                                context,
                                MaterialPageRoute<void>(
                                    builder: (_) => PasswordRecoveryScreen(
                                        initialEmail:
                                            emailController.text.trim()))),
                            borderRadius: BorderRadius.circular(8),
                            child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 4),
                                child: Text('Forgot password?',
                                    style: TextStyle(
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.w700,
                                        color: skin.blue)))),
                      ]),
                  if (errorMessage != null) ...[
                    const SizedBox(height: 10),
                    Container(
                        padding: const EdgeInsets.all(11),
                        decoration: BoxDecoration(
                            color: skin.red.withValues(alpha: .1),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                                color: skin.red.withValues(alpha: .2))),
                        child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(Icons.error_outline,
                                  size: 18, color: skin.red),
                              const SizedBox(width: 8),
                              Expanded(
                                  child: Text(errorMessage!,
                                      style: TextStyle(
                                          fontSize: 12.5, color: skin.red)))
                            ])),
                    if (errorMessage ==
                        'Please verify your email before signing in')
                      TextButton(
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => EmailVerificationScreen(
                              email: emailController.text.trim(),
                            ),
                          ),
                        ),
                        child: const Text('Enter verification code or resend'),
                      ),
                  ],
                  const SizedBox(height: 16),
                  AuthPrimaryButton(
                      label: 'Sign in',
                      onPressed: loading ? null : login,
                      loading: loading,
                      success: success,
                      arrow: true),
                  const SizedBox(height: 20),
                  AuthDividerLabel(),
                  const SizedBox(height: 14),
                  AuthGoogleButton(
                      onPressed: loading ? null : googleLogin),
                ])));
  }
}
