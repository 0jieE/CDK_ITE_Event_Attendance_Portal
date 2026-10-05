import 'package:flutter_test/flutter_test.dart';
import 'package:ite_attendance/utils/event_dates.dart';

import 'test_helpers.dart';

void main() {
  final today = DateTime(2026, 10, 6);

  group('dayAvailability', () {
    test('compares by calendar day, ignoring time of day', () {
      expect(dayAvailability(DateTime(2026, 10, 6), DateTime(2026, 10, 6, 23, 59)),
          DayAvailability.today);
      expect(dayAvailability(DateTime(2026, 10, 6, 23, 59), DateTime(2026, 10, 6, 0, 1)),
          DayAvailability.today);
      expect(dayAvailability(DateTime(2026, 10, 5, 23, 59), DateTime(2026, 10, 6, 0, 1)),
          DayAvailability.past);
      expect(dayAvailability(DateTime(2026, 10, 7), DateTime(2026, 10, 6, 23, 59)),
          DayAvailability.upcoming);
    });
  });

  group('eventDays / selectableDay', () {
    test('multi-day event: only today is selectable', () {
      final e = ev(1, '2026-10-05', '2026-10-08');
      final days = eventDays(e, today);
      expect(days.length, 4);
      expect(days.map((d) => d.availability), [
        DayAvailability.past,
        DayAvailability.today,
        DayAvailability.upcoming,
        DayAvailability.upcoming,
      ]);
      expect(days.where((d) => d.selectable).length, 1);
      expect(days.map((d) => d.hint), ['Past', 'Today', 'Upcoming', 'Upcoming']);
      expect(selectableDay(e, today), DateTime(2026, 10, 6));
    });

    test('today outside the range: nothing selectable', () {
      final before = ev(1, '2026-10-07', '2026-10-09');
      final after = ev(2, '2026-10-01', '2026-10-05');
      for (final e in [before, after]) {
        expect(isRunningOn(e, today), isFalse);
        expect(selectableDay(e, today), isNull);
        expect(eventDays(e, today).any((d) => d.selectable), isFalse);
      }
    });

    test('range edges are inclusive', () {
      expect(isRunningOn(ev(1, '2026-10-06', '2026-10-09'), today), isTrue);
      expect(isRunningOn(ev(1, '2026-10-01', '2026-10-06'), today), isTrue);
    });

    test('single-day event today', () {
      final e = ev(1, '2026-10-06', '2026-10-06');
      expect(eventDays(e, today).single.selectable, isTrue);
    });

    test('spans a month boundary without skipping days', () {
      final e = ev(1, '2026-03-28', '2026-04-02');
      expect(e.dateRange.length, 6);
      expect(eventDays(e, DateTime(2026, 3, 31)).where((d) => d.selectable).length, 1);
    });
  });

  group('pickClosestEvent', () {
    test('empty list -> null', () {
      expect(pickClosestEvent(const [], today), isNull);
    });

    test('event containing today wins over nearer-looking ones', () {
      final far = ev(1, '2026-10-01', '2026-10-30'); // contains today
      final near = ev(2, '2026-10-07', '2026-10-07'); // tomorrow
      expect(pickClosestEvent([near, far], today)!.id, 1);
    });

    test('otherwise nearest range by days, either side', () {
      final past = ev(1, '2026-09-20', '2026-10-03'); // ended 3 days ago
      final future = ev(2, '2026-10-12', '2026-10-13'); // starts in 6 days
      expect(pickClosestEvent([future, past], today)!.id, 1);

      final pastFar = ev(3, '2026-09-01', '2026-09-02'); // 34 days
      final futureNear = ev(4, '2026-10-08', '2026-10-09'); // 2 days
      expect(pickClosestEvent([pastFar, futureNear], today)!.id, 4);
    });

    test('distance uses the nearest edge of the range', () {
      expect(distanceFromToday(ev(1, '2026-10-01', '2026-10-05'), today), 1);
      expect(distanceFromToday(ev(1, '2026-10-08', '2026-10-20'), today), 2);
      expect(distanceFromToday(ev(1, '2026-10-06', '2026-10-06'), today), 0);
    });

    test('tie between past and upcoming prefers the upcoming one', () {
      final past = ev(1, '2026-10-01', '2026-10-03'); // 3 days ago
      final upcoming = ev(2, '2026-10-09', '2026-10-10'); // in 3 days
      expect(pickClosestEvent([past, upcoming], today)!.id, 2);
      expect(pickClosestEvent([upcoming, past], today)!.id, 2);
    });

    test('tie on the same side prefers the more recent start', () {
      final a = ev(1, '2026-10-01', '2026-10-03');
      final b = ev(2, '2026-09-20', '2026-10-03'); // same end -> same distance
      expect(pickClosestEvent([a, b], today)!.id, 1);
      expect(pickClosestEvent([b, a], today)!.id, 1);
    });

    test('two events containing today prefer the more recent start', () {
      final a = ev(1, '2026-10-01', '2026-10-10');
      final b = ev(2, '2026-10-05', '2026-10-07');
      expect(pickClosestEvent([a, b], today)!.id, 2);
    });
  });
}
