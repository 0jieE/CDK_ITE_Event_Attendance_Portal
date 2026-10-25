/// The backend runs on Asia/Manila (UTC+8, no DST) and is the authority on
/// "today". These helpers keep the app's idea of the date/time in the same
/// zone, even when the phone is set to a different one.
const Duration manilaOffset = Duration(hours: 8);

/// A [DateTime] whose *components* are the Manila wall-clock time of [instant].
/// (Only read year/month/day/hour/... from it — it is flagged UTC.)
DateTime toManila(DateTime instant) => instant.toUtc().add(manilaOffset);

/// Today's calendar date in Manila, at midnight (components only).
DateTime manilaToday([DateTime? now]) {
  final m = toManila(now ?? DateTime.now());
  return DateTime(m.year, m.month, m.day);
}

/// Strips the time of day, keeping the calendar date.
DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// Whole calendar days from [a] to [b] (positive when [b] is later). Immune to
/// time-of-day and DST because it counts via UTC midnights.
int daysBetween(DateTime a, DateTime b) {
  final ua = DateTime.utc(a.year, a.month, a.day);
  final ub = DateTime.utc(b.year, b.month, b.day);
  return ub.difference(ua).inDays;
}

/// `YYYY-MM-DD` for API query/body fields.
String apiDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';
