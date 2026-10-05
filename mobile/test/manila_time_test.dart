import 'package:flutter_test/flutter_test.dart';
import 'package:ite_attendance/utils/manila_time.dart';

void main() {
  test('manilaToday rolls over at 16:00 UTC (midnight in Manila)', () {
    expect(manilaToday(DateTime.utc(2026, 10, 6, 15, 59)), DateTime(2026, 10, 6));
    expect(manilaToday(DateTime.utc(2026, 10, 6, 16, 0)), DateTime(2026, 10, 7));
  });

  test('toManila shifts an offset timestamp to Manila wall time', () {
    final t = DateTime.parse('2026-10-06T08:15:00+08:00');
    final m = toManila(t);
    expect([m.hour, m.minute], [8, 15]);
  });

  test('daysBetween counts calendar days', () {
    expect(daysBetween(DateTime(2026, 10, 6, 23, 59), DateTime(2026, 10, 7, 0, 1)), 1);
    expect(daysBetween(DateTime(2026, 10, 7), DateTime(2026, 10, 6)), -1);
    expect(daysBetween(DateTime(2026, 2, 28), DateTime(2026, 3, 1)), 1);
  });

  test('apiDate pads', () => expect(apiDate(DateTime(2026, 3, 4)), '2026-03-04'));
}
