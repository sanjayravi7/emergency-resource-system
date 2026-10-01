import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/auth_shell.dart';
import 'login_screen.dart';

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
          "You'll use ERAS to receive eligible emergencies and provide assistance.",
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

  String? validEmail(String? v) =>
      requiredField(v, 'Email') ??
      (RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(v!.trim())
          ? null
          : 'Enter a valid email address');

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
      await ApiService.register(
        name: name.text.trim(),
        email: email.text.trim(),
        password: password.text,
        phone: phone.text,
        role: selectedRole!.wireName,
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Account created successfully.'),
          content: const Text(
            'Your ERAS account is ready. Sign in to continue.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Continue'),
            ),
          ],
        ),
      );
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const LoginScreen()),
        );
      }
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
    final dark = Theme.of(context).brightness == Brightness.dark;
    return AuthShell(child: Container(
      padding: EdgeInsets.all(MediaQuery.sizeOf(context).width < 430 ? 22 : 32),
      decoration: BoxDecoration(color: dark ? const Color(0xE6102035) : Colors.white, borderRadius: BorderRadius.circular(22), border: Border.all(color: dark ? const Color(0xFF2A4C68) : AppColors.border), boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: dark ? .2 : .08), blurRadius: 35, offset: const Offset(0, 14))]),
      child: Form(key: form, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [Expanded(child: _authTab('Login', false, () => Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const LoginScreen())))), Expanded(child: _authTab('Register', true, () {}))]),
        const SizedBox(height: 24), const Icon(Icons.person_add_alt_1_rounded, color: AppColors.teal, size: 38), const SizedBox(height: 10),
        Text('CREATE ACCOUNT', textAlign: TextAlign.center, style: TextStyle(fontSize: 25, fontWeight: FontWeight.w800, color: dark ? Colors.white : AppColors.text)),
        const SizedBox(height: 5), Text('Join the ERAS emergency response network', textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: dark ? const Color(0xFF9CAFC4) : AppColors.textDim)),
        const SizedBox(height: 24), Text('How would you like to use ERAS?', style: TextStyle(fontSize: 10.5, letterSpacing: 1.1, fontWeight: FontWeight.w800, color: dark ? const Color(0xFFA9B8CC) : AppColors.textDim)), const SizedBox(height: 10), _roleCards(),
        if (selectedRole != null) Padding(padding: const EdgeInsets.only(top: 10), child: Container(padding: const EdgeInsets.all(11), decoration: BoxDecoration(color: AppColors.teal.withValues(alpha: .1), borderRadius: BorderRadius.circular(9)), child: Text(selectedRole!.explanation, style: TextStyle(fontSize: 11.5, color: dark ? const Color(0xFFC6D5E4) : AppColors.text)))) else if (roleError != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(roleError!, style: const TextStyle(fontSize: 12, color: AppColors.red))),
        const SizedBox(height: 18), TextFormField(controller: name, textInputAction: TextInputAction.next, decoration: const InputDecoration(labelText: 'Full name', prefixIcon: Icon(Icons.person_outline)), validator: (v) => requiredField(v, 'Name')),
        const SizedBox(height: 12), TextFormField(controller: email, keyboardType: TextInputType.emailAddress, textInputAction: TextInputAction.next, decoration: const InputDecoration(labelText: 'Email', prefixIcon: Icon(Icons.mail_outline)), validator: validEmail),
        const SizedBox(height: 12), TextFormField(controller: phone, keyboardType: TextInputType.phone, textInputAction: TextInputAction.next, decoration: const InputDecoration(labelText: 'Phone number (optional)', prefixIcon: Icon(Icons.phone_outlined))),
        const SizedBox(height: 12), TextFormField(controller: password, obscureText: hidePassword, textInputAction: TextInputAction.next, decoration: InputDecoration(labelText: 'Password', helperText: 'At least 6 characters', prefixIcon: const Icon(Icons.lock_outline), suffixIcon: IconButton(tooltip: 'Show or hide password', onPressed: () => setState(() => hidePassword = !hidePassword), icon: Icon(hidePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined))), validator: (v) => requiredField(v, 'Password') ?? (v!.length < 6 ? 'Use at least 6 characters' : null)),
        const SizedBox(height: 12), TextFormField(controller: confirm, obscureText: hideConfirm, decoration: InputDecoration(labelText: 'Confirm password', prefixIcon: const Icon(Icons.lock_reset_outlined), suffixIcon: IconButton(tooltip: 'Show or hide password', onPressed: () => setState(() => hideConfirm = !hideConfirm), icon: Icon(hideConfirm ? Icons.visibility_outlined : Icons.visibility_off_outlined))), validator: (v) => v != password.text ? 'Passwords do not match' : null),
        if (error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(error!, style: const TextStyle(color: AppColors.red))), const SizedBox(height: 18),
        DecoratedBox(decoration: BoxDecoration(gradient: const LinearGradient(colors: [Color(0xFF2478E5), Color(0xFF08AA91)]), borderRadius: BorderRadius.circular(12)), child: FilledButton(onPressed: loading ? null : submit, style: FilledButton.styleFrom(backgroundColor: Colors.transparent, shadowColor: Colors.transparent), child: loading ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Text('Create account'))),
      ])),
    ));
  }

  Widget _authTab(String label, bool selected, VoidCallback tap) => InkWell(onTap: tap, borderRadius: BorderRadius.circular(10), child: Container(padding: const EdgeInsets.symmetric(vertical: 12), decoration: BoxDecoration(color: selected ? AppColors.teal.withValues(alpha: .1) : Colors.transparent, borderRadius: BorderRadius.circular(10), border: Border(bottom: BorderSide(color: selected ? AppColors.teal : Colors.transparent, width: 2))), child: Text(label, textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.w700, color: selected ? AppColors.teal : Theme.of(context).colorScheme.onSurfaceVariant))));

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
    final selected = widget.selected;
    final borderColor = _keyboardFocus
        ? AppColors.blue
        : selected
            ? AppColors.teal
            : AppColors.border;
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
            color: selected ? AppColors.tealDim : AppColors.surface,
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              onTap: _activate,
              borderRadius: BorderRadius.circular(10),
              child: Container(
                key: ValueKey<String>('role-card-${widget.role.wireName}'),
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
                        Icon(widget.icon, size: 22, color: AppColors.text),
                        const Spacer(),
                        if (selected)
                          Icon(
                            Icons.check_circle,
                            key: ValueKey<String>(
                              'role-selected-check-${widget.role.wireName}',
                            ),
                            size: 20,
                            color: AppColors.teal,
                          )
                        else
                          const Icon(
                            Icons.radio_button_unchecked,
                            size: 20,
                            color: AppColors.textFaint,
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      widget.title,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: .3,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      widget.description,
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: AppColors.textDim,
                      ),
                    ),
                    if (selected) ...[
                      const SizedBox(height: 8),
                      Text(
                        'SELECTED',
                        key: ValueKey<String>(
                          'role-selected-tag-${widget.role.wireName}',
                        ),
                        style: const TextStyle(
                          fontSize: 9.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1,
                          color: AppColors.teal,
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
