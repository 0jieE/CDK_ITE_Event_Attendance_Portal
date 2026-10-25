/// The four daily attendance slots, matching the backend `AttendanceType`.
class AttendanceType {
  final String code;
  final String label;
  const AttendanceType(this.code, this.label);

  static const amIn = AttendanceType('AM_IN', 'AM Time-In');
  static const amOut = AttendanceType('AM_OUT', 'AM Time-Out');
  static const pmIn = AttendanceType('PM_IN', 'PM Time-In');
  static const pmOut = AttendanceType('PM_OUT', 'PM Time-Out');

  static const all = [amIn, amOut, pmIn, pmOut];

  /// Human label for a backend code (falls back to the raw code).
  static String labelFor(String code) {
    for (final t in all) {
      if (t.code == code) return t.label;
    }
    return code;
  }
}
