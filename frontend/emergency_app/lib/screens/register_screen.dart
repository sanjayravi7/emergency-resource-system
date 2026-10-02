import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/api_service.dart';
import '../services/email_validation.dart';
import '../services/google_auth_service.dart';
import '../theme/app_theme.dart';
import '../widgets/auth_motion.dart';
import '../widgets/auth_shell.dart';
import '../widgets/auth_visuals.dart';
import 'dispatch_console_page.dart';
import 'email_verification_screen.dart';
import 'login_screen.dart';
import 'responder_readiness_page.dart';

/// The two roles PUBLIC registration may choose between. ADMIN is
/// intentionally absent: it stays a database role provisioned through the
/// administrator workflow, never a public signup option.
enum RegistrationRole { requester, responder }

extension RegistrationRoleWire on RegistrationRole {
  /// Exact value sent to POST /api/auth/register. The backend allowlists
  /// these two values and rejects everything else.
  String get wireName => switch (this) {
        RegistrationRole.requester => 'REQUESTER',
        RegistrationRole.responder => 'RESPONDER',
      };

  /// Short, professional explanation shown once a role is selected.
  String get explanation => switch (this) {
        RegistrationRole.requester =>
          "You'll use ERAS to request emergency resources and assistance.",
        RegistrationRole.responder =>
          "You'll use ERAS to receive eligible emergencies and provide "
              'assistance.',
      };
}

