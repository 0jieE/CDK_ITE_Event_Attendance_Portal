// Fixtures for the instructor event-attendance endpoint
// (GET /instructor/events/{id}/attendance/).

Map<String, dynamic> slotSummaryJson(
  String type,
  String label, {
  bool elapsed = true,
  int present = 0,
  int absent = 0,
  int pending = 0,
  String start = '07:00:00',
  String end = '08:00:00',
}) => {
  'type': type,
  'label': label,
  'window_start': start,
  'window_end': end,
  'elapsed': elapsed,
  'present': present,
  'absent': absent,
  'pending': pending,
};

Map<String, dynamic> cellJson(String type, String status, [String? at]) => {
  'type': type,
  'status': status,
  'scanned_at': at,
};

Map<String, dynamic> studentJson(
  int id,
  String number,
  String name,
  List<Map<String, dynamic>> cells, {
  String? photo,
  String yearSection = '2nd Year A',
}) => {
  'id': id,
  'student_number': number,
  'full_name': name,
  'year_section': yearSection,
  'photo': photo,
  'attended': cells
      .where((c) => c['status'] == 'PRESENT' || c['status'] == 'LATE')
      .length,
  'missed': cells.where((c) => c['status'] == 'ABSENT').length,
  'slots': cells,
};

/// A 3-student, 2-slot class on [date]. With [allElapsed] both windows are
/// closed (so the second slot holds real results instead of PENDING).
///
///  * DEMO-001 Maria Santos: AM-In present 07:12, AM-Out pending / present
///  * DEMO-002 Juan Dela Cruz (has a photo): AM-In absent, AM-Out pending / absent
///  * DEMO-003 Ana Reyes: AM-In late 07:50, AM-Out pending / absent
Map<String, dynamic> sampleAttendanceJson({
  String date = '2026-10-08',
  List<String> dates = const ['2026-10-06', '2026-10-08', '2026-10-10'],
  bool isToday = true,
  bool allElapsed = false,
}) {
  final second = allElapsed ? 'ABSENT' : 'PENDING';
  return {
    'event': {
      'id': 3,
      'name': 'ITE Tech Week 2026',
      'start_date': '2026-10-06',
      'end_date': '2026-10-10',
      'is_active': true,
    },
    'date': date,
    'dates': dates,
    'is_today': isToday,
    'slots': [
      slotSummaryJson('AM_IN', 'AM Time-In', present: 2, absent: 1),
      slotSummaryJson(
        'AM_OUT',
        'AM Time-Out',
        elapsed: allElapsed,
        start: '11:30:00',
        end: '12:00:00',
        present: allElapsed ? 1 : 0,
        absent: allElapsed ? 2 : 0,
        pending: allElapsed ? 0 : 3,
      ),
    ],
    'students': [
      studentJson(5, 'DEMO-001', 'Maria Santos', [
        cellJson('AM_IN', 'PRESENT', '2026-10-08T07:12:09+08:00'),
        allElapsed
            ? cellJson('AM_OUT', 'PRESENT', '2026-10-08T11:45:00+08:00')
            : cellJson('AM_OUT', 'PENDING'),
      ]),
      studentJson(6, 'DEMO-002', 'Juan Dela Cruz', [
        cellJson('AM_IN', 'ABSENT'),
        cellJson('AM_OUT', second),
      ], photo: 'https://example.com/juan.jpg'),
      studentJson(7, 'DEMO-003', 'Ana Reyes', [
        cellJson('AM_IN', 'LATE', '2026-10-08T07:50:00+08:00'),
        cellJson('AM_OUT', second),
      ]),
    ],
  };
}
