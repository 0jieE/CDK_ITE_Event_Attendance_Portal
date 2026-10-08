import 'package:flutter_test/flutter_test.dart';
import 'package:ite_attendance/models/event_attendance.dart';
import 'package:ite_attendance/utils/attendance_filter.dart';

import 'instructor_fixtures.dart';

EventAttendance load({bool allElapsed = false}) =>
    EventAttendance.fromJson(sampleAttendanceJson(allElapsed: allElapsed));

List<int> ids(List<StudentAttendance> l) => l.map((s) => s.id).toList();

void main() {
  group('filterStudents', () {
    test('all keeps server order', () {
      expect(ids(filterStudents(load())), [5, 6, 7]);
    });

    test('missing = missed > 0', () {
      expect(ids(filterStudents(load(), filter: AttendanceFilter.missing)), [
        6,
      ]);
      expect(
        ids(
          filterStudents(
            load(allElapsed: true),
            filter: AttendanceFilter.missing,
          ),
        ),
        [6, 7],
      );
    });

    test('complete needs every slot attended AND every window closed', () {
      // Slot 2 still open: nobody is complete yet.
      expect(
        ids(filterStudents(load(), filter: AttendanceFilter.complete)),
        isEmpty,
      );
      // Everything closed: only Maria scanned both slots.
      expect(
        ids(
          filterStudents(
            load(allElapsed: true),
            filter: AttendanceFilter.complete,
          ),
        ),
        [5],
      );
    });

    test(
      'scanning every slot is not "complete" while a window is still open',
      () {
        final j = sampleAttendanceJson();
        final maria = (j['students'] as List)[0] as Map<String, dynamic>;
        maria['slots'] = [
          cellJson('AM_IN', 'PRESENT', '2026-10-08T07:12:09+08:00'),
          cellJson('AM_OUT', 'PRESENT', '2026-10-08T11:40:00+08:00'),
        ];
        maria['attended'] = 2;
        final data = EventAttendance.fromJson(j);
        expect(
          filterStudents(data, filter: AttendanceFilter.complete),
          isEmpty,
        );
      },
    );

    test('an event with no slots has no complete students', () {
      final j = sampleAttendanceJson()..['slots'] = [];
      final data = EventAttendance.fromJson(j);
      expect(filterStudents(data, filter: AttendanceFilter.complete), isEmpty);
    });

    test('search matches name or number, case-insensitively', () {
      expect(ids(filterStudents(load(), query: 'maria')), [5]);
      expect(ids(filterStudents(load(), query: '  CRUZ ')), [6]);
      expect(ids(filterStudents(load(), query: 'demo-003')), [7]);
      expect(ids(filterStudents(load(), query: 'demo')), [5, 6, 7]);
      expect(filterStudents(load(), query: 'zzz'), isEmpty);
    });

    test('search and filter combine', () {
      expect(
        ids(
          filterStudents(
            load(allElapsed: true),
            filter: AttendanceFilter.missing,
            query: 'ana',
          ),
        ),
        [7],
      );
      expect(
        filterStudents(
          load(allElapsed: true),
          filter: AttendanceFilter.complete,
          query: 'ana',
        ),
        isEmpty,
      );
    });
  });

  test('filterCounts ignores the search text', () {
    final counts = filterCounts(load(allElapsed: true));
    expect(counts[AttendanceFilter.all], 3);
    expect(counts[AttendanceFilter.missing], 2);
    expect(counts[AttendanceFilter.complete], 1);
  });

  group('headline', () {
    test('talks about the latest closed slot', () {
      final d = load();
      expect(focusSlot(d)!.type, 'AM_IN');
      expect(attendanceHeadline(d), '2 of 3 present · AM Time-In');
      final all = load(allElapsed: true);
      expect(focusSlot(all)!.type, 'AM_OUT');
      expect(attendanceHeadline(all), '1 of 3 present · AM Time-Out');
    });

    test('before anything closed, falls back to the first slot "so far"', () {
      final j = sampleAttendanceJson();
      for (final s in j['slots'] as List) {
        (s as Map<String, dynamic>)['elapsed'] = false;
        s['present'] = 0;
      }
      final d = EventAttendance.fromJson(j);
      expect(focusSlot(d)!.type, 'AM_IN');
      expect(attendanceHeadline(d), '0 of 3 present so far · AM Time-In');
    });

    test('no slots -> no headline', () {
      final d = EventAttendance.fromJson(
        sampleAttendanceJson()..['slots'] = [],
      );
      expect(attendanceHeadline(d), isNull);
    });
  });

  group('slotPhase', () {
    SlotSummary slot({required bool elapsed, String? start = '07:00:00'}) =>
        SlotSummary(
          type: 'AM_IN',
          label: 'AM Time-In',
          windowStart: start,
          windowEnd: '08:00:00',
          elapsed: elapsed,
          present: 0,
          absent: 0,
          pending: 0,
        );

    test('closed whenever elapsed', () {
      expect(
        slotPhase(
          slot(elapsed: true),
          isToday: false,
          nowManila: DateTime(2026, 10, 8, 6),
        ),
        SlotPhase.closed,
      );
    });

    test('open once the window began today, not yet before it', () {
      expect(
        slotPhase(
          slot(elapsed: false),
          isToday: true,
          nowManila: DateTime(2026, 10, 8, 7, 30),
        ),
        SlotPhase.open,
      );
      expect(
        slotPhase(
          slot(elapsed: false),
          isToday: true,
          nowManila: DateTime(2026, 10, 8, 6, 59),
        ),
        SlotPhase.notYet,
      );
      expect(
        slotPhase(
          slot(elapsed: false),
          isToday: true,
          nowManila: DateTime(2026, 10, 8, 7, 0),
        ),
        SlotPhase.open,
      );
    });

    test('a future day or an unknown start is "not yet"', () {
      expect(
        slotPhase(
          slot(elapsed: false),
          isToday: false,
          nowManila: DateTime(2026, 10, 8, 12),
        ),
        SlotPhase.notYet,
      );
      expect(
        slotPhase(
          slot(elapsed: false, start: null),
          isToday: true,
          nowManila: DateTime(2026, 10, 8, 12),
        ),
        SlotPhase.notYet,
      );
    });
  });

  group('formatting', () {
    test('formatClock', () {
      expect(formatClock('07:00:00'), '7:00 AM');
      expect(formatClock('13:05'), '1:05 PM');
      expect(formatClock(null), '');
      expect(formatClock('soon'), 'soon');
    });

    test('shortSlotLabel', () {
      expect(shortSlotLabel('AM_IN'), 'AM-In');
      expect(shortSlotLabel('AM_OUT'), 'AM-Out');
      expect(shortSlotLabel('PM_IN'), 'PM-In');
      expect(shortSlotLabel('PM_OUT'), 'PM-Out');
    });

    test(
      'formatScanTime shows Manila time whatever zone the instant is in',
      () {
        expect(
          formatScanTime(DateTime.parse('2026-10-08T07:12:09+08:00')),
          '7:12 AM',
        );
        expect(
          formatScanTime(DateTime.parse('2026-10-07T23:12:09Z')),
          '7:12 AM',
        );
      },
    );
  });
}
