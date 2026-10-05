import 'package:flutter_test/flutter_test.dart';
import 'package:ite_attendance/models/attendance_log.dart';
import 'package:ite_attendance/utils/attendance_groups.dart';

AttendanceLog log(int id, String date, String type, {String? at}) =>
    AttendanceLog.fromJson({
      'id': id,
      'event': 1,
      'event_name': 'Foundation Day',
      'date': date,
      'attendance_type': type,
      'attendance_type_display': type,
      'status': 'PRESENT',
      'scanned_at': at,
    });

void main() {
  test('groups by date, newest day first, slots in natural order', () {
    final groups = groupLogsByDate([
      log(1, '2026-10-05', 'PM_IN'),
      log(2, '2026-10-06', 'AM_OUT'),
      log(3, '2026-10-06', 'AM_IN'),
      log(4, '2026-10-05', 'AM_IN'),
      log(5, '2026-10-06', 'PM_OUT'),
    ]);
    expect(groups.map((g) => g.date), [DateTime(2026, 10, 6), DateTime(2026, 10, 5)]);
    expect(groups[0].logs.map((l) => l.attendanceType), ['AM_IN', 'AM_OUT', 'PM_OUT']);
    expect(groups[1].logs.map((l) => l.attendanceType), ['AM_IN', 'PM_IN']);
  });

  test('empty input -> no groups', () {
    expect(groupLogsByDate(const []), isEmpty);
  });
}
