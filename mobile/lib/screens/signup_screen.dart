import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../utils/errors.dart';
import '../utils/image_type.dart';
import '../utils/validators.dart';
import '../widgets/state_message.dart';

/// Student self-registration. The account is created inactive; the Department
/// Adviser approves it in the web portal before the student can sign in, so on
/// success this screen shows a confirmation instead of signing anyone in.
///
/// Pops with the chosen username (so the login screen can pre-fill it) after a
/// successful registration.
class SignUpScreen extends StatefulWidget {
  /// Injectable for tests; defaults to the real camera/gallery picker.
  final ImagePicker? picker;

  const SignUpScreen({super.key, this.picker});

  @override
  State<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends State<SignUpScreen> {
  final _formKey = GlobalKey<FormState>();
  final _studentNumber = TextEditingController();
  final _first = TextEditingController();
  final _middle = TextEditingController();
  final _last = TextEditingController();
  final _section = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  late final ImagePicker _picker = widget.picker ?? ImagePicker();

  String? _year;
  Uint8List? _photo;
  ImageType? _photoType;
  String? _photoError;

  bool _showPassword = false;
  bool _showConfirm = false;
  bool _busy = false;

  /// Banner above the submit button; [_bannerRetry] adds a "Try again" action
  /// (network failures and rate limiting).
  String? _banner;
  bool _bannerRetry = false;

  /// Set once the server accepted the registration.
  String? _doneMessage;

  /// Server-side field errors; each disappears once its input is edited.
  final _serverErrors = ServerFieldErrors();

  late final Map<String, TextEditingController> _byField = {
    'student_number': _studentNumber,
    'first_name': _first,
    'middle_name': _middle,
    'last_name': _last,
    'section': _section,
    'username': _username,
    'password': _password,
  };

  @override
  void dispose() {
    for (final c in [..._byField.values, _confirm]) {
      c.dispose();
    }
    super.dispose();
  }

  String _valueOf(String field) {
    if (field == 'year_level') return _year ?? '';
    return _byField[field]?.text ?? '';
  }

  /// Wraps a validator so a server error for [field] shows (while the value is
  /// unchanged) when the client validation passes.
  FormFieldValidator<String> _check(
    String field,
    FormFieldValidator<String> client,
  ) {
    return (v) => client(v) ?? _serverErrors.forField(field, v);
  }

  // --- Submit ---------------------------------------------------------------
  Future<void> _submit() async {
    _serverErrors.clear();
    setState(() {
      _banner = null;
      _bannerRetry = false;
    });
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    final api = context.read<ApiService>();
    final username = _username.text.trim();
    setState(() => _busy = true);
    try {
      final message = await api.register(
        studentNumber: _studentNumber.text.trim(),
        firstName: _first.text.trim(),
        middleName: _middle.text.trim(),
        lastName: _last.text.trim(),
        username: username,
        password: _password.text,
        yearLevel: _year!,
        section: _section.text.trim(),
        photo: _photo,
        photoType: _photoType,
      );
      if (!mounted) return;
      setState(() => _doneMessage = message);
    } catch (e) {
      if (!mounted) return;
      _showFailure(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showFailure(Object e) {
    final fields = e is ApiException && e.statusCode == 400
        ? fieldErrors(e)
        : const <String, String>{};
    final known = {..._byField.keys, 'year_level', 'profile_image'};
    final shownFields = fields.keys.where(known.contains).toSet();
    final others = {
      for (final f in fields.entries)
        if (!known.contains(f.key)) f.key: f.value,
    };

    setState(() {
      _serverErrors.set({
        for (final f in fields.entries)
          if (known.contains(f.key) && f.key != 'profile_image') f.key: f.value,
      }, _valueOf);
      _photoError = fields['profile_image'];

      if (fields.isEmpty) {
        // 429, network trouble, 5xx or a plain `detail`.
        _banner = friendlyError(e);
        _bannerRetry =
            e is! ApiException || e.isRateLimited || e.statusCode >= 500;
      } else if (others.isNotEmpty) {
        _banner = others.values.join(' ');
        _bannerRetry = false;
      } else if (shownFields.isNotEmpty) {
        _banner = 'Please fix the highlighted fields and try again.';
        _bannerRetry = false;
      }
    });
    _formKey.currentState!.validate(); // paint the server errors
  }

  // --- Photo ----------------------------------------------------------------
  Future<void> _choosePhotoSource() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a photo'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source != null) await _pick(source);
  }

  Future<void> _pick(ImageSource source) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      // Downscale + recompress (keeps it well under the 5 MB limit).
      final picked = await _picker.pickImage(
        source: source,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 85,
      );
      if (picked == null) return; // cancelled
      final bytes = await picked.readAsBytes();
      final type = detectImageType(bytes);
      if (type == null) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Unsupported image. Please use a JPG, PNG or WebP.'),
          ),
        );
        return;
      }
      if (bytes.length > maxPhotoBytes) {
        messenger.showSnackBar(
          const SnackBar(content: Text('That photo is too large (max 5 MB).')),
        );
        return;
      }
      if (!mounted) return;
      setState(() {
        _photo = bytes;
        _photoType = type;
        _photoError = null;
      });
    } on PlatformException catch (e) {
      final denied = e.code.contains('access_denied');
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            denied
                ? (source == ImageSource.camera
                      ? 'Camera access is turned off. Allow it in your phone settings.'
                      : 'Photo access is turned off. Allow it in your phone settings.')
                : 'Could not open the picker. Please try again.',
          ),
        ),
      );
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Could not read that photo. Please try another.'),
        ),
      );
    }
  }

  void _removePhoto() => setState(() {
    _photo = null;
    _photoType = null;
    _photoError = null;
  });

  // --- UI -------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    if (_doneMessage != null) {
      return _SubmittedView(
        message: _doneMessage!,
        username: _username.text.trim(),
        onDone: () => Navigator.of(context).pop(_username.text.trim()),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Create account')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Form(
                key: _formKey,
                autovalidateMode: AutovalidateMode.onUserInteraction,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Register with your student details. The Department '
                      'Adviser reviews every new account before you can sign in.',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 16),
                    _Section(
                      title: 'Profile photo (optional)',
                      icon: Icons.photo_camera_outlined,
                      child: _photoPicker(scheme),
                    ),
                    const SizedBox(height: 16),
                    _Section(
                      title: 'Student information',
                      icon: Icons.school_outlined,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _field(
                            _studentNumber,
                            'student_number',
                            'Student number',
                            validator: validateStudentNumber,
                            icon: Icons.badge_outlined,
                          ),
                          _field(
                            _first,
                            'first_name',
                            'First name',
                            validator: (v) => validateRequired(v, 'first name'),
                            capitalization: TextCapitalization.words,
                          ),
                          _field(
                            _middle,
                            'middle_name',
                            'Middle name (optional)',
                            capitalization: TextCapitalization.words,
                          ),
                          _field(
                            _last,
                            'last_name',
                            'Last name',
                            validator: (v) => validateRequired(v, 'last name'),
                            capitalization: TextCapitalization.words,
                          ),
                          _yearDropdown(),
                          _field(
                            _section,
                            'section',
                            'Section (optional)',
                            helper: 'For example: A',
                            capitalization: TextCapitalization.characters,
                            last: true,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    _Section(
                      title: 'Sign-in details',
                      icon: Icons.lock_outline,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _field(
                            _username,
                            'username',
                            'Username',
                            validator: validateUsername,
                            icon: Icons.alternate_email,
                            helper: 'What you type to sign in. No spaces.',
                            autofill: const [AutofillHints.newUsername],
                          ),
                          _field(
                            _password,
                            'password',
                            'Password',
                            validator: validateRegistrationPassword,
                            icon: Icons.lock_outline,
                            obscure: !_showPassword,
                            toggle: _toggle(
                              _showPassword,
                              'password',
                              () => setState(
                                () => _showPassword = !_showPassword,
                              ),
                            ),
                            helper: 'At least 8 characters, not only numbers.',
                            autofill: const [AutofillHints.newPassword],
                          ),
                          _field(
                            _confirm,
                            'confirm_password',
                            'Confirm password',
                            validator: (v) =>
                                validateConfirm(v, _password.text),
                            icon: Icons.lock_outline,
                            obscure: !_showConfirm,
                            toggle: _toggle(
                              _showConfirm,
                              'password',
                              () =>
                                  setState(() => _showConfirm = !_showConfirm),
                            ),
                            last: true,
                          ),
                        ],
                      ),
                    ),
                    if (_banner != null) ...[
                      const SizedBox(height: 16),
                      InlineBanner(
                        message: _banner!,
                        action: _bannerRetry
                            ? TextButton(
                                onPressed: _busy ? null : _submit,
                                child: const Text('Try again'),
                              )
                            : null,
                      ),
                    ],
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      child: _busy
                          ? const SizedBox(
                              height: 22,
                              width: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: AppTheme.onGreen,
                              ),
                            )
                          : const Text('Create account'),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => Navigator.of(context).pop(),
                      child: const Text('Already registered? Back to sign in'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _photoPicker(ColorScheme scheme) {
    final photo = _photo;
    return Column(
      children: [
        GestureDetector(
          onTap: _busy ? null : _choosePhotoSource,
          child: CircleAvatar(
            radius: 48,
            backgroundColor: context.brand.tint,
            backgroundImage: photo == null ? null : MemoryImage(photo),
            child: photo == null
                ? Icon(
                    Icons.person_outline,
                    size: 44,
                    color: context.brand.accent,
                  )
                : null,
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: _busy ? null : _choosePhotoSource,
              icon: const Icon(Icons.photo_camera_outlined),
              label: Text(photo == null ? 'Add photo' : 'Change photo'),
            ),
            if (photo != null)
              TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: scheme.error),
                onPressed: _busy ? null : _removePhoto,
                icon: const Icon(Icons.delete_outline),
                label: const Text('Remove photo'),
              ),
          ],
        ),
        if (_photoError != null) ...[
          const SizedBox(height: 10),
          Text(_photoError!, style: TextStyle(color: scheme.error)),
        ],
      ],
    );
  }

  Widget _yearDropdown() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: DropdownButtonFormField<String>(
        initialValue: _year,
        isExpanded: true,
        decoration: const InputDecoration(
          labelText: 'Year level',
          prefixIcon: Icon(Icons.school_outlined),
        ),
        items: [
          for (final e in yearLevels.entries)
            DropdownMenuItem(value: e.key, child: Text(e.value)),
        ],
        onChanged: _busy ? null : (v) => setState(() => _year = v),
        validator: _check('year_level', validateYearLevel),
      ),
    );
  }

  Widget _toggle(bool shown, String what, VoidCallback onTap) => IconButton(
    tooltip: shown ? 'Hide $what' : 'Show $what',
    icon: Icon(
      shown ? Icons.visibility_outlined : Icons.visibility_off_outlined,
    ),
    onPressed: onTap,
  );

  Widget _field(
    TextEditingController controller,
    String apiField,
    String label, {
    FormFieldValidator<String>? validator,
    TextCapitalization capitalization = TextCapitalization.none,
    IconData? icon,
    String? helper,
    bool obscure = false,
    Widget? toggle,
    Iterable<String>? autofill,
    bool last = false,
  }) {
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 14),
      child: TextFormField(
        controller: controller,
        textCapitalization: capitalization,
        textInputAction: TextInputAction.next,
        enabled: !_busy,
        obscureText: obscure,
        autocorrect: false,
        enableSuggestions: !obscure,
        autofillHints: autofill,
        decoration: InputDecoration(
          labelText: label,
          helperText: helper,
          helperMaxLines: 2,
          prefixIcon: icon == null ? null : Icon(icon),
          suffixIcon: toggle,
        ),
        validator: _check(apiField, validator ?? (_) => null),
      ),
    );
  }
}

