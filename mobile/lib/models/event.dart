import 'attendance_type.dart';

/// One slot's scan window (admin-set times for AM/PM in/out).
class SlotWindow {
  final String code; // AM_IN ...
  final String label; // "AM Time-In"
  final String start; // "07:00" (24h, trimmed)
  final String end; // "08:00"
  const SlotWindow(this.code, this.label, this.start, this.end);
}

/// An event the student/instructor interacts with (from the events endpoints).
class Event {
  final int id;
  final String name;
  final String semesterLabel;
  final DateTime startDate;
  final DateTime endDate;
  final String fineRate;
  final List<String> requiredTypes;
  final bool isActive;

  /// Raw "HH:MM:SS" (or null) per slot boundary, keyed by field name.
  final Map<String, String?> _times;

  const Event({
    required this.id,
    required this.name,
    required this.semesterLabel,
    required this.startDate,
    required this.endDate,
    required this.fineRate,
    required this.requiredTypes,
    required this.isActive,
    required Map<String, String?> times,
  }) : _times = times;

  factory Event.fromJson(Map<String, dynamic> json) {
    String? t(String k) => json[k] as String?;
    return Event(
      id: json['id'] as int,
      name: json['name'] as String? ?? '',
      semesterLabel: json['semester_label'] as String? ?? '',
      startDate: DateTime.parse(json['start_date'] as String),
      endDate: DateTime.parse(json['end_date'] as String),
      fineRate: '${json['fine_rate'] ?? '0.00'}',
      requiredTypes:
          (json['required_types'] as List<dynamic>? ?? []).map((e) => '$e').toList(),
      isActive: json['is_active'] as bool? ?? false,
      times: {
        for (final k in const [
          'am_in_start', 'am_in_end', 'am_out_start', 'am_out_end',
          'pm_in_start', 'pm_in_end', 'pm_out_start', 'pm_out_end',
        ])
          k: t(k),
      },
    );
  }

  /// Back to the API's JSON shape (for the offline cache).
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'semester_label': semesterLabel,
        'start_date': _ymd(startDate),
        'end_date': _ymd(endDate),
        'fine_rate': fineRate,
        'required_types': requiredTypes,
        'is_active': isActive,
        ..._times,
      };

  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static const _slotFields = {
    'AM_IN': ['am_in_start', 'am_in_end'],
    'AM_OUT': ['am_out_start', 'am_out_end'],
    'PM_IN': ['pm_in_start', 'pm_in_end'],
    'PM_OUT': ['pm_out_start', 'pm_out_end'],
  };

  static String _hhmm(String raw) =>
      raw.length >= 5 ? raw.substring(0, 5) : raw;

  /// Configured scan windows for the event's required slots (for display).
  List<SlotWindow> get schedule {
    final out = <SlotWindow>[];
    for (final code in const ['AM_IN', 'AM_OUT', 'PM_IN', 'PM_OUT']) {
      if (!requiredTypes.contains(code)) continue;
      final fields = _slotFields[code]!;
      final s = _times[fields[0]];
      final e = _times[fields[1]];
      if (s != null && e != null) {
        out.add(SlotWindow(code, AttendanceType.labelFor(code), _hhmm(s), _hhmm(e)));
      }
    }
    return out;
  }

  /// The required slot whose scan window contains the wall-clock time of
  /// [manila] (Manila time components), or null - the same rule the server
  /// uses, so offline scans pick the slot the server will.
  String? slotAt(DateTime manila) {
    final t = manila.hour * 3600 + manila.minute * 60 + manila.second;
    for (final code in const ['AM_IN', 'AM_OUT', 'PM_IN', 'PM_OUT']) {
      if (!requiredTypes.contains(code)) continue;
      final fields = _slotFields[code]!;
      final s = _seconds(_times[fields[0]]);
      final e = _seconds(_times[fields[1]]);
      if (s != null && e != null && s <= t && t <= e) return code;
    }
    return null;
  }

  /// "HH:MM[:SS]" -> seconds since midnight.
  static int? _seconds(String? raw) {
    if (raw == null) return null;
    final p = raw.split(':').map(int.tryParse).toList();
    if (p.length < 2 || p.any((x) => x == null)) return null;
    return p[0]! * 3600 + p[1]! * 60 + (p.length > 2 ? p[2]! : 0);
  }

  /// Every date in [startDate, endDate] inclusive — for the date picker.
  List<DateTime> get dateRange {
    final days = <DateTime>[];
    var d = DateTime(startDate.year, startDate.month, startDate.day);
    final end = DateTime(endDate.year, endDate.month, endDate.day);
    while (!d.isAfter(end)) {
      days.add(d);
      // Calendar arithmetic (not +24h) so a DST change can't skip/repeat a day.
      d = DateTime(d.year, d.month, d.day + 1);
    }
    return days;
  }
}
