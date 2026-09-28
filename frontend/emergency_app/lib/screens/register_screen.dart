import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import 'login_screen.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});
  @override State<RegisterScreen> createState() => _RegisterScreenState();
}
class _RegisterScreenState extends State<RegisterScreen> {
  final name = TextEditingController(), email = TextEditingController(), phone = TextEditingController();
  final password = TextEditingController(), confirm = TextEditingController();
  final form = GlobalKey<FormState>();
  bool loading = false, hidePassword = true, hideConfirm = true;
  String? error;
  String? requiredField(String? v, String label) => v == null || v.trim().isEmpty ? '$label is required' : null;
  String? validEmail(String? v) => requiredField(v, 'Email') ?? (RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(v!.trim()) ? null : 'Enter a valid email address');
  Future<void> submit() async {
    FocusScope.of(context).unfocus();
    if (!form.currentState!.validate()) return;
    setState(() { loading = true; error = null; });
    try {
      await ApiService.register(name: name.text.trim(), email: email.text.trim(), password: password.text, phone: phone.text);
      if (!mounted) return;
      await showDialog<void>(context: context, builder: (_) => AlertDialog(title: const Text('Account created'), content: const Text('Your requester account is ready. You can now sign in.'), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Continue'))]));
      if (mounted) Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const LoginScreen()));
    } catch (e) { if (mounted) setState(() => error = e.toString().replaceFirst('Exception: ', '')); }
    finally { if (mounted) setState(() => loading = false); }
  }
  @override void dispose() { for (final c in [name,email,phone,password,confirm]) { c.dispose(); } super.dispose(); }
  @override Widget build(BuildContext context) => Scaffold(backgroundColor: AppColors.bg, body: SafeArea(child: Center(child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 460), child: Card(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: const BorderSide(color: AppColors.border)), elevation: 0, child: Padding(padding: const EdgeInsets.all(28), child: Form(key: form, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [const Text('ERAS', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)), const SizedBox(height: 5), const Text('Emergency Resource Allocation System', style: TextStyle(color: AppColors.textDim)), const SizedBox(height: 28), const Text('CREATE ACCOUNT', style: TextStyle(fontSize: 12, letterSpacing: 1, fontWeight: FontWeight.w700, color: AppColors.textDim)), const SizedBox(height: 16), TextFormField(controller: name, textInputAction: TextInputAction.next, decoration: const InputDecoration(labelText: 'Full name'), validator: (v) => requiredField(v, 'Name')), const SizedBox(height: 12), TextFormField(controller: email, keyboardType: TextInputType.emailAddress, textInputAction: TextInputAction.next, decoration: const InputDecoration(labelText: 'Email'), validator: validEmail), const SizedBox(height: 12), TextFormField(controller: phone, keyboardType: TextInputType.phone, textInputAction: TextInputAction.next, decoration: const InputDecoration(labelText: 'Phone number (optional)')), const SizedBox(height: 12), TextFormField(controller: password, obscureText: hidePassword, textInputAction: TextInputAction.next, decoration: InputDecoration(labelText: 'Password', helperText: 'At least 6 characters', suffixIcon: IconButton(tooltip: 'Show or hide password', onPressed: () => setState(() => hidePassword = !hidePassword), icon: Icon(hidePassword ? Icons.visibility : Icons.visibility_off))), validator: (v) => requiredField(v, 'Password') ?? (v!.length < 6 ? 'Use at least 6 characters' : null)), const SizedBox(height: 12), TextFormField(controller: confirm, obscureText: hideConfirm, decoration: InputDecoration(labelText: 'Confirm password', suffixIcon: IconButton(tooltip: 'Show or hide password', onPressed: () => setState(() => hideConfirm = !hideConfirm), icon: Icon(hideConfirm ? Icons.visibility : Icons.visibility_off))), validator: (v) => v != password.text ? 'Passwords do not match' : null), const SizedBox(height: 14), Container(padding: const EdgeInsets.all(12), color: AppColors.tealDim, child: const Text('Account type: Requester\nPublic registration cannot create responder or admin accounts.', style: TextStyle(fontSize: 12, color: AppColors.text))), if (error != null) Padding(padding: const EdgeInsets.only(top: 14), child: Text(error!, style: const TextStyle(color: AppColors.red))), const SizedBox(height: 20), FilledButton(onPressed: loading ? null : submit, child: loading ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Text('Create account')), const SizedBox(height: 12), TextButton(onPressed: loading ? null : () => Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const LoginScreen())), child: const Text('Already have an account? Sign in'))])))))))));
}
