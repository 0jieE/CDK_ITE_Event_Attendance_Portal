import 'package:flutter_test/flutter_test.dart';
import 'package:ite_attendance/utils/event_status.dart';

import 'test_helpers.dart';

void main() {
  final today = DateTime(2026, 10, 8);

  group('eventStatus', () {
    test('ongoing includes the first and last day', () {
      expect(
        eventStatus(ev(1, '2026-10-08', '2026-10-10'), today),
        EventStatus.ongoing,
      );
      expect(
        eventStatus(ev(1, '2026-10-06', '2026-10-08'), today),
        EventStatus.ongoing,
      );
      expect(
        eventStatus(ev(1, '2026-10-08', '2026-10-08'), today),
        EventStatus.ongoing,
      );
    });

    test('upcoming starts tomorrow or later, finished ended yesterday', () {
      expect(
        eventStatus(ev(1, '2026-10-09', '2026-10-09'), today),
        EventStatus.upcoming,
      );
      expect(
        eventStatus(ev(1, '2026-10-06', '2026-10-07'), today),
        EventStatus.finished,
      );
    });

    test('time of day on `today` does not matter', () {
      expect(
        eventStatus(
          ev(1, '2026-10-08', '2026-10-08'),
          DateTime(2026, 10, 8, 23, 59),
        ),
        EventStatus.ongoing,
      );
    });

    test('labels', () {
      expect(EventStatus.ongoing.label, 'Ongoing');
      expect(EventStatus.upcoming.label, 'Upcoming');
      expect(EventStatus.finished.label, 'Finished');
    });
  });

  group('sortEventsForAttendance', () {
    test(
      'ongoing, then upcoming (soonest first), then finished (latest first)',
      () {
        final events = [
          ev(1, '2026-01-01', '2026-01-02'), // finished, old
          ev(2, '2026-12-01', '2026-12-02'), // upcoming, later
          ev(3, '2026-10-07', '2026-10-09'), // ongoing
          ev(4, '2026-09-01', '2026-09-03'), // finished, recent
          ev(5, '2026-10-20', '2026-10-21'), // upcoming, soon
        ];
        final sorted = sortEventsForAttendance(events, today);
        expect(sorted.map((e) => e.id), [3, 5, 2, 4, 1]);
      },
    );

    test('ties are stable: higher id first, and the input is not mutated', () {
      final events = [
        ev(1, '2026-10-20', '2026-10-21'),
        ev(2, '2026-10-20', '2026-10-21'),
      ];
      final sorted = sortEventsForAttendance(events, today);
      expect(sorted.map((e) => e.id), [2, 1]);
      expect(events.map((e) => e.id), [1, 2]);
    });

    test('ongoing events ending soonest come first', () {
      final sorted = sortEventsForAttendance([
        ev(1, '2026-10-01', '2026-10-30'),
        ev(2, '2026-10-05', '2026-10-09'),
      ], today);
      expect(sorted.map((e) => e.id), [2, 1]);
    });

    test('empty list', () {
      expect(sortEventsForAttendance(const [], today), isEmpty);
    });
  });

  group('filterEventsByName', () {
    final events = [
      ev(1, '2026-10-01', '2026-10-02'),
      ev(2, '2026-10-01', '2026-10-02'),
    ];
    test('blank query keeps everything; match is case-insensitive', () {
      expect(filterEventsByName(events, '  '), events);
      expect(filterEventsByName(events, 'EVENT 2').map((e) => e.id), [2]);
      expect(filterEventsByName(events, 'nope'), isEmpty);
    });
  });

  group('eventRangeLabel', () {
    test('range and single day', () {
      expect(
        eventRangeLabel(ev(1, '2026-10-06', '2026-10-10')),
        'Oct 6 – Oct 10, 2026',
      );
      expect(eventRangeLabel(ev(1, '2026-10-06', '2026-10-06')), 'Oct 6, 2026');
    });
  });
}
