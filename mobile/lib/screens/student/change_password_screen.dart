import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/api_service.dart';
import '../../theme/app_theme.dart';
import '../../utils/errors.dart';
import '../../utils/validators.dart';
import '../../widgets/state_message.dart';

/// Change the account password: current + new + confirm. The server's Django
/// validators decide whether the new password is acceptable and their messages
/// are shown under the field.
class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({super.key});

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _new = TextEditingController();
  final _confirm = TextEditingController();

  bool _showCurrent = false;
  bool _showNew = false;
  bool _showConfirm = false;
  bool _busy = false;
  String? _banner;
  final _serverErrors = ServerFieldErrors();

  @override
  void dispose() {
    _current.dispose();
    _new.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    _serverErrors.clear();
    setState(() => _banner = null);
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    final api = context.read<ApiService>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await api.changePassword(
        currentPassword: _current.text,
        newPassword: _new.text,
      );
      if (!mounted) return;
      _current.clear();
      _new.clear();
      _confirm.clear();
      _formKey.currentState!.reset();
      messenger.showSnackBar(
          const SnackBar(content: Text('Password changed successfully.')));
    } on SessionExpired {
      return;
    } catch (e) {
      if (!mounted) return;
      final fields = fieldErrors(e);
      setState(() {
        _serverErrors.set(
            fields,
            (f) => f == 'current_password' ? _current.text : _new.text);
        final shown = fields.keys
            .every((k) => k == 'current_password' || k == 'new_password');
        _banner = (fields.isEmpty || !shown) ? friendlyError(e) : null;
      });
      _formKey.currentState!.validate(); // paint the server errors
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _toggle(bool shown, VoidCallback onTap) => IconButton(
        tooltip: shown ? 'Hide password' : 'Show password',
        icon: Icon(shown ? Icons.visibility_outlined : Icons.visibility_off_outlined),
        onPressed: onTap,
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Change password')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextFormField(
                      controller: _current,
                      obscureText: !_showCurrent,
                      enabled: !_busy,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.password],
                      decoration: InputDecoration(
                        labelText: 'Current password',
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: _toggle(_showCurrent,
                            () => setState(() => _showCurrent = !_showCurrent)),
                      ),
                      validator: (v) => (v == null || v.isEmpty)
                          ? 'Enter your current password'
                          : _serverErrors.forField('current_password', v),
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _new,
                      obscureText: !_showNew,
                      enabled: !_busy,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.newPassword],
                      decoration: InputDecoration(
                        labelText: 'New password',
                        helperText: 'At least 8 characters. Avoid common or '
                            'all-number passwords.',
                        helperMaxLines: 2,
                        prefixIcon: const Icon(Icons.lock_reset),
                        suffixIcon: _toggle(
                            _showNew, () => setState(() => _showNew = !_showNew)),
                      ),
                      validator: (v) =>
                          validateNewPassword(v) ??
                          _serverErrors.forField('new_password', v),
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _confirm,
                      obscureText: !_showConfirm,
                      enabled: !_busy,
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => _submit(),
                      decoration: InputDecoration(
                        labelText: 'Confirm new password',
                        prefixIcon: const Icon(Icons.lock_reset),
                        suffixIcon: _toggle(_showConfirm,
                            () => setState(() => _showConfirm = !_showConfirm)),
                      ),
                      validator: (v) => validateConfirm(v, _new.text),
                    ),
                    if (_banner != null) ...[
                      const SizedBox(height: 14),
                      InlineBanner(message: _banner!),
                    ],
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      style: AppTheme.wide,
                      onPressed: _busy ? null : _submit,
                      icon: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: AppTheme.onGreen))
                          : const Icon(Icons.check),
                      label: Text(_busy ? 'Saving…' : 'Update password'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
