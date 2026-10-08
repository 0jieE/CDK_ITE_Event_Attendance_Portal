import 'package:flutter_test/flutter_test.dart';
import 'package:ite_attendance/models/event_attendance.dart';

import 'instructor_fixtures.dart';

void main() {
  group('EventAttendance.fromJson', () {
    final data = EventAttendance.fromJson(sampleAttendanceJson());

    test('parses the event, day, selector dates and flags', () {
      expect(data.event.id, 3);
      expect(data.event.name, 'ITE Tech Week 2026');
      expect(data.event.startDate, DateTime(2026, 10, 6));
      expect(data.event.endDate, DateTime(2026, 10, 10));
      expect(data.event.isActive, isTrue);
      expect(data.date, DateTime(2026, 10, 8));
      expect(data.dates, [
        DateTime(2026, 10, 6),
        DateTime(2026, 10, 8),
        DateTime(2026, 10, 10),
      ]);
      expect(data.isToday, isTrue);
    });

    test('parses slot summaries in order', () {
      expect(data.slots.map((s) => s.type), ['AM_IN', 'AM_OUT']);
      final am = data.slots.first;
      expect(am.label, 'AM Time-In');
      expect(am.windowStart, '07:00:00');
      expect(am.elapsed, isTrue);
      expect((am.present, am.absent, am.pending), (2, 1, 0));
      expect(data.slots.last.elapsed, isFalse);
      expect(data.slots.last.pending, 3);
    });

    test('parses students, including a PENDING cell and a null photo', () {
      expect(data.students.length, 3);
      final maria = data.students.first;
      expect(maria.fullName, 'Maria Santos');
      expect(maria.studentNumber, 'DEMO-001');
      expect(maria.yearSection, '2nd Year A');
      expect(maria.photo, isNull);
      expect(maria.attended, 1);
      expect(maria.missed, 0);
      expect(maria.slots[0].status, SlotStatus.present);
      // 07:12:09+08:00 == 23:12:09Z the previous day.
      expect(
        maria.slots[0].scannedAt!.toUtc(),
        DateTime.utc(2026, 10, 7, 23, 12, 9),
      );
      expect(maria.slots[1].status, SlotStatus.pending);
      expect(maria.slots[1].scannedAt, isNull);

      final juan = data.students[1];
      expect(juan.photo, 'https://example.com/juan.jpg');
      expect(juan.slots[0].status, SlotStatus.absent);
      expect(juan.missed, 1);
      expect(data.students[2].slots[0].status, SlotStatus.late);
    });

    test('empty photo string is treated as no photo', () {
      final j = sampleAttendanceJson();
      (j['students'] as List)[0]['photo'] = '';
      expect(EventAttendance.fromJson(j).students.first.photo, isNull);
    });

    test('falls back to the single day when `dates` is missing', () {
      final j = sampleAttendanceJson()..remove('dates');
      final d = EventAttendance.fromJson(j);
      expect(d.dates, isEmpty);
      expect(d.selectableDates, [DateTime(2026, 10, 8)]);
    });
  });

  group('SlotStatus', () {
    test('parse maps the API strings; unknown reads as pending', () {
      expect(SlotStatus.parse('PRESENT'), SlotStatus.present);
      expect(SlotStatus.parse('LATE'), SlotStatus.late);
      expect(SlotStatus.parse('ABSENT'), SlotStatus.absent);
      expect(SlotStatus.parse('PENDING'), SlotStatus.pending);
      expect(SlotStatus.parse(null), SlotStatus.pending);
      expect(SlotStatus.parse('???'), SlotStatus.pending);
    });

    test('code is the badge key and isAttended covers present + late', () {
      expect(SlotStatus.late.code, 'LATE');
      expect(SlotStatus.pending.code, 'PENDING');
      expect(SlotStatus.present.isAttended, isTrue);
      expect(SlotStatus.late.isAttended, isTrue);
      expect(SlotStatus.absent.isAttended, isFalse);
      expect(SlotStatus.pending.isAttended, isFalse);
    });
  });
}
