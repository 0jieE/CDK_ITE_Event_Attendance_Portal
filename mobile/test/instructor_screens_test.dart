import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ite_attendance/screens/instructor/attendance_tab.dart';
import 'package:ite_attendance/screens/instructor/event_attendance_screen.dart';
import 'package:ite_attendance/screens/instructor/instructor_home.dart';
import 'package:ite_attendance/services/api_service.dart';
import 'package:ite_attendance/services/auth_provider.dart';
import 'package:ite_attendance/theme/app_theme.dart';
import 'package:ite_attendance/utils/manila_time.dart';
import 'package:provider/provider.dart';

import 'instructor_fixtures.dart';
import 'test_helpers.dart';

http.Response json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

void bigScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// 08:30 Manila on 2026-10-08.
DateTime morning() => DateTime.utc(2026, 10, 8, 0, 30);

/// 11:45 Manila on 2026-10-08 (the AM-Out window 11:30-12:00 is open).
DateTime nearNoon() => DateTime.utc(2026, 10, 8, 3, 45);

Widget app(ApiService api, Widget home, {AuthProvider? auth}) {
  Widget child = MaterialApp(theme: AppTheme.light, home: home);
  child = Provider<ApiService>.value(value: api, child: child);
  if (auth != null) {
    child = ChangeNotifierProvider<AuthProvider>.value(
      value: auth,
      child: child,
    );
  }
  return child;
}

