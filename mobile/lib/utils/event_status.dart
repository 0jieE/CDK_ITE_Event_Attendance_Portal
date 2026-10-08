import 'package:intl/intl.dart';

import '../models/event.dart';
import 'manila_time.dart';

/// Where an event sits relative to "today" (calendar days, Manila).
enum EventStatus {
  ongoing,
  upcoming,
  finished;

  String get label {
    switch (this) {
      case EventStatus.ongoing:
        return 'Ongoing';
      case EventStatus.upcoming:
        return 'Upcoming';
      case EventStatus.finished:
        return 'Finished';
    }
  }
}

EventStatus eventStatus(Event event, DateTime today) {
  if (daysBetween(today, event.startDate) > 0) return EventStatus.upcoming;
  if (daysBetween(event.endDate, today) > 0) return EventStatus.finished;
  return EventStatus.ongoing;
}

/// Orders events for the instructor's attendance list: ongoing first (ending
/// soonest first), then upcoming (soonest start first), then finished (most
/// recently ended first). Ties fall back to the higher id so the order is
/// stable. Returns a new list.
List<Event> sortEventsForAttendance(List<Event> events, DateTime today) {
  int rank(EventStatus s) => s.index; // ongoing, upcoming, finished
  final sorted = [...events];
  sorted.sort((a, b) {
    final sa = eventStatus(a, today), sb = eventStatus(b, today);
    if (sa != sb) return rank(sa).compareTo(rank(sb));
    int byDate;
    switch (sa) {
      case EventStatus.ongoing:
        byDate = a.endDate.compareTo(b.endDate);
        if (byDate == 0) byDate = b.startDate.compareTo(a.startDate);
      case EventStatus.upcoming:
        byDate = a.startDate.compareTo(b.startDate);
        if (byDate == 0) byDate = a.endDate.compareTo(b.endDate);
      case EventStatus.finished:
        byDate = b.endDate.compareTo(a.endDate);
        if (byDate == 0) byDate = b.startDate.compareTo(a.startDate);
    }
    return byDate != 0 ? byDate : b.id.compareTo(a.id);
  });
  return sorted;
}

/// Case-insensitive "name contains" filter; a blank [query] keeps everything.
List<Event> filterEventsByName(List<Event> events, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return events;
  return events.where((e) => e.name.toLowerCase().contains(q)).toList();
}

/// "Oct 6 – Oct 10, 2026", or "Oct 6, 2026" for a single-day event.
String eventRangeLabel(Event e) {
  final df = DateFormat('MMM d');
  final dfy = DateFormat('MMM d, y');
  return daysBetween(e.startDate, e.endDate) == 0
      ? dfy.format(e.startDate)
      : '${df.format(e.startDate)} – ${dfy.format(e.endDate)}';
}