/// Registration asks ONCE how the user intends to use ERAS. The selected role
/// is persisted by the backend on the User record; login never asks again and
/// always derives the experience from the server-provided database role.
class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final name = TextEditingController(),
      email = TextEditingController(),
      phone = TextEditingController();
  final password = TextEditingController(), confirm = TextEditingController();
  final form = GlobalKey<FormState>();
  bool loading = false, hidePassword = true, hideConfirm = true;
  String? error;

  /// Selected role. Kept only for the duration of the form; the persisted
  /// role always lives in PostgreSQL via the registration API.
  RegistrationRole? selectedRole;

  /// Validation message shown when submit is attempted with no role chosen.
  String? roleError;

  void selectRole(RegistrationRole role) {
    setState(() {
      selectedRole = role;
      roleError = null;
    });
  }

  String? requiredField(String? v, String label) =>
      v == null || v.trim().isEmpty ? '$label is required' : null;

  /// Server-parity email validation (see lib/services/email_validation.dart):
  /// syntax and length only, never a mailbox existence probe.
  String? validEmail(String? v) =>
      requiredField(v, 'Email') ??
      (isValidEmail(v) ? null : 'Enter a valid email address');

  Future<void> submit() async {
    FocusScope.of(context).unfocus();

    // Role selection is required: never submit without an explicit choice.
    if (selectedRole == null) {
      setState(() => roleError = 'Choose how you want to use ERAS.');
      return;
    }

    if (!form.currentState!.validate()) return;

    setState(() {
      loading = true;
      error = null;
    });

    try {
      final response = await ApiService.register(
        name: name.text.trim(),
        email: email.text.trim(),
        password: password.text,
        phone: phone.text,
        role: selectedRole!.wireName,
      );
      if (!mounted) return;

      // The backend issues the ERAS session on registration. Email/password
      // accounts start unverified, so the next step is the ERAS verification
      // code; Google accounts are verified by Google and skip it.
      ApiService.applySession(response);

      if (ApiService.emailVerified == false) {
        await Navigator.pushReplacement(
          context,
          MaterialPageRoute<void>(
            builder: (_) => EmailVerificationScreen(
              email: ApiService.currentUserEmail ?? email.text.trim(),
            ),
          ),
        );
        return;
      }

      Navigator.pushReplacement(
        context,
        MaterialPageRoute<void>(builder: (_) => const LoginScreen()),
      );
    } catch (e) {
      final message = e.toString().replaceFirst('Exception: ', '');
      if (mounted) {
        setState(() {
          error = message.contains('Email already registered')
              ? 'An account with this email already exists.'
              : message;
        });
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  void dispose() {
    for (final c in [name, email, phone, password, confirm]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final skin = AuthSkin.of(context);
    return AuthShell(
        child: AuthPanel(
      hoverLift: true,
      child: Form(
          key: form,
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            AuthTabs(
                registerSelected: true,
                onLoginTap: () => Navigator.pushReplacement(context,
                    MaterialPageRoute(builder: (_) => const LoginScreen())),
                onRegisterTap: () {}),
            const SizedBox(height: 20),
            Center(
                child: Container(
                    width: 58,
                    height: 58,
                    decoration: BoxDecoration(
                        color: skin.tealDim, shape: BoxShape.circle),
                    child: const Center(
                        child: AuthShield(size: 30, outlined: true)))),
            const SizedBox(height: 12),
            Text('CREATE ACCOUNT',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 24,
                    height: 1.2,
                    fontWeight: FontWeight.w800,
                    letterSpacing: .4,
                    color: skin.text)),
            const SizedBox(height: 5),
            Text('Join the ERAS emergency response network',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: skin.textDim)),
            const SizedBox(height: 20),
            Text('How would you like to use ERAS?',
                style: TextStyle(
                    fontSize: 10.5,
                    letterSpacing: 1.1,
                    fontWeight: FontWeight.w800,
                    color: skin.textDim)),
            const SizedBox(height: 10),
            _roleCards(),
            if (selectedRole != null)
              Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Container(
                      padding: const EdgeInsets.all(11),
                      decoration: BoxDecoration(
                          color: skin.tealDim,
                          borderRadius: BorderRadius.circular(9)),
                      child: Text(selectedRole!.explanation,
                          style: TextStyle(fontSize: 11.5, color: skin.text))))
            else if (roleError != null)
              Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(roleError!,
                      style: TextStyle(fontSize: 12, color: skin.red))),
            const SizedBox(height: 16),
            FocusGlow(
                glowColor: skin.blue,
                child: TextFormField(
                    controller: name,
                    textInputAction: TextInputAction.next,
                    decoration: authFieldDecoration(context,
                        label: 'Full name', icon: Icons.person_outline),
                    validator: (v) => requiredField(v, 'Name'))),
            const SizedBox(height: 12),
            FocusGlow(
                glowColor: skin.blue,
                child: TextFormField(
                    controller: email,
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.next,
                    decoration: authFieldDecoration(context,
                        label: 'Email', icon: Icons.mail_outline),
                    validator: validEmail)),
            const SizedBox(height: 12),
            FocusGlow(
                glowColor: skin.blue,
                child: TextFormField(
                    controller: phone,
                    keyboardType: TextInputType.phone,
                    textInputAction: TextInputAction.next,
                    decoration: authFieldDecoration(context,
                        label: 'Phone number (optional)',
                        icon: Icons.phone_outlined))),
            const SizedBox(height: 12),
            FocusGlow(
                glowColor: skin.blue,
                child: TextFormField(
                    controller: password,
                    obscureText: hidePassword,
                    textInputAction: TextInputAction.next,
                    decoration: authFieldDecoration(context,
                        label: 'Password',
                        icon: Icons.lock_outline,
                        helperText: 'At least 6 characters',
                        suffixIcon: IconButton(
                            tooltip: 'Show or hide password',
                            onPressed: () =>
                                setState(() => hidePassword = !hidePassword),
                            icon: AnimatedSwap(
                                child: Icon(
                                    hidePassword
                                        ? Icons.visibility_outlined
                                        : Icons.visibility_off_outlined,
                                    key: ValueKey(hidePassword))))),
                    validator: (v) =>
                        requiredField(v, 'Password') ??
                        (v!.length < 6 ? 'Use at least 6 characters' : null))),
            const SizedBox(height: 12),
            FocusGlow(
                glowColor: skin.blue,
                child: TextFormField(
                    controller: confirm,
                    obscureText: hideConfirm,
                    decoration: authFieldDecoration(context,
                        label: 'Confirm password',
                        icon: Icons.lock_reset_outlined,
                        suffixIcon: IconButton(
                            tooltip: 'Show or hide password',
                            onPressed: () =>
                                setState(() => hideConfirm = !hideConfirm),
                            icon: AnimatedSwap(
                                child: Icon(
                                    hideConfirm
                                        ? Icons.visibility_outlined
                                        : Icons.visibility_off_outlined,
                                    key: ValueKey(hideConfirm))))),
                    validator: (v) =>
                        v != password.text ? 'Passwords do not match' : null)),
            if (error != null)
              Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(error!, style: TextStyle(color: skin.red))),
            const SizedBox(height: 18),
            AuthPrimaryButton(
                label: 'Create account',
                onPressed: loading ? null : submit,
                loading: loading),
            const SizedBox(height: 18),
            const AuthDividerLabel(),
            const SizedBox(height: 12),
            AuthGoogleButton(onPressed: signUpWithGoogle),
          ])),
    ));
  }

  /// Google registration through the existing Firebase project.
  ///
  /// The selected role is only a *request* for a brand-new ERAS account; the
  /// server ignores it for an existing account and never lets a client create
  /// an ADMIN. An existing account is simply linked by verified email.
  Future<void> signUpWithGoogle() async {
    if (loading) return;
    FocusScope.of(context).unfocus();

    if (selectedRole == null) {
      setState(() => roleError = 'Choose how you want to use ERAS.');
      return;
    }

    setState(() {
      loading = true;
      error = null;
    });

    try {
      final idToken = await GoogleAuthService.instance.signInAndGetIdToken();
      if (idToken == null) return; // dismissed the account sheet

      await ApiService.googleSignIn(
        idToken: idToken,
        role: selectedRole!.wireName,
        name: name.text.trim(),
        phone: phone.text.trim(),
      );
      if (!mounted) return;
      _openAuthenticatedArea();
    } on GoogleAuthException catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (e) {
      final message = e.toString().replaceFirst('Exception: ', '');
      if (mounted) setState(() => error = message);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void _openAuthenticatedArea() {
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

  /// Two selectable role cards. They sit side by side when there is room and
  /// stack vertically on narrow phones so nothing is ever clipped or
  /// horizontally overflowing.
  Widget _roleCards() => LayoutBuilder(
        builder: (context, constraints) {
          final cards = <Widget>[
            _RoleSelectionCard(
              role: RegistrationRole.requester,
              icon: Icons.emergency,
              title: 'I NEED HELP',
              description: 'Request emergency assistance',
              selected: selectedRole == RegistrationRole.requester,
              onSelected: selectRole,
            ),
            _RoleSelectionCard(
              role: RegistrationRole.responder,
              icon: Icons.volunteer_activism,
              title: "I'M WILLING TO HELP",
              description: 'Provide emergency assistance',
              selected: selectedRole == RegistrationRole.responder,
              onSelected: selectRole,
            ),
          ];

          if (constraints.maxWidth >= 380) {
            return IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: cards[0]),
                  const SizedBox(width: 12),
                  Expanded(child: cards[1]),
                ],
              ),
            );
          }

          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              cards[0],
              const SizedBox(height: 12),
              cards[1],
            ],
          );
        },
      );
}