void main() {
  group('EventAttendanceScreen', () {
    final event = ev(3, '2026-10-06', '2026-10-10');

    /// Fake backend. [handler] may override the attendance response.
    ({ApiService api, List<Map<String, String>> queries}) backend({
      http.Response Function(Map<String, String> q)? handler,
    }) {
      final queries = <Map<String, String>>[];
      final client = MockClient((req) async {
        if (!req.url.path.endsWith('/instructor/events/3/attendance/')) {
          return json({'detail': 'not found'}, 404);
        }
        queries.add(req.url.queryParameters);
        if (handler != null) return handler(req.url.queryParameters);
        final d = req.url.queryParameters['date'];
        if (d == null || d == '2026-10-08') return json(sampleAttendanceJson());
        return json(
          sampleAttendanceJson(
            date: d,
            isToday: false,
            allElapsed: d == '2026-10-06',
          ),
        );
      });
      return (
        api: ApiService(tokens: FakeTokens(), client: client),
        queries: queries,
      );
    }

    testWidgets(
      'renders header, date selector, slot summary and student rows',
      (tester) async {
        bigScreen(tester);
        final b = backend();
        await tester.pumpWidget(
          app(b.api, EventAttendanceScreen(event: event, clock: morning)),
        );
        await tester.pumpAndSettle();

        // First request lets the server choose the day.
        expect(b.queries.single, isEmpty);

        // App bar: name + date range.
        expect(find.text('Event 3'), findsOneWidget);
        expect(find.text('Oct 6 – Oct 10, 2026'), findsOneWidget);

        // Date selector: every event day, today flagged.
        expect(find.text('Today'), findsOneWidget);
        expect(find.text('6'), findsOneWidget);
        expect(find.text('8'), findsOneWidget);
        expect(find.text('10'), findsOneWidget);

        // Summary: both slots, with counts; the unfinished slot is "Not yet".
        expect(find.text('AM Time-In'), findsOneWidget);
        expect(find.text('AM Time-Out'), findsOneWidget);
        expect(find.text('7:00 AM – 8:00 AM'), findsOneWidget);
        expect(find.text('2 present'), findsOneWidget);
        expect(find.text('1 absent · 0 pending'), findsOneWidget);
        expect(find.text('0 absent · 3 pending'), findsOneWidget);
        expect(find.text('Not yet'), findsOneWidget);
        expect(find.text('Open'), findsNothing);
        expect(find.byType(LinearProgressIndicator), findsNWidgets(2));

        // Headline.
        expect(find.text('2 of 3 present · AM Time-In'), findsOneWidget);

        // Rows.
        expect(find.text('Maria Santos'), findsOneWidget);
        expect(find.text('Juan Dela Cruz'), findsOneWidget);
        expect(find.text('Ana Reyes'), findsOneWidget);
        expect(find.text('DEMO-001 · 2nd Year A'), findsOneWidget);
        expect(find.text('AM-In · 7:12 AM'), findsOneWidget);
        expect(find.text('AM-In · Absent'), findsOneWidget);
        expect(find.text('AM-In · 7:50 AM · Late'), findsOneWidget);
        expect(find.text('AM-Out · Pending'), findsNWidgets(3));
        expect(find.text('All 3'), findsOneWidget);
        expect(find.text('Missing 1'), findsOneWidget);
        expect(find.text('Complete 0'), findsOneWidget);
        // Today is the selected day, so no "not started" note.
        expect(find.textContaining("hasn't started"), findsNothing);
      },
    );

    testWidgets('an open window is labelled "Open" and not dimmed away', (
      tester,
    ) async {
      bigScreen(tester);
      final b = backend();
      await tester.pumpWidget(
        app(b.api, EventAttendanceScreen(event: event, clock: nearNoon)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Open'), findsOneWidget);
      expect(find.text('Not yet'), findsNothing);
    });

    testWidgets('changing the day re-fetches with ?date= and shows the note '
        'for a day that has not started', (tester) async {
      bigScreen(tester);
      final b = backend();
      await tester.pumpWidget(
        app(b.api, EventAttendanceScreen(event: event, clock: morning)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('10'));
      await tester.pumpAndSettle();
      expect(b.queries.last, {'date': '2026-10-10'});
      expect(
        find.textContaining("This day hasn't started yet"),
        findsOneWidget,
      );
      // The selector is still there and the roster re-rendered.
      expect(find.text('Maria Santos'), findsOneWidget);

      // A finished day shows real results and no note.
      await tester.tap(find.text('6'));
      await tester.pumpAndSettle();
      expect(b.queries.last, {'date': '2026-10-06'});
      expect(find.textContaining("hasn't started"), findsNothing);
      expect(find.text('1 of 3 present · AM Time-Out'), findsOneWidget);
      expect(find.text('AM-Out · 11:45 AM'), findsOneWidget);
      expect(find.text('AM-Out · Absent'), findsNWidgets(2));

      // Re-tapping the selected day does not fetch again.
      final n = b.queries.length;
      await tester.tap(find.text('6'));
      await tester.pumpAndSettle();
      expect(b.queries.length, n);
    });

    testWidgets('filter chips and search narrow the list', (tester) async {
      bigScreen(tester);
      final b = backend();
      await tester.pumpWidget(
        app(b.api, EventAttendanceScreen(event: event, clock: morning)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Missing 1'));
      await tester.pumpAndSettle();
      expect(find.text('Juan Dela Cruz'), findsOneWidget);
      expect(find.text('Maria Santos'), findsNothing);
      expect(find.text('Showing 1 of 3'), findsOneWidget);

      await tester.tap(find.text('All 3'));
      await tester.pumpAndSettle();
      expect(find.text('Maria Santos'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'demo-003');
      await tester.pumpAndSettle();
      expect(find.text('Ana Reyes'), findsOneWidget);
      expect(find.text('Maria Santos'), findsNothing);

      // Search + Complete: nothing matches -> friendly empty state.
      await tester.tap(find.text('Complete 0'));
      await tester.pumpAndSettle();
      expect(find.text('No students match'), findsOneWidget);
      expect(find.text('Ana Reyes'), findsNothing);

      // Clearing the search and going back to All restores everyone.
      await tester.tap(find.byTooltip('Clear search'));
      await tester.tap(find.text('All 3'));
      await tester.pumpAndSettle();
      expect(find.text('Maria Santos'), findsOneWidget);
      expect(find.text('Ana Reyes'), findsOneWidget);
    });

    testWidgets('Complete lists students who scanned every closed slot', (
      tester,
    ) async {
      bigScreen(tester);
      final b = backend(
        handler: (_) => json(sampleAttendanceJson(allElapsed: true)),
      );
      await tester.pumpWidget(
        app(b.api, EventAttendanceScreen(event: event, clock: morning)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Complete 1'), findsOneWidget);
      await tester.tap(find.text('Complete 1'));
      await tester.pumpAndSettle();
      expect(find.text('Maria Santos'), findsOneWidget);
      expect(find.text('Juan Dela Cruz'), findsNothing);
    });

    testWidgets(
      'error state with retry; a failed day change keeps the selector',
      (tester) async {
        bigScreen(tester);
        var fail = true;
        final b = backend(
          handler: (q) {
            if (fail) return json({'detail': 'Server exploded.'}, 500);
            if (q['date'] == '2026-10-10') {
              return json({
                'date': ['Date is outside the event.'],
              }, 400);
            }
            return json(sampleAttendanceJson());
          },
        );
        await tester.pumpWidget(
          app(b.api, EventAttendanceScreen(event: event, clock: morning)),
        );
        await tester.pumpAndSettle();

        expect(find.text('Could not load attendance'), findsOneWidget);
        expect(find.text('Server exploded.'), findsOneWidget);
        expect(find.text('Maria Santos'), findsNothing);
        // The days are still offered (from the event) even before any data.
        expect(find.text('10'), findsOneWidget);

        fail = false;
        await tester.tap(find.text('Retry'));
        await tester.pumpAndSettle();
        expect(find.text('Maria Santos'), findsOneWidget);

        // A 400 for a day shows the server's message with Retry.
        await tester.tap(find.text('10'));
        await tester.pumpAndSettle();
        expect(find.text('Date is outside the event.'), findsOneWidget);
        expect(find.text('Retry'), findsOneWidget);
        expect(find.text('10'), findsOneWidget);
      },
    );

    testWidgets('single-day event still shows the selector; empty roster '
        'shows an empty state', (tester) async {
      bigScreen(tester);
      final one = ev(3, '2026-10-08', '2026-10-08');
      final b = backend(
        handler: (_) {
          final j = sampleAttendanceJson(dates: const ['2026-10-08']);
          j['students'] = [];
          for (final s in j['slots'] as List) {
            (s as Map<String, dynamic>)
              ..['present'] = 0
              ..['absent'] = 0;
          }
          return json(j);
        },
      );
      await tester.pumpWidget(
        app(b.api, EventAttendanceScreen(event: one, clock: morning)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Today'), findsOneWidget);
      expect(find.text('Oct 8, 2026'), findsOneWidget);
      expect(find.text('No students to show'), findsOneWidget);
    });

    testWidgets('a future event: everything Pending with a friendly note', (
      tester,
    ) async {
      bigScreen(tester);
      final future = ev(3, '2026-10-20', '2026-10-21');
      final b = backend(
        handler: (_) {
          final j = sampleAttendanceJson(
            date: '2026-10-20',
            dates: const ['2026-10-20', '2026-10-21'],
            isToday: false,
          );
          for (final s in j['slots'] as List) {
            (s as Map<String, dynamic>)
              ..['elapsed'] = false
              ..['present'] = 0
              ..['absent'] = 0
              ..['pending'] = 3;
          }
          for (final st in j['students'] as List) {
            st['attended'] = 0;
            st['missed'] = 0;
            st['slots'] = [
              cellJson('AM_IN', 'PENDING'),
              cellJson('AM_OUT', 'PENDING'),
            ];
          }
          return json(j);
        },
      );
      await tester.pumpWidget(
        app(b.api, EventAttendanceScreen(event: future, clock: morning)),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining("This day hasn't started yet"),
        findsOneWidget,
      );
      expect(find.text('AM-In · Pending'), findsNWidgets(3));
      expect(find.text('AM-Out · Pending'), findsNWidgets(3));
      expect(find.text('Not yet'), findsNWidgets(2));
      expect(find.text('0 of 3 present so far · AM Time-In'), findsOneWidget);
      expect(find.text('Missing 0'), findsOneWidget);
    });

    testWidgets('pull-to-refresh re-requests the selected day', (tester) async {
      tester.view.physicalSize = const Size(800, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final b = backend();
      await tester.pumpWidget(
        app(b.api, EventAttendanceScreen(event: event, clock: morning)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('6'));
      await tester.pumpAndSettle();
      final n = b.queries.length;
      await tester.drag(find.text('Maria Santos'), const Offset(0, 700));
      await tester.pumpAndSettle();
      expect(b.queries.length, n + 1);
      expect(b.queries.last, {'date': '2026-10-06'});
    });

    testWidgets('lays out on a narrow phone with large text (no overflow)', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final b = backend();
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(360, 740),
            textScaler: TextScaler.linear(1.3),
          ),
          child: app(
            b.api,
            EventAttendanceScreen(event: event, clock: morning),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Maria Santos'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders ~100 students', (tester) async {
      bigScreen(tester);
      final b = backend(
        handler: (_) {
          final j = sampleAttendanceJson();
          j['students'] = [
            for (var i = 0; i < 100; i++)
              studentJson(
                i,
                'S-${i.toString().padLeft(3, '0')}',
                'Student $i',
                [
                  cellJson('AM_IN', 'PRESENT', '2026-10-08T07:12:09+08:00'),
                  cellJson('AM_OUT', 'PENDING'),
                ],
              ),
          ];
          return json(j);
        },
      );
      await tester.pumpWidget(
        app(b.api, EventAttendanceScreen(event: event, clock: morning)),
      );
      await tester.pumpAndSettle();
      expect(find.text('All 100'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Student 99'),
        500,
        scrollable: find
            .descendant(
              of: find.byType(RefreshIndicator),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.text('Student 99'), findsOneWidget);
    });
  });

  group('AttendanceTab', () {
    final today = manilaToday();
    String day(int o) => ymd(DateTime(today.year, today.month, today.day + o));

    Map<String, dynamic> named(int id, String name, int s, int e) =>
        eventJson(id, name, day(s), day(e));

    ApiService backend({
      required http.Response Function(http.Request) onEvents,
      List<String>? calls,
    }) {
      final client = MockClient((req) async {
        calls?.add('${req.url.path}?${req.url.query}');
        if (req.url.path.endsWith('/instructor/events/')) return onEvents(req);
        if (req.url.path.endsWith('/attendance/')) {
          return json(sampleAttendanceJson());
        }
        return json({'detail': 'nf'}, 404);
      });
      return ApiService(tokens: FakeTokens(), client: client);
    }

    testWidgets('orders ongoing, upcoming, finished; chips; search; tap opens '
        'the roster', (tester) async {
      bigScreen(tester);
      final calls = <String>[];
      final api = backend(
        calls: calls,
        onEvents: (req) {
          expect(req.url.queryParameters['all'], 'true');
          return json({
            'count': 3,
            'next': null,
            'results': [
              named(1, 'Old Fair', -30, -29),
              named(2, 'Next Month Summit', 20, 21),
              named(3, 'Tech Week', -1, 1),
            ],
          });
        },
      );
      await tester.pumpWidget(app(api, const Scaffold(body: AttendanceTab())));
      await tester.pumpAndSettle();

      final ongoing = tester.getTopLeft(find.text('Tech Week')).dy;
      final upcoming = tester.getTopLeft(find.text('Next Month Summit')).dy;
      final finished = tester.getTopLeft(find.text('Old Fair')).dy;
      expect(ongoing < upcoming, isTrue);
      expect(upcoming < finished, isTrue);
      expect(find.text('Ongoing'), findsOneWidget);
      expect(find.text('Upcoming'), findsOneWidget);
      expect(find.text('Finished'), findsOneWidget);

      // Search by name.
      await tester.enterText(find.byType(TextField), 'summit');
      await tester.pumpAndSettle();
      expect(find.text('Next Month Summit'), findsOneWidget);
      expect(find.text('Tech Week'), findsNothing);

      await tester.enterText(find.byType(TextField), 'zzz');
      await tester.pumpAndSettle();
      expect(find.textContaining('No events match'), findsOneWidget);

      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();

      // Tap -> EventAttendanceScreen for that event.
      await tester.tap(find.text('Tech Week'));
      await tester.pumpAndSettle();
      expect(find.byType(EventAttendanceScreen), findsOneWidget);
      expect(
        calls.any((c) => c.startsWith('/api/instructor/events/3/attendance/')),
        isTrue,
      );
      expect(find.text('Maria Santos'), findsOneWidget);
    });

    testWidgets('empty state', (tester) async {
      bigScreen(tester);
      final api = backend(
        onEvents: (_) => json({'count': 0, 'next': null, 'results': []}),
      );
      await tester.pumpWidget(app(api, const Scaffold(body: AttendanceTab())));
      await tester.pumpAndSettle();
      expect(find.text('No events yet'), findsOneWidget);
    });

    testWidgets('error state with retry', (tester) async {
      bigScreen(tester);
      var fail = true;
      final api = backend(
        onEvents: (_) {
          if (fail) return json({'detail': 'Nope.'}, 403);
          return json({
            'results': [named(3, 'Tech Week', -1, 1)],
          });
        },
      );
      await tester.pumpWidget(app(api, const Scaffold(body: AttendanceTab())));
      await tester.pumpAndSettle();
      expect(find.text('Could not load events'), findsOneWidget);
      expect(find.text('Nope.'), findsOneWidget);
      fail = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Tech Week'), findsOneWidget);
    });
  });

  group('InstructorHome shell', () {
    testWidgets('opens on the Scan tab (events + Scan QR) and lazily loads '
        'the Attendance tab', (tester) async {
      bigScreen(tester);
      final today = manilaToday();
      String day(int o) =>
          ymd(DateTime(today.year, today.month, today.day + o));
      final calls = <String>[];
      final client = MockClient((req) async {
        calls.add('${req.url.path}?${req.url.query}');
        final path = req.url.path;
        if (path.endsWith('/me/')) {
          return json({
            'id': 9,
            'username': 'prof',
            'full_name': 'Prof Ada',
            'is_admin': false,
            'is_instructor': true,
            'is_student': false,
            'role': 'instructor',
            'profile_image': null,
          });
        }
        if (path.endsWith('/instructor/events/')) {
          if (req.url.queryParameters['all'] == 'true') {
            return json({
              'results': [
                eventJson(1, 'Old Fair', day(-30), day(-29)),
                eventJson(2, 'Running Expo', day(-1), day(1)),
              ],
            });
          }
          return json({
            'results': [eventJson(2, 'Running Expo', day(-1), day(1))],
          });
        }
        return json({'detail': 'nf'}, 404);
      });
      final api = ApiService(tokens: FakeTokens(), client: client);
      final auth = AuthProvider(apiService: api);
      await auth.bootstrap();

      await tester.pumpWidget(app(api, const InstructorHome(), auth: auth));
      await tester.pumpAndSettle();

      // Scan tab content, unchanged.
      expect(find.text('Hello, Prof Ada'), findsOneWidget);
      expect(find.text('Active events you can scan for'), findsOneWidget);
      expect(find.text('Running Expo'), findsOneWidget);
      expect(find.text('Active'), findsOneWidget);
      expect(find.text('Scan QR'), findsOneWidget);
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byTooltip('Log out'), findsOneWidget);
      // The attendance list has not been requested yet.
      expect(calls.where((c) => c.contains('all=true')), isEmpty);

      // Switch to Attendance: list of ALL events, scan button gone.
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('Attendance'),
        ),
      );
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.contains('all=true')).length, 1);
      expect(find.text('Old Fair'), findsOneWidget);
      expect(find.text('Ongoing'), findsOneWidget);
      expect(find.text('Finished'), findsOneWidget);
      expect(find.text('Scan QR'), findsNothing);
      expect(find.byTooltip('Log out'), findsOneWidget);

      // And back: the Scan tab is intact.
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('Scan'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Scan QR'), findsOneWidget);
      expect(find.text('Hello, Prof Ada'), findsOneWidget);
      // Tabs are kept alive: no extra fetch when switching back and forth.
      expect(calls.where((c) => c.contains('all=true')).length, 1);
    });
  });
}
