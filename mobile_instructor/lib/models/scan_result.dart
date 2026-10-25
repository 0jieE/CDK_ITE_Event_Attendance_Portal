/// Result of an instructor scan (`POST /api/instructor/scan/`).
class ScanResult {
  final bool ok; // HTTP 2xx
  final bool created; // newly recorded vs already-recorded
  final String detail;
  final String? code; // INVALID_TOKEN / STALE_QR / EVENT_INACTIVE / ...
  final String? studentName;
  final String? studentNumber;
  final String? studentPhoto; // so the instructor can compare faces
  final String? eventName;
  final String? attendanceTypeDisplay;
  final String? status;
  final DateTime? scannedAt;

  /// Saved on the phone (no connection); it is sent to the server later.
  final bool offline;

  /// Offline and the code wasn't in the downloaded list, so the student is
  /// unknown until it syncs (the QR may still turn out to be invalid).
  final bool unverified;

  const ScanResult({
    required this.ok,
    required this.created,
    required this.detail,
    this.code,
    this.studentName,
    this.studentNumber,
    this.studentPhoto,
    this.eventName,
    this.attendanceTypeDisplay,
    this.status,
    this.scannedAt,
    this.offline = false,
    this.unverified = false,
  });

  factory ScanResult.success(Map<String, dynamic> json, {required bool created}) {
    return ScanResult(
      ok: true,
      created: created,
      detail: json['detail'] as String? ?? '',
      studentName: json['student_name'] as String?,
      studentNumber: json['student_number'] as String?,
      studentPhoto: json['student_photo'] as String?,
      eventName: json['event_name'] as String?,
      attendanceTypeDisplay: json['attendance_type_display'] as String?,
      status: json['status'] as String?,
      scannedAt: json['scanned_at'] != null
          ? DateTime.tryParse(json['scanned_at'] as String)
          : null,
    );
  }

  factory ScanResult.failure(String detail, String? code,
      {bool offline = false}) {
    return ScanResult(
        ok: false, created: false, detail: detail, code: code, offline: offline);
  }
}
