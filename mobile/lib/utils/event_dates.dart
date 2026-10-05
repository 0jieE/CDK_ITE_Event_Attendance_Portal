import '../models/event.dart';
import 'manila_time.dart';

/// Where a calendar day sits relative to "today".
enum DayAvailability { past, today, upcoming }

/// One day of an event with its availability for QR generation.
class EventDay {
  final DateTime date;
  final DayAvailability availability;
  const EventDay(this.date, this.availability);

  /// Only today can be generated (the server enforces the same rule).
  bool get selectable => availability == DayAvailability.today;

  /// Short hint shown next to the day.
  String get hint {
    switch (availability) {
      case DayAvailability.past:
        return 'Past';
      case DayAvailability.upcoming:
        return 'Upcoming';
      case DayAvailability.today:
        return 'Today';
    }
  }
}

/// Compares by calendar day only (no time-of-day bugs).
DayAvailability dayAvailability(DateTime day, DateTime today) {
  final diff = daysBetween(today, day);
  if (diff == 0) return DayAvailability.today;
  return diff < 0 ? DayAvailability.past : DayAvailability.upcoming;
}

/// Every day of [event] (start..end inclusive) tagged relative to [today].
List<EventDay> eventDays(Event event, DateTime today) {
  return [
    for (final d in event.dateRange) EventDay(d, dayAvailability(d, today)),
  ];
}

/// Is [today] inside the event's start..end range (calendar days)?
bool isRunningOn(Event event, DateTime today) =>
    daysBetween(event.startDate, today) >= 0 &&
    daysBetween(today, event.endDate) >= 0;

/// The one selectable day (today) or null when the event isn't running today.
DateTime? selectableDay(Event event, DateTime today) =>
    isRunningOn(event, today) ? dateOnly(today) : null;

/// Distance in days between [today] and the event's range: 0 when today is
/// inside it, otherwise the gap to the nearest edge (before or after).
int distanceFromToday(Event event, DateTime today) {
  final toStart = daysBetween(today, event.startDate); // > 0: starts later
  final fromEnd = daysBetween(event.endDate, today); // > 0: ended earlier
  if (toStart > 0) return toStart;
  if (fromEnd > 0) return fromEnd;
  return 0;
}

/// The event "closest" to [today]: one whose range contains today wins;
/// otherwise the nearest range by distance in days (either side). Ties prefer
/// the upcoming event over a past one, then the more recent start date, then
/// the higher id. Returns null for an empty list.
Event? pickClosestEvent(List<Event> events, DateTime today) {
  Event? best;
  for (final e in events) {
    if (best == null || _isBetter(e, best, today)) best = e;
  }
  return best;
}

bool _isBetter(Event a, Event b, DateTime today) {
  final da = distanceFromToday(a, today);
  final db = distanceFromToday(b, today);
  if (da != db) return da < db;
  final upA = daysBetween(today, a.startDate) > 0;
  final upB = daysBetween(today, b.startDate) > 0;
  if (upA != upB) return upA; // upcoming beats past on a tie
  final byStart = daysBetween(b.startDate, a.startDate);
  if (byStart != 0) return byStart > 0; // more recent start
  return a.id > b.id;
}
