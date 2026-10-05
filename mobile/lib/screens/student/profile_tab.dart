import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../models/student_profile.dart';
import '../../services/api_service.dart';
import '../../services/auth_provider.dart';
import '../../theme/app_theme.dart';
import '../../utils/errors.dart';
import '../../utils/image_type.dart';
import '../../utils/validators.dart';
import '../../widgets/logout_action.dart';
import '../../widgets/profile_avatar.dart';
import '../../widgets/state_message.dart';
import 'change_password_screen.dart';

/// Server's upload limit for profile photos.
const _maxPhotoBytes = 5 * 1024 * 1024;

/// The student's profile: photo, editable account details, read-only school
/// info, password change and logout.
class ProfileTab extends StatefulWidget {
  const ProfileTab({super.key});

  @override
  State<ProfileTab> createState() => _ProfileTabState();
}

class _ProfileTabState extends State<ProfileTab> {
  final _formKey = GlobalKey<FormState>();
  final _first = TextEditingController();
  final _middle = TextEditingController();
  final _last = TextEditingController();
  final _email = TextEditingController();
  final _username = TextEditingController();
  final _picker = ImagePicker();

  StudentProfile? _profile;
  bool _loading = true;
  String? _loadError;

  bool _saving = false;
  bool _photoBusy = false;
  String? _formError;

  /// Server-side field errors; each disappears once its input is edited.
  final _serverErrors = ServerFieldErrors();

  late final List<TextEditingController> _all = [
    _first,
    _middle,
    _last,
    _email,
    _username,
  ];

  @override
  void initState() {
    super.initState();
    for (final c in _all) {
      c.addListener(_onEdited);
    }
    _load();
  }

  @override
  void dispose() {
    for (final c in _all) {
      c.dispose();
    }
    super.dispose();
  }

