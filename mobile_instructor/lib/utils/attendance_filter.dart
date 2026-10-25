import 'package:intl/intl.dart';

import '../models/attendance_type.dart';
import '../models/event_attendance.dart';
import 'manila_time.dart';

/// Row filter chips on the event attendance screen.
enum AttendanceFilter { all, missing, complete }

/// Has this student missed at least one (closed) slot?
bool isMissing(StudentAttendance s) => s.missed > 0;

/// Attended every required slot, and every slot's window has closed.
bool isComplete(EventAttendance data, StudentAttendance s) =>
    data.slots.isNotEmpty &&
    s.attended == data.slots.length &&
    data.slots.every((slot) => slot.elapsed);

bool matchesFilter(
  EventAttendance data,
  StudentAttendance s,
  AttendanceFilter f,
) => switch (f) {
  AttendanceFilter.all => true,
  AttendanceFilter.missing => isMissing(s),
  AttendanceFilter.complete => isComplete(data, s),
};

/// Case-insensitive match on the student's name or student number.
bool matchesQuery(StudentAttendance s, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  return s.fullName.toLowerCase().contains(q) ||
      s.studentNumber.toLowerCase().contains(q);
}

/// The roster narrowed by [filter] and [query] (server order is kept).
List<StudentAttendance> filterStudents(
  EventAttendance data, {
  AttendanceFilter filter = AttendanceFilter.all,
  String query = '',
}) {
  return [
    for (final s in data.students)
      if (matchesFilter(data, s, filter) && matchesQuery(s, query)) s,
  ];
}

/// How many students each filter chip would show (ignoring the search text).
Map<AttendanceFilter, int> filterCounts(EventAttendance data) => {
  for (final f in AttendanceFilter.values)
    f: data.students.where((s) => matchesFilter(data, s, f)).length,
};

/// The slot the headline talks about: the latest slot whose window has
/// closed, else the first slot. Null when the event has no slots.
SlotSummary? focusSlot(EventAttendance data) {
  if (data.slots.isEmpty) return null;
  for (var i = data.slots.length - 1; i >= 0; i--) {
    if (data.slots[i].elapsed) return data.slots[i];
  }
  return data.slots.first;
}

/// Total students a slot's counts are measured against.
int slotTotal(EventAttendance data, SlotSummary slot) {
  if (data.students.isNotEmpty) return data.students.length;
  return slot.present + slot.absent + slot.pending;
}

/// "18 of 24 present · AM Time-In" (or "... present so far ..." while the
/// slot's window is still open). Null when there is nothing to summarise.
String? attendanceHeadline(EventAttendance data) {
  final slot = focusSlot(data);
  if (slot == null) return null;
  final total = slotTotal(data, slot);
  final so = slot.elapsed ? '' : ' so far';
  return '${slot.present} of $total present$so · ${slot.label}';
}

/// Where a slot's scan window is right now.
enum SlotPhase { closed, open, notYet }

/// [closed] once the window has passed; otherwise [open] when it has begun
/// today and [notYet] when it hasn't (or the day itself is still ahead).
SlotPhase slotPhase(
  SlotSummary slot, {
  required bool isToday,
  required DateTime nowManila,
}) {
  if (slot.elapsed) return SlotPhase.closed;
  if (!isToday) return SlotPhase.notYet;
  final start = clockMinutes(slot.windowStart);
  if (start == null) return SlotPhase.notYet;
  final now = nowManila.hour * 60 + nowManila.minute;
  return now >= start ? SlotPhase.open : SlotPhase.notYet;
}

/// Minutes after midnight for "HH:MM[:SS]", or null when unparsable.
int? clockMinutes(String? hhmmss) {
  if (hhmmss == null) return null;
  final parts = hhmmss.split(':');
  if (parts.length < 2) return null;
  final h = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  if (h == null || m == null) return null;
  return h * 60 + m;
}

/// "07:00:00" -> "7:00 AM" (unparsable input is returned as given).
String formatClock(String? hhmmss) {
  final minutes = clockMinutes(hhmmss);
  if (minutes == null) return hhmmss ?? '';
  return DateFormat(
    'h:mm a',
  ).format(DateTime(2000, 1, 1, minutes ~/ 60, minutes % 60));
}

/// "AM-In" style label for a student's slot pill.
String shortSlotLabel(String code) {
  switch (code) {
    case 'AM_IN':
      return 'AM-In';
    case 'AM_OUT':
      return 'AM-Out';
    case 'PM_IN':
      return 'PM-In';
    case 'PM_OUT':
      return 'PM-Out';
    default:
      return AttendanceType.labelFor(code);
  }
}

/// Scan time as Manila wall-clock "h:mm a".
String formatScanTime(DateTime scannedAt) =>
    DateFormat('h:mm a').format(toManila(scannedAt));
