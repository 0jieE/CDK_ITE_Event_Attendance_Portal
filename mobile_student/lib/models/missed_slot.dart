/// A required slot the student missed: its window closed with no scan
/// (from `GET /api/student/missed-slots/`). Each one is fined at [rate].
class MissedSlot {
  final int event;
  final String eventName;
  final DateTime date;
  final String attendanceType;
  final String attendanceTypeDisplay;

  /// "HH:MM:SS" scan window, or null when the admin didn't set it.
  final String? windowStart;
  final String? windowEnd;
  final String rate;
  final bool paid;

  const MissedSlot({
    required this.event,
    required this.eventName,
    required this.date,
    required this.attendanceType,
    required this.attendanceTypeDisplay,
    required this.windowStart,
    required this.windowEnd,
    required this.rate,
    required this.paid,
  });

  factory MissedSlot.fromJson(Map<String, dynamic> json) {
    return MissedSlot(
      event: json['event'] as int,
      eventName: json['event_name'] as String? ?? '',
      date: DateTime.parse(json['date'] as String),
      attendanceType: json['attendance_type'] as String? ?? '',
      attendanceTypeDisplay: json['attendance_type_display'] as String? ?? '',
      windowStart: json['window_start'] as String?,
      windowEnd: json['window_end'] as String?,
      rate: '${json['rate'] ?? '0.00'}',
      paid: json['paid'] as bool? ?? false,
    );
  }
}
