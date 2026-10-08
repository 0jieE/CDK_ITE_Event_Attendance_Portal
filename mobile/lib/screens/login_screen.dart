import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/api_service.dart';
import '../services/auth_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/state_message.dart';
import 'signup_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    final auth = context.read<AuthProvider>();
    await auth.login(_userCtrl.text, _passCtrl.text);
    // On success the root router swaps this screen out automatically.
  }

  Future<void> _openSignUp() async {
    final auth = context.read<AuthProvider>()..clearError();
    final username = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const SignUpScreen()),
    );
    if (!mounted || username == null || username.isEmpty) return;
    // Registered: make signing in (once approved) a one-field job.
    _userCtrl.text = username;
    _passCtrl.clear();
    auth.clearError();
  }

  /// The failed-login message, styled by what happened: waiting for approval is
  /// good-news-pending (calm), a rejection or a wrong password is an error.
  Widget _loginBanner(AuthProvider auth) {
    switch (auth.errorCode) {
      case ApiCodes.pendingApproval:
        return const InlineBanner(
          isError: false,
          icon: Icons.hourglass_top,
          message: 'Your account is waiting for approval by the Department '
              "Adviser. You'll be able to sign in once it is approved.",
        );
      case ApiCodes.registrationRejected:
        return InlineBanner(icon: Icons.block, message: auth.error!);
      default:
        return InlineBanner(message: auth.error!);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppTheme.green, AppTheme.greenPressed],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Card(
                  elevation: 6,
                  shadowColor: const Color(0x4D06200A),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
                    child: Form(
                      key: _formKey,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Center(
                            child: Container(
                              width: 68,
                              height: 68,
                              decoration: BoxDecoration(
                                color: AppTheme.green,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: const Icon(Icons.qr_code_2,
                                  size: 40, color: AppTheme.onGreen),
                            ),
                          ),
                          const SizedBox(height: 16),
                          Text('ITE Attendance',
                              textAlign: TextAlign.center,
                              style: Theme.of(context)
                                  .textTheme
                                  .headlineSmall
                                  ?.copyWith(fontWeight: FontWeight.w800)),
                          const SizedBox(height: 2),
                          Text('Colegio de Kidapawan',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: scheme.onSurfaceVariant)),
                          const SizedBox(height: 28),
                          TextFormField(
                            controller: _userCtrl,
                            textInputAction: TextInputAction.next,
                            autofillHints: const [AutofillHints.username],
                            decoration: const InputDecoration(
                              labelText: 'Username',
                              prefixIcon: Icon(Icons.person_outline),
                            ),
                            validator: (v) => (v == null || v.trim().isEmpty)
                                ? 'Enter your username'
                                : null,
                          ),
                          const SizedBox(height: 16),
                          TextFormField(
                            controller: _passCtrl,
                            obscureText: _obscure,
                            autofillHints: const [AutofillHints.password],
                            onFieldSubmitted: (_) => _submit(),
                            decoration: InputDecoration(
                              labelText: 'Password',
                              prefixIcon: const Icon(Icons.lock_outline),
                              suffixIcon: IconButton(
                                tooltip:
                                    _obscure ? 'Show password' : 'Hide password',
                                icon: Icon(_obscure
                                    ? Icons.visibility_off_outlined
                                    : Icons.visibility_outlined),
                                onPressed: () =>
                                    setState(() => _obscure = !_obscure),
                              ),
                            ),
                            validator: (v) => (v == null || v.isEmpty)
                                ? 'Enter your password'
                                : null,
                          ),
                          if (auth.error != null) ...[
                            const SizedBox(height: 16),
                            _loginBanner(auth),
                          ],
                          const SizedBox(height: 24),
                          FilledButton(
                            onPressed: auth.busy ? null : _submit,
                            child: auth.busy
                                ? const SizedBox(
                                    height: 22,
                                    width: 22,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2.5,
                                        color: AppTheme.onGreen),
                                  )
                                : const Text('Sign in'),
                          ),
                          const SizedBox(height: 8),
                          TextButton(
                            onPressed: auth.busy ? null : _openSignUp,
                            child: const Text('New student? Create an account'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
