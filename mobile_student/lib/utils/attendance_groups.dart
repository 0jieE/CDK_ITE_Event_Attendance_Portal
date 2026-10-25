import '../models/attendance_log.dart';
import '../models/attendance_type.dart';
import 'manila_time.dart';

/// Attendance logs of one calendar day.
class DayLogs {
  final DateTime date;
  final List<AttendanceLog> logs;
  const DayLogs(this.date, this.logs);
}

int _slotOrder(String code) {
  final i = AttendanceType.all.indexWhere((t) => t.code == code);
  return i < 0 ? AttendanceType.all.length : i;
}

/// Groups logs by date, newest day first; inside a day the slots follow the
/// natural order (AM in/out, PM in/out), then scan time, then event name.
List<DayLogs> groupLogsByDate(List<AttendanceLog> logs) {
  final byDay = <DateTime, List<AttendanceLog>>{};
  for (final l in logs) {
    byDay.putIfAbsent(dateOnly(l.date), () => []).add(l);
  }
  final days = byDay.keys.toList()..sort((a, b) => b.compareTo(a));
  return [
    for (final d in days)
      DayLogs(
        d,
        byDay[d]!
          ..sort((a, b) {
            final s = _slotOrder(a.attendanceType)
                .compareTo(_slotOrder(b.attendanceType));
            if (s != 0) return s;
            final ta = a.scannedAt, tb = b.scannedAt;
            if (ta != null && tb != null) {
              final t = ta.compareTo(tb);
              if (t != 0) return t;
            }
            return a.eventName.compareTo(b.eventName);
          }),
      ),
  ];
}
