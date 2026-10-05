import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../services/client_error_reporting.dart';
import '../services/email_validation.dart';
import '../services/google_auth_service.dart';
import '../services/session_persistence.dart';
import '../services/socket_service.dart';
import '../widgets/auth_motion.dart';
import '../widgets/auth_shell.dart';
import '../widgets/auth_visuals.dart';
import 'auth_welcome_screen.dart';
import 'dispatch_console_page.dart';
import 'email_verification_screen.dart';
import 'forgot_password_screen.dart';
import 'register_screen.dart';
import 'responder_readiness_page.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final emailController = TextEditingController(),
      passwordController = TextEditingController();
  final FocusNode emailFocusNode = FocusNode(debugLabel: 'login-email');
  final FocusNode passwordFocusNode = FocusNode(debugLabel: 'login-password');
  bool loading = false,
      success = false,
      obscurePassword = true,
      rememberMe = false;
  String? errorMessage;

  /// Neutral, non-error feedback (for example while a Google redirect starts).
  String? statusMessage;

  @override
  void initState() {
    super.initState();
    // The stored "Remember me" choice drives the checkbox, so the control
    // never disagrees with the session that is actually remembered.
    _restoreRememberChoice();
    // Flutter Web: a Google redirect return - or a browser refresh after a
    // completed Google sign-in - is resumed here, without another popup.
    // Everywhere else only a remembered session can be restored.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _restoreSessionOnStart();
    });
  }

  /// Reads the stored remember-me preference into the checkbox state.
  Future<void> _restoreRememberChoice() async {
    final remembered = await SessionPersistence.readRememberPreference();
    if (!mounted || !remembered) return;
    setState(() => rememberMe = true);
  }

  /// Start-up authentication.
  ///
  /// A pending Flutter Web Google sign-in is finished first (it is the more
  /// recent user intent); otherwise a session that a previous "Remember me"
  /// login persisted is restored.
  Future<void> _restoreSessionOnStart() async {
    final googleCompleted = await _resumeWebGoogleSignIn();
    if (googleCompleted || !mounted) return;
    await _restoreRememberedSession();
  }

  /// Restores the session a previous "Remember me" login persisted.
  ///
  /// The stored token is validated against the server before it is used, so an
  /// expired or revoked session simply leaves the login form on screen.
  Future<void> _restoreRememberedSession() async {
    final restored = await ApiService.restoreRememberedSession();
    if (!mounted || !restored) return;

    setState(() => success = true);

    // An unverified account still confirms its mailbox first, exactly like a
    // fresh password login.
    if (ApiService.emailVerified == false) {
      await Navigator.pushReplacement(
          context,
          MaterialPageRoute<void>(
              builder: (_) =>
                  EmailVerificationScreen(email: ApiService.currentUserEmail)));
      return;
    }

    _openAuthenticatedArea();
  }

  Future<void> login() async {
    FocusScope.of(context).unfocus();
    if (emailController.text.trim().isEmpty ||
        passwordController.text.isEmpty) {
      setState(() => errorMessage = 'Please enter email and password');
      return;
    }
    if (!isValidEmail(emailController.text)) {
      setState(() => errorMessage = 'Enter a valid email address');
      return;
    }
    setState(() {
      loading = true;
      errorMessage = null;
    });
    try {
      await ApiService.login(
        emailController.text.trim(),
        passwordController.text,
        rememberMe: rememberMe,
      );
      if (!mounted) return;
      // Purely visual confirmation: the check stays visible on the button
      // while the route transition plays. Navigation is not delayed.
      setState(() => success = true);

      // FIRST-LOGIN EMAIL VERIFICATION: only an explicit `false` gates the
      // console. Google accounts (and older/partial payloads) report true or
      // null and go straight through.
      if (ApiService.emailVerified == false) {
        await Navigator.pushReplacement(
            context,
            MaterialPageRoute<void>(
                builder: (_) => EmailVerificationScreen(
                    email: ApiService.currentUserEmail)));
        return;
      }

      _openAuthenticatedArea();
    } catch (error) {
      if (mounted) {
        setState(() =>
            errorMessage = error.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  /// Shared post-authentication routing (password and Google paths).
  ///
  /// The realtime connection is opened here, i.e. only once the session is
  /// actually entering the authenticated area, so a session that is still
  /// waiting on email verification never holds a live socket.
  void _openAuthenticatedArea() {
    SocketService.instance.connect();
    if (ApiService.isResponder) {
      Navigator.pushReplacement(
          context,
          MaterialPageRoute<void>(
              builder: (readinessContext) =>
                  ResponderReadinessPage(onSaved: () {
                    Navigator.of(readinessContext).pushReplacement(
                        MaterialPageRoute<void>(
                            builder: (_) => const DispatchConsolePage(
                                readinessSuccess: true)));
                  })));
    } else {
      Navigator.pushReplacement(context,
          MaterialPageRoute<void>(builder: (_) => const DispatchConsolePage()));
    }
  }

  /// Google sign-in through the existing Firebase project.
  ///
  /// The client only obtains the Firebase ID token; the ERAS backend verifies
  /// it, logs in a known Firebase UID or links an existing user with the same
  /// verified email while preserving the ERAS role, then returns the normal
  /// ERAS JWT. Flutter Web runs the popup/redirect flow inside Firebase Auth,
  /// so a blocked popup degrades to a redirect instead of failing. A new
  /// Google account needs a public registration role, so new users start on
  /// the register screen. Google accounts are verified by Google and skip the
  /// email-verification screen.
  Future<void> signInWithGoogle() async {
    if (loading) return;
    FocusScope.of(context).unfocus();
    setState(() {
      loading = true;
      errorMessage = null;
      statusMessage = null;
    });

    try {
      // Flutter Web can fall back to a full-page redirect, which reloads the
      // app and this widget with it: park the checkbox choice so the completed
      // sign-in still honours it.
      if (kIsWeb) {
        await SessionPersistence.markGoogleIntent(rememberMe);
      }
      final outcome = await GoogleAuthService.instance.signIn();
      if (!mounted) return;
      if (outcome.isRedirecting) {
        // The browser is leaving for Google's handler; stay usable meanwhile.
        setState(() => statusMessage = 'Continuing with Google in this tab…');
        return;
      }
      final idToken = outcome.idToken;
      if (idToken == null) {
        // The user dismissed the Google UI: nothing happened and no session
        // changed.
        return;
      }
      await _completeGoogleSignIn(idToken, rememberSession: rememberMe);
    } on GoogleAuthException catch (error) {
      if (mounted) setState(() => errorMessage = error.message);
    } catch (error) {
      if (mounted) setState(() => errorMessage = _safeErrorMessage(error));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  /// Exchanges a Firebase ID token for the ERAS session and routes the user.
  ///
  /// [rememberSession] carries the checkbox choice of the attempt that started
  /// this exchange. When it is absent (a Flutter Web redirect return, where the
  /// widget and its state were rebuilt) the choice parked before the redirect
  /// is used instead.
  Future<void> _completeGoogleSignIn(
    String idToken, {
    GoogleRegistrationRequest? registration,
    bool? rememberSession,
  }) async {
    final parkedChoice = await SessionPersistence.consumeGoogleIntent();
    final rememberMe = rememberSession ?? parkedChoice ?? false;
    final Map<String, dynamic> response;
    try {
      response = await ApiService.googleSignIn(
        idToken: idToken,
        role: registration?.role,
        name: registration?.name,
        phone: registration?.phone,
        rememberMe: rememberMe,
      );
    } catch (error) {
      // Firebase authenticated this browser but ERAS did not create a session:
      // clear the provider session instead of leaving a half-authenticated
      // state behind, so the next attempt starts cleanly.
      await GoogleAuthService.instance.signOut();
      rethrow;
    }

    if (!mounted) return;
    setState(() => success = true);
    if (ApiService.isNewGoogleUser(response)) {
      final data = ApiService.authResponseData(response);
      Navigator.pushReplacement(
        context,
        MaterialPageRoute<void>(
          builder: (_) => AuthWelcomeScreen(
            welcomeEmailDeliveryResult:
                data['welcomeEmailDeliveryResult']?.toString(),
          ),
        ),
      );
    } else {
      // Existing Google users sign in normally; they never see a first-time
      // welcome screen or trigger another welcome email.
      _openAuthenticatedArea();
    }
  }

  /// Flutter Web: finishes a Google sign-in Firebase left pending (a redirect
  /// return, or the persisted session after a browser refresh).
  ///
  /// Does nothing on native platforms. Returns true when the pending sign-in
  /// actually produced an ERAS session, so the caller knows not to restore a
  /// remembered one on top of it.
  Future<bool> _resumeWebGoogleSignIn() async {
    GoogleWebResumeResult? result;
    try {
      result = await GoogleAuthService.instance.resumeWebSignIn();
    } on GoogleAuthException catch (error) {
      if (mounted) setState(() => errorMessage = error.message);
      return false;
    } catch (_) {
      // A pending sign-in that cannot be resumed must never block the page:
      // the user can simply press the Google button again.
      return false;
    }

    final idToken = result?.outcome.idToken;
    if (idToken == null || !mounted) return false;

    setState(() {
      loading = true;
      errorMessage = null;
    });
    try {
      await _completeGoogleSignIn(idToken, registration: result?.registration);
      return true;
    } on GoogleAuthException catch (error) {
      if (mounted) setState(() => errorMessage = error.message);
    } catch (error) {
      if (mounted) setState(() => errorMessage = _safeErrorMessage(error));
    } finally {
      if (mounted) setState(() => loading = false);
    }
    return false;
  }

  /// One safe sentence for anything that is not a [GoogleAuthException].
  ///
  /// Messages raised by ERAS's own API layer are written for the user and are
  /// shown as-is. Anything else is logged as a sanitized diagnostic and
  /// replaced by the generic notice, so an unexpected exception can never leak
  /// internals (URLs, plugin payloads, identifiers) into the UI.
  String _safeErrorMessage(Object error) {
    if (error is Exception) {
      final text = error
          .toString()
          .replaceFirst('Exception: ', '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (text.isNotEmpty && text.length <= 200) return text;
    }
    logErasClientDiagnostic('google-signin-unexpected', error);
    return erasGoogleGenericFailureMessage;
  }

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    emailFocusNode.dispose();
    passwordFocusNode.dispose();
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
                      key: const ValueKey('login-auth-tabs'),
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
                          focusNode: emailFocusNode,
                          keyboardType: TextInputType.emailAddress,
                          textInputAction: TextInputAction.next,
                          onEditingComplete: () =>
                              passwordFocusNode.requestFocus(),
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
                          focusNode: passwordFocusNode,
                          obscureText: obscurePassword,
                          textInputAction: TextInputAction.done,
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
                                    builder: (_) =>
                                        const ForgotPasswordScreen())),
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
                  AuthInlineMessage(
                    key: const ValueKey<String>('login-error-region'),
                    message: errorMessage,
                    color: skin.red,
                  ),
                  if (statusMessage != null)
                    AuthInlineMessage(
                      key: const ValueKey<String>('login-status-region'),
                      message: statusMessage,
                      color: skin.blue,
                      icon: Icons.info_outline_rounded,
                    ),
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
                  AuthGoogleButton(onPressed: signInWithGoogle),
                ])));
  }
}
