import '../utils/manila_time.dart';

/// Status of one student in one slot (the backend's `status` strings).
enum SlotStatus {
  present,
  late,
  absent,

  /// The slot's scan window hasn't closed yet — not a miss.
  pending;

  /// Unknown/missing values read as [pending] (never as a false "absent").
  static SlotStatus parse(String? raw) {
    switch (raw) {
      case 'PRESENT':
        return SlotStatus.present;
      case 'LATE':
        return SlotStatus.late;
      case 'ABSENT':
        return SlotStatus.absent;
      default:
        return SlotStatus.pending;
    }
  }

  /// The backend spelling — also the key [BrandColors.badge] understands.
  String get code => name.toUpperCase();

  /// Counts as attended (PRESENT or LATE).
  bool get isAttended => this == present || this == late;
}

/// The few event fields the attendance endpoint echoes back.
class EventBrief {
  final int id;
  final String name;
  final DateTime startDate;
  final DateTime endDate;
  final bool isActive;

  const EventBrief({
    required this.id,
    required this.name,
    required this.startDate,
    required this.endDate,
    required this.isActive,
  });

  factory EventBrief.fromJson(Map<String, dynamic> json) => EventBrief(
    id: json['id'] as int,
    name: json['name'] as String? ?? '',
    startDate: DateTime.parse(json['start_date'] as String),
    endDate: DateTime.parse(json['end_date'] as String),
    isActive: json['is_active'] as bool? ?? false,
  );
}

/// Class-wide totals for one required slot on the selected day.
class SlotSummary {
  final String type; // AM_IN | AM_OUT | PM_IN | PM_OUT
  final String label; // "AM Time-In"
  final String? windowStart; // "07:00:00"
  final String? windowEnd;

  /// False while the scan window is still open / not opened yet (or the day is
  /// in the future).
  final bool elapsed;
  final int present;
  final int absent;
  final int pending;

  const SlotSummary({
    required this.type,
    required this.label,
    required this.windowStart,
    required this.windowEnd,
    required this.elapsed,
    required this.present,
    required this.absent,
    required this.pending,
  });

  factory SlotSummary.fromJson(Map<String, dynamic> json) => SlotSummary(
    type: json['type'] as String? ?? '',
    label: json['label'] as String? ?? '',
    windowStart: json['window_start'] as String?,
    windowEnd: json['window_end'] as String?,
    elapsed: json['elapsed'] as bool? ?? false,
    present: (json['present'] as num?)?.toInt() ?? 0,
    absent: (json['absent'] as num?)?.toInt() ?? 0,
    pending: (json['pending'] as num?)?.toInt() ?? 0,
  );
}

/// One student's result for one slot.
class SlotCell {
  final String type;
  final SlotStatus status;
  final DateTime? scannedAt;

  const SlotCell({
    required this.type,
    required this.status,
    required this.scannedAt,
  });

  factory SlotCell.fromJson(Map<String, dynamic> json) {
    final at = json['scanned_at'];
    return SlotCell(
      type: json['type'] as String? ?? '',
      status: SlotStatus.parse(json['status'] as String?),
      scannedAt: at is String ? DateTime.tryParse(at) : null,
    );
  }
}

/// One roster row: a student and their cell per required slot.
class StudentAttendance {
  final int id;
  final String studentNumber;
  final String fullName;
  final String yearSection;
  final String? photo;
  final int attended;
  final int missed;
  final List<SlotCell> slots;

  const StudentAttendance({
    required this.id,
    required this.studentNumber,
    required this.fullName,
    required this.yearSection,
    required this.photo,
    required this.attended,
    required this.missed,
    required this.slots,
  });

  factory StudentAttendance.fromJson(Map<String, dynamic> json) {
    final photo = json['photo'] as String?;
    return StudentAttendance(
      id: json['id'] as int,
      studentNumber: json['student_number'] as String? ?? '',
      fullName: json['full_name'] as String? ?? '',
      yearSection: json['year_section'] as String? ?? '',
      photo: (photo != null && photo.isNotEmpty) ? photo : null,
      attended: (json['attended'] as num?)?.toInt() ?? 0,
      missed: (json['missed'] as num?)?.toInt() ?? 0,
      slots: (json['slots'] as List<dynamic>? ?? const [])
          .map((e) => SlotCell.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// `GET /api/instructor/events/{id}/attendance/` — the full class roster for
/// one event-day.
class EventAttendance {
  final EventBrief event;

  /// The day returned (calendar date, local midnight).
  final DateTime date;

  /// Every day of the event, for the date selector.
  final List<DateTime> dates;
  final bool isToday;
  final List<SlotSummary> slots;
  final List<StudentAttendance> students;

  const EventAttendance({
    required this.event,
    required this.date,
    required this.dates,
    required this.isToday,
    required this.slots,
    required this.students,
  });

  factory EventAttendance.fromJson(Map<String, dynamic> json) {
    final date = DateTime.parse(json['date'] as String);
    return EventAttendance(
      event: EventBrief.fromJson(json['event'] as Map<String, dynamic>),
      date: date,
      dates: (json['dates'] as List<dynamic>? ?? const [])
          .map((e) => DateTime.parse(e as String))
          .toList(),
      isToday: json['is_today'] as bool? ?? false,
      slots: (json['slots'] as List<dynamic>? ?? const [])
          .map((e) => SlotSummary.fromJson(e as Map<String, dynamic>))
          .toList(),
      students: (json['students'] as List<dynamic>? ?? const [])
          .map((e) => StudentAttendance.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  /// The days to offer in the selector (falls back to just [date]).
  List<DateTime> get selectableDates =>
      dates.isEmpty ? [dateOnly(date)] : dates;
}