  void _onEdited() => setState(() {});

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _loadError = null;
      });
    }
    try {
      final p = await context.read<ApiService>().studentProfile();
      if (!mounted) return;
      _fill(p);
      setState(() {
        _profile = p;
        _loading = false;
        _loadError = null;
      });
    } on SessionExpired {
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = friendlyError(e);
        _loading = false;
      });
    }
  }

  /// Puts [p]'s values in the inputs (without flagging them as edits).
  void _fill(StudentProfile p) {
    _first.text = p.firstName;
    _middle.text = p.middleName;
    _last.text = p.lastName;
    _email.text = p.email;
    _username.text = p.username;
    _serverErrors.clear();
    _formError = null;
  }

  Map<String, String> _changes() {
    final p = _profile;
    if (p == null) return const {};
    return changedProfileFields(
      p,
      firstName: _first.text,
      middleName: _middle.text,
      lastName: _last.text,
      email: _email.text,
      username: _username.text,
    );
  }

  /// Wraps a validator so a server error for [field] shows (while the value
  /// is unchanged) when the client validation passes.
  FormFieldValidator<String> _check(
      String field, FormFieldValidator<String> client) {
    return (v) => client(v) ?? _serverErrors.forField(field, v);
  }

  late final Map<String, TextEditingController> _byField = {
    'first_name': _first,
    'middle_name': _middle,
    'last_name': _last,
    'email': _email,
    'username': _username,
  };

  Future<void> _save() async {
    _serverErrors.clear();
    if (!_formKey.currentState!.validate()) return;
    final changes = _changes();
    if (changes.isEmpty) return;

    if (changes.containsKey('username')) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Change username?'),
          content: Text(
            'Your username is what you type to sign in. After saving, sign in '
            'with "${changes['username']}" instead of your old username.',
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Change username')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }

    FocusScope.of(context).unfocus();
    final api = context.read<ApiService>();
    final auth = context.read<AuthProvider>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _saving = true;
      _formError = null;
    });
    try {
      final updated = await api.updateProfile(changes);
      if (!mounted) return;
      auth.applyProfile(updated);
      setState(() => _profile = updated);
      _fill(updated);
      messenger.showSnackBar(SnackBar(
        content: Text(changes.containsKey('username')
            ? 'Profile updated. Use your new username next time you sign in.'
            : 'Profile updated.'),
      ));
    } on SessionExpired {
      return;
    } catch (e) {
      if (!mounted) return;
      final fields = fieldErrors(e);
      setState(() {
        _serverErrors.set(fields, (f) => _byField[f]?.text ?? '');
        // Errors for fields we don't show (or a plain `detail`) go in a banner.
        final other = fields.keys.any((k) => !_byField.containsKey(k));
        _formError = (fields.isEmpty || other) ? friendlyError(e) : null;
      });
      _formKey.currentState!.validate(); // paint the server errors
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // --- Photo ---------------------------------------------------------------
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
    if (source != null) await _pickAndUpload(source);
  }

  Future<void> _pickAndUpload(ImageSource source) async {
    final api = context.read<ApiService>();
    final auth = context.read<AuthProvider>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      // Downscale + recompress before upload (keeps it well under 5 MB).
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
        messenger.showSnackBar(const SnackBar(
            content: Text('Unsupported image. Please use a JPG, PNG or WebP.')));
        return;
      }
      if (bytes.length > _maxPhotoBytes) {
        messenger.showSnackBar(const SnackBar(
            content: Text('That photo is too large (max 5 MB).')));
        return;
      }
      if (!mounted) return;
      setState(() => _photoBusy = true);
      var url = await api.uploadPhoto(bytes, type);
      // Fall back to the profile endpoint if the upload reply had no URL.
      url ??= (await api.studentProfile()).profileImage;
      _applyPhoto(auth, url);
      messenger.showSnackBar(const SnackBar(content: Text('Photo updated.')));
    } on PlatformException catch (e) {
      final denied = e.code.contains('access_denied');
      messenger.showSnackBar(SnackBar(
        content: Text(denied
            ? (source == ImageSource.camera
                ? 'Camera access is turned off. Allow it in your phone settings.'
                : 'Photo access is turned off. Allow it in your phone settings.')
            : 'Could not open the picker. Please try again.'),
      ));
    } on SessionExpired {
      return;
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
    } finally {
      if (mounted) setState(() => _photoBusy = false);
    }
  }

  Future<void> _removePhoto() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove photo?'),
        content: const Text('Your profile picture will be deleted.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final api = context.read<ApiService>();
    final auth = context.read<AuthProvider>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _photoBusy = true);
    try {
      await api.deletePhoto();
      _applyPhoto(auth, null);
      messenger.showSnackBar(const SnackBar(content: Text('Photo removed.')));
    } on SessionExpired {
      return;
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
    } finally {
      if (mounted) setState(() => _photoBusy = false);
    }
  }

  void _applyPhoto(AuthProvider auth, String? url) {
    // The URL may be unchanged after a re-upload; drop cached bitmaps so the
    // new picture shows everywhere.
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    auth.setPhoto(url);
    if (mounted && _profile != null) {
      setState(() => _profile = _profile!.withPhoto(url));
    }
  }

  // --- UI -------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final profile = _profile;
    if (profile == null) {
      return StateMessage(
        icon: Icons.cloud_off,
        isError: true,
        title: 'Could not load your profile',
        subtitle: _loadError,
        actionLabel: 'Retry',
        onAction: _load,
      );
    }
    final user = context.watch<AuthProvider>().user;
    final photo = user?.profileImage ?? profile.profileImage;
    final name = (user?.fullName.isNotEmpty ?? false)
        ? user!.fullName
        : profile.fullName;
    final changed = _changes().isNotEmpty;

    return RefreshIndicator(
      onRefresh: () => _load(silent: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          _PhotoCard(
            name: name,
            subtitle: profile.studentNumber,
            photoUrl: photo,
            busy: _photoBusy,
            onChange: _photoBusy ? null : _choosePhotoSource,
            onRemove: (_photoBusy || photo == null || photo.isEmpty)
                ? null
                : _removePhoto,
          ),
          const SizedBox(height: 16),
          _SectionCard(
            title: 'Account details',
            icon: Icons.badge_outlined,
            child: Form(
              key: _formKey,
              autovalidateMode: AutovalidateMode.onUserInteraction,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _field(_first, 'first_name', 'First name',
                      validator: (v) => validateRequired(v, 'first name'),
                      capitalization: TextCapitalization.words),
                  _field(_middle, 'middle_name', 'Middle name (optional)',
                      capitalization: TextCapitalization.words),
                  _field(_last, 'last_name', 'Last name',
                      validator: (v) => validateRequired(v, 'last name'),
                      capitalization: TextCapitalization.words),
                  _field(_email, 'email', 'Email',
                      validator: validateEmail,
                      keyboard: TextInputType.emailAddress,
                      icon: Icons.mail_outline),
                  _field(_username, 'username', 'Username',
                      validator: (v) => validateRequired(v, 'username'),
                      icon: Icons.alternate_email,
                      helper: 'This is what you type to sign in. If you change '
                          'it, use the new username next time.',
                      last: true),
                  if (_formError != null) ...[
                    const SizedBox(height: 12),
                    InlineBanner(message: _formError!),
                  ],
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    style: AppTheme.wide,
                    onPressed: (_saving || !changed) ? null : _save,
                    icon: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: AppTheme.onGreen))
                        : const Icon(Icons.save_outlined),
                    label: Text(_saving ? 'Saving…' : 'Save changes'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          _SectionCard(
            title: 'School information',
            icon: Icons.school_outlined,
            subtitle: 'Managed by your adviser. Ask them if something is wrong.',
            child: Column(
              children: [
                _InfoRow('Student number', profile.studentNumber),
                const Divider(),
                _InfoRow(
                    'Year & Section',
                    profile.yearSection.isNotEmpty
                        ? profile.yearSection
                        : profile.yearLevelDisplay),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: ListTile(
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              leading: Icon(Icons.lock_outline, color: context.brand.accent),
              title: const Text('Change password',
                  style: TextStyle(fontWeight: FontWeight.w700)),
              subtitle: const Text('Update the password you sign in with'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                    builder: (_) => const ChangePasswordScreen()),
              ),
            ),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => confirmLogout(context),
            icon: const Icon(Icons.logout),
            label: const Text('Log out'),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String apiField,
    String label, {
    FormFieldValidator<String>? validator,
    TextInputType? keyboard,
    TextCapitalization capitalization = TextCapitalization.none,
    IconData? icon,
    String? helper,
    bool last = false,
  }) {
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 14),
      child: TextFormField(
        controller: controller,
        keyboardType: keyboard,
        textCapitalization: capitalization,
        textInputAction: last ? TextInputAction.done : TextInputAction.next,
        enabled: !_saving,
        autocorrect: false,
        decoration: InputDecoration(
          labelText: label,
          helperText: helper,
          helperMaxLines: 3,
          prefixIcon: icon == null ? null : Icon(icon),
        ),
        validator: _check(apiField, validator ?? (_) => null),
      ),
    );
  }
}

/// Avatar with photo actions.
class _PhotoCard extends StatelessWidget {
  final String name;
  final String subtitle;
  final String? photoUrl;
  final bool busy;
  final VoidCallback? onChange;
  final VoidCallback? onRemove;

  const _PhotoCard({
    required this.name,
    required this.subtitle,
    required this.photoUrl,
    required this.busy,
    required this.onChange,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            GestureDetector(
              onTap: onChange,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  ProfileAvatar(imageUrl: photoUrl, name: name, radius: 54),
                  if (busy)
                    Container(
                      width: 108,
                      height: 108,
                      decoration: const BoxDecoration(
                          color: Color(0x80000000), shape: BoxShape.circle),
                      child: const Center(
                        child: SizedBox(
                          width: 30,
                          height: 30,
                          child: CircularProgressIndicator(
                              strokeWidth: 3, color: Colors.white),
                        ),
                      ),
                    ),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: AppTheme.green,
                        shape: BoxShape.circle,
                        border: Border.all(color: scheme.surface, width: 3),
                      ),
                      child: const Icon(Icons.photo_camera,
                          size: 18, color: AppTheme.onGreen),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Text(name,
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            Text(subtitle, style: TextStyle(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: onChange,
                  icon: const Icon(Icons.photo_camera_outlined),
                  label: const Text('Change photo'),
                ),
                TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: scheme.error),
                  onPressed: onRemove,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Remove photo'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final String title;
  final String? subtitle;
  final IconData icon;
  final Widget child;
  const _SectionCard({
    required this.title,
    required this.icon,
    required this.child,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
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
                Text(title,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w800)),
              ],
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(subtitle!,
                  style:
                      TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
            ],
            const SizedBox(height: 16),
            child,
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(child: Text(label, style: TextStyle(color: muted))),
          Flexible(
            child: Text(value.isEmpty ? '—' : value,
                textAlign: TextAlign.end,
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 8),
          Icon(Icons.lock_outline, size: 16, color: muted),
        ],
      ),
    );
  }
}
