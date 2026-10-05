import '../models/student_profile.dart';

final _emailRe = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

/// Non-empty after trimming; [label] names the field in the message.
String? validateRequired(String? v, String label) =>
    (v == null || v.trim().isEmpty) ? 'Enter your $label' : null;

String? validateEmail(String? v) {
  final t = v?.trim() ?? '';
  if (t.isEmpty) return 'Enter your email';
  if (!_emailRe.hasMatch(t)) return 'Enter a valid email address';
  return null;
}

/// Quick client-side checks only; the server's Django validators (min length,
/// too common, all-numeric, similar to user info) are the authority and their
/// messages are shown when it rejects the password.
String? validateNewPassword(String? v) {
  if (v == null || v.isEmpty) return 'Enter a new password';
  if (v.length < 8) return 'Use at least 8 characters';
  return null;
}

String? validateConfirm(String? confirm, String newPassword) {
  if (confirm == null || confirm.isEmpty) return 'Confirm your new password';
  if (confirm != newPassword) return 'Passwords do not match';
  return null;
}

/// The PATCH body: only the editable fields whose trimmed value differs from
/// [current]. Empty map when nothing changed.
Map<String, String> changedProfileFields(
  StudentProfile current, {
  required String firstName,
  required String middleName,
  required String lastName,
  required String email,
  required String username,
}) {
  final out = <String, String>{};
  void diff(String key, String oldValue, String newValue) {
    final t = newValue.trim();
    if (t != oldValue.trim()) out[key] = t;
  }

  diff('first_name', current.firstName, firstName);
  diff('middle_name', current.middleName, middleName);
  diff('last_name', current.lastName, lastName);
  diff('email', current.email, email);
  diff('username', current.username, username);
  return out;
}

/// Server-side field errors, each tied to the value that triggered it so the
/// message disappears the moment the student edits that field.
class ServerFieldErrors {
  final Map<String, ({String message, String value})> _errors = {};

  bool get isEmpty => _errors.isEmpty;

  void clear() => _errors.clear();

  /// Record [messages] (field -> message); [valueOf] gives each field's
  /// current text.
  void set(Map<String, String> messages, String Function(String field) valueOf) {
    _errors
      ..clear()
      ..addAll({
        for (final e in messages.entries)
          e.key: (message: e.value, value: valueOf(e.key)),
      });
  }

  /// The message for [field] while its text is still [currentValue].
  String? forField(String field, String? currentValue) {
    final e = _errors[field];
    return (e != null && e.value == (currentValue ?? '')) ? e.message : null;
  }
}