/// Titled card grouping a few inputs (same look as the Profile tab sections).
class _Section extends StatelessWidget {
  final String title;
  final IconData icon;
  final Widget child;
  const _Section({
    required this.title,
    required this.icon,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: context.brand.accent),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            child,
          ],
        ),
      ),
    );
  }
}

/// Full-screen "Registration submitted" confirmation.
class _SubmittedView extends StatelessWidget {
  final String message;
  final String username;
  final VoidCallback onDone;
  const _SubmittedView({
    required this.message,
    required this.username,
    required this.onDone,
  });

  @override
  Widget build(BuildContext context) {
    final brand = context.brand;
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(color: scheme.onSurfaceVariant);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 88,
                      height: 88,
                      decoration: BoxDecoration(
                        color: brand.tint,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.check_circle_outline,
                        size: 48,
                        color: brand.accent,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Registration submitted',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(message, textAlign: TextAlign.center, style: muted),
                  const SizedBox(height: 24),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'What happens next',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 12),
                          _Step(
                            Icons.fact_check_outlined,
                            'The Department Adviser reviews your registration.',
                          ),
                          const _Step(
                            Icons.verified_user_outlined,
                            'Once it is approved you can sign in.',
                          ),
                          _Step(
                            Icons.login,
                            username.isEmpty
                                ? 'Sign in with the username and password you just chose.'
                                : 'Sign in as "$username" with the password you just chose.',
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: onDone,
                    child: const Text('Back to sign in'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Step(this.icon, this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: context.brand.accent),
          const SizedBox(width: 12),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}
