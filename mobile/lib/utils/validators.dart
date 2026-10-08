import '../models/student_profile.dart';

/// Non-empty after trimming; [label] names the field in the message.
String? validateRequired(String? v, String label) =>
    (v == null || v.trim().isEmpty) ? 'Enter your $label' : null;

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

// --- Self-registration ------------------------------------------------------

/// Year levels offered at sign-up: API value -> label.
const yearLevels = {
  '1': '1st Year',
  '2': '2nd Year',
  '3': '3rd Year',
  '4': '4th Year',
};

String? validateStudentNumber(String? v) {
  final t = v?.trim() ?? '';
  if (t.isEmpty) return 'Enter your student number';
  if (t.length < 3) return 'That student number looks too short';
  return null;
}

/// Username: required, no spaces, at least 3 characters. Uniqueness and any
/// other character rules are the server's call.
String? validateUsername(String? v) {
  final t = v?.trim() ?? '';
  if (t.isEmpty) return 'Choose a username';
  if (RegExp(r'\s').hasMatch(t)) return 'No spaces in a username';
  if (t.length < 3) return 'Use at least 3 characters';
  return null;
}

String? validateYearLevel(String? v) =>
    (v == null || !yearLevels.containsKey(v)) ? 'Choose your year level' : null;

/// Password for a new account: the quick checks only (the server's Django
/// validators have the final say, and their messages are shown on rejection).
String? validateRegistrationPassword(String? v) {
  if (v == null || v.isEmpty) return 'Choose a password';
  if (v.length < 8) return 'Use at least 8 characters';
  if (RegExp(r'^\d+$').hasMatch(v)) {
    return 'Add some letters; numbers alone are too easy to guess';
  }
  return null;
}

/// The PATCH body: only the editable fields whose trimmed value differs from
/// [current]. Empty map when nothing changed.
Map<String, String> changedProfileFields(
  StudentProfile current, {
  required String firstName,
  required String middleName,
  required String lastName,
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
  void set(
    Map<String, String> messages,
    String Function(String field) valueOf,
  ) {
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
