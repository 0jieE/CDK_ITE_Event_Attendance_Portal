/// A student's attendance record for one slot (from `GET /api/student/attendance/`).
class AttendanceLog {
  final int id;
  final int event;
  final String eventName;
  final DateTime date;
  final String attendanceType;
  final String attendanceTypeDisplay;
  final String status; // PRESENT | LATE | ABSENT
  final DateTime? scannedAt;

  const AttendanceLog({
    required this.id,
    required this.event,
    required this.eventName,
    required this.date,
    required this.attendanceType,
    required this.attendanceTypeDisplay,
    required this.status,
    required this.scannedAt,
  });

  factory AttendanceLog.fromJson(Map<String, dynamic> json) {
    return AttendanceLog(
      id: json['id'] as int,
      event: json['event'] as int,
      eventName: json['event_name'] as String? ?? '',
      date: DateTime.parse(json['date'] as String),
      attendanceType: json['attendance_type'] as String? ?? '',
      attendanceTypeDisplay: json['attendance_type_display'] as String? ?? '',
      status: json['status'] as String? ?? 'ABSENT',
      scannedAt: json['scanned_at'] != null
          ? DateTime.tryParse(json['scanned_at'] as String)
          : null,
    );
  }

  bool get isPresent => status == 'PRESENT';
  bool get isLate => status == 'LATE';
  bool get isAbsent => status == 'ABSENT';
}