/// A single selectable role card.
///
/// - radio-style check marker + bold border + SELECTED tag so the chosen state
///   is obvious without relying on colour alone,
/// - a visible keyboard focus ring, and Enter/Space activation,
/// - semantics: exposed as a selectable button with a full spoken label.
class _RoleSelectionCard extends StatefulWidget {
  const _RoleSelectionCard({
    required this.role,
    required this.icon,
    required this.title,
    required this.description,
    required this.selected,
    required this.onSelected,
  });

  final RegistrationRole role;
  final IconData icon;
  final String title;
  final String description;
  final bool selected;
  final ValueChanged<RegistrationRole> onSelected;

  @override
  State<_RoleSelectionCard> createState() => _RoleSelectionCardState();
}

class _RoleSelectionCardState extends State<_RoleSelectionCard> {
  final FocusNode _focusNode = FocusNode();
  bool _keyboardFocus = false;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_handleFocusChange);
  }

  void _handleFocusChange() {
    if (!mounted) return;
    final hasFocus = _focusNode.hasFocus;
    if (hasFocus != _keyboardFocus) {
      setState(() => _keyboardFocus = hasFocus);
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _activate() => widget.onSelected(widget.role);

  @override
  Widget build(BuildContext context) {
    final p = ErasPalette.of(context);
    final selected = widget.selected;
    final baseBorder = selected ? p.teal : p.border;
    final borderColor = _keyboardFocus ? p.blue : baseBorder;
    final borderWidth = _keyboardFocus || selected ? 2.0 : 1.0;

    return Semantics(
      container: true,
      button: true,
      selected: selected,
      label: '${widget.title}. ${widget.description}',
      child: ExcludeSemantics(
        child: FocusableActionDetector(
          focusNode: _focusNode,
          mouseCursor: SystemMouseCursors.click,
          shortcuts: const <ShortcutActivator, Intent>{
            SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
            SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
          },
          actions: <Type, Action<Intent>>{
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                _activate();
                return null;
              },
            ),
          },
          child: Material(
            color: selected ? p.tealDim : (p.dark ? p.surface2 : p.surface),
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              onTap: _activate,
              borderRadius: BorderRadius.circular(10),
              child: AnimatedContainer(
                key: ValueKey<String>('role-card-${widget.role.wireName}'),
                duration: AuthMotion.scaled(
                  context,
                  const Duration(milliseconds: 200),
                ),
                curve: Curves.easeOutCubic,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: borderColor,
                    width: borderWidth,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Icon(widget.icon, size: 22, color: p.text),
                        const Spacer(),
                        AnimatedSwap(
                          child: selected
                              ? Icon(
                                  Icons.check_circle,
                                  key: ValueKey<String>(
                                    'role-selected-check-'
                                    '${widget.role.wireName}',
                                  ),
                                  size: 20,
                                  color: p.teal,
                                )
                              : Icon(
                                  Icons.radio_button_unchecked,
                                  key: ValueKey<String>(
                                    'role-unselected-mark-'
                                    '${widget.role.wireName}',
                                  ),
                                  size: 20,
                                  color: p.textFaint,
                                ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      widget.title,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: .3,
                        color: p.text,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      widget.description,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: p.textDim,
                      ),
                    ),
                    if (selected) ...[
                      const SizedBox(height: 8),
                      Text(
                        'SELECTED',
                        key: ValueKey<String>(
                          'role-selected-tag-${widget.role.wireName}',
                        ),
                        style: TextStyle(
                          fontSize: 9.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1,
                          color: p.teal,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
