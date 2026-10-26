import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ite_students/screens/student/fines_tab.dart';
import 'package:ite_students/screens/student/history_tab.dart';
import 'package:ite_students/screens/student/profile_tab.dart';
import 'package:ite_students/services/api_service.dart';
import 'package:ite_students/services/auth_provider.dart';
import 'package:ite_students/theme/app_theme.dart';
import 'package:ite_students/utils/manila_time.dart';
import 'package:provider/provider.dart';

import 'test_helpers.dart';

http.Response json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

Map<String, dynamic> logJson(int id, String date, String type, String display,
        String status, String? at) =>
    {
      'id': id,
      'event': 2,
      'event_name': 'Running Event',
      'date': date,
      'attendance_type': type,
      'attendance_type_display': display,
      'status': status,
      'scanned_at': at,
    };

void bigScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  Map<String, dynamic> missedJson(String date, String type, String display,
          {bool paid = false}) =>
      {
        'event': 2,
        'event_name': 'Running Event',
        'date': date,
        'attendance_type': type,
        'attendance_type_display': display,
        'window_start': '13:00:00',
        'window_end': '14:00:00',
        'rate': '50.00',
        'paid': paid,
      };

  Future<void> pumpHistory(WidgetTester tester, MockClient client) async {
    await tester.pumpWidget(
      Provider<ApiService>.value(
        value: ApiService(tokens: FakeTokens(), client: client),
        child: MaterialApp(
          theme: AppTheme.light,
          home: const Scaffold(body: HistoryTab()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('History lists events; the closest one drops down its missed slots',
      (tester) async {
    bigScreen(tester);
    final today = manilaToday();
    String day(int o) => ymd(DateTime(today.year, today.month, today.day + o));
    final client = MockClient((req) async {
      final path = req.url.path;
      if (path.endsWith('/student/events/')) {
        expect(req.url.queryParameters['all'], 'true');
        return json({
          'results': [
            eventJson(3, 'Future Event', day(20), day(21)),
            eventJson(2, 'Running Event', day(-1), day(1)),
            eventJson(1, 'Old Event', day(-60), day(-59)),
          ],
        });
      }
      if (path.endsWith('/student/attendance/')) {
        expect(req.url.queryParameters, isEmpty);
        return json({
          'results': [
            logJson(1, day(-1), 'AM_IN', 'AM Time-In', 'LATE',
                '${day(-1)}T08:20:00+08:00'), // stale server value -> Present
            logJson(3, day(0), 'AM_IN', 'AM Time-In', 'PRESENT',
                '${day(0)}T07:30:00+08:00'),
          ],
        });
      }
      if (path.endsWith('/student/missed-slots/')) {
        return json({
          'results': [
            missedJson(day(-1), 'PM_IN', 'PM Time-In'),
            missedJson(day(-1), 'PM_OUT', 'PM Time-Out', paid: true),
          ],
        });
      }
      return json({'detail': 'nf'}, 404);
    });
    await pumpHistory(tester, client);

    // Every event is a card; past/ongoing ones show their missed count.
    expect(find.text('Future Event'), findsOneWidget);
    expect(find.text('Old Event'), findsOneWidget);
    expect(find.text('2 missed'), findsOneWidget);
    expect(find.text('No misses'), findsOneWidget); // Old Event

    // The running event starts expanded: missed slots with their window.
    expect(find.text('Missed slots (2)'), findsOneWidget);
    expect(find.text('PM Time-In'), findsOneWidget);
    expect(find.textContaining('Scan window 1:00 PM – 2:00 PM'),
        findsNWidgets(2));
    expect(find.text('Unpaid'), findsOneWidget);
    expect(find.text('Paid'), findsOneWidget);
    expect(find.text('Attended (2)'), findsOneWidget);
    expect(find.textContaining('7:30 AM'), findsOneWidget);
    // A stale "LATE" from the server reads as Present: no Late anywhere.
    expect(find.textContaining('Late'), findsNothing);

    // Collapse it, expand the old event: nothing missed there.
    await tester.tap(find.text('Running Event'));
    await tester.pumpAndSettle();
    expect(find.text('PM Time-In'), findsNothing);
    await tester.tap(find.text('Old Event'));
    await tester.pumpAndSettle();
    expect(find.text("You haven't missed any slot so far."), findsOneWidget);
  });

  testWidgets('History still shows events when missed slots fail to load',
      (tester) async {
    bigScreen(tester);
    final today = manilaToday();
    final client = MockClient((req) async {
      if (req.url.path.endsWith('/student/events/')) {
        return json({
          'results': [
            eventJson(2, 'Running Event', ymd(today), ymd(today)),
          ],
        });
      }
      if (req.url.path.endsWith('/student/missed-slots/')) {
        return json({'detail': 'Not found.'}, 404);
      }
      return json({'results': []});
    });
    await pumpHistory(tester, client);
    expect(find.text('Running Event'), findsOneWidget);
    expect(find.textContaining("Missed slots couldn't be loaded"), findsOneWidget);
    expect(find.text('No scans recorded yet.'), findsOneWidget);
  });

  testWidgets('Fines: tapping a fine drops down its missed slots',
      (tester) async {
    bigScreen(tester);
    final client = MockClient((req) async {
      final path = req.url.path;
      if (path.endsWith('/student/balance/')) {
        return json({
          'total_fines': '100.00',
          'total_paid': '50.00',
          'outstanding': '50.00',
        });
      }
      if (path.endsWith('/student/fines/')) {
        return json({
          'results': [
            {
              'id': 9,
              'event': 2,
              'event_name': 'Running Event',
              'missed_slots': 2,
              'amount': '100.00',
              'status': 'UNPAID',
              'paid_at': null,
            },
          ],
        });
      }
      if (path.endsWith('/student/missed-slots/')) {
        return json({
          'results': [
            missedJson('2026-10-20', 'PM_IN', 'PM Time-In'),
            missedJson('2026-10-20', 'PM_OUT', 'PM Time-Out', paid: true),
          ],
        });
      }
      return json({'detail': 'nf'}, 404);
    });
    await tester.pumpWidget(
      Provider<ApiService>.value(
        value: ApiService(tokens: FakeTokens(), client: client),
        child: MaterialApp(
          theme: AppTheme.light,
          home: const Scaffold(body: FinesTab()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('2 missed slots'), findsOneWidget);
    expect(find.text('PM Time-In'), findsNothing); // collapsed
    await tester.tap(find.text('Running Event'));
    await tester.pumpAndSettle();
    expect(find.text('PM Time-In'), findsOneWidget);
    expect(find.text('PM Time-Out'), findsOneWidget);
    expect(find.text('Tue, Oct 20, 2026\nScan window 1:00 PM – 2:00 PM'),
        findsNWidgets(2));
    expect(find.text('Paid'), findsOneWidget);
  });

  group('Profile tab', () {
    const profile = {
      'id': 1,
      'student_number': '2023-0001',
      'full_name': 'Juan Cruz',
      'first_name': 'Juan',
      'middle_name': '',
      'last_name': 'Cruz',
      'username': 'jcruz',
      'year_level': '3',
      'year_level_display': '3rd Year',
      'section': 'A',
      'year_section': '3A',
      'profile_image': null,
    };
    const me = {
      'id': 1,
      'username': 'jcruz',
      'full_name': 'Juan Cruz',
      'is_admin': false,
      'is_instructor': false,
      'is_student': true,
      'role': 'student',
      'profile_image': null,
    };

    testWidgets('saves only changed fields, confirms username change, shows '
        'server field errors, updates the cached name', (tester) async {
      bigScreen(tester);
      final patches = <Map<String, dynamic>>[];
      var reject = true;
      final client = MockClient((req) async {
        final path = req.url.path;
        if (path.endsWith('/me/')) return json(me);
        if (path.endsWith('/student/profile/') && req.method == 'GET') {
          return json(profile);
        }
        if (path.endsWith('/student/profile/') && req.method == 'PATCH') {
          patches.add(jsonDecode(req.body) as Map<String, dynamic>);
          if (reject) {
            return json({
              'username': ['A user with that username already exists.']
            }, 400);
          }
          return json({
            ...profile,
            'username': 'juan.cruz',
            'first_name': 'Juanito',
            'full_name': 'Juanito Cruz',
          });
        }
        return json({'detail': 'nf'}, 404);
      });
      final auth = AuthProvider(
        apiService: ApiService(tokens: FakeTokens(), client: client),
      );
      await auth.bootstrap();

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: auth,
          child: ProxyProvider<AuthProvider, ApiService>(
            update: (_, a, _) => a.api,
            child: MaterialApp(
              theme: AppTheme.light,
              home: const Scaffold(body: ProfileTab()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Read-only school info is shown; Save is disabled until something changes.
      expect(find.text('2023-0001'), findsWidgets);
      expect(find.text('3A'), findsOneWidget);
      FilledButton save() => tester.widget<FilledButton>(find.ancestor(
          of: find.text('Save changes'), matching: find.byType(FilledButton)));
      expect(save().onPressed, isNull);

      // Change the username -> confirmation warns about login.
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Username'), '  juan.cruz ');
      await tester.pump();
      expect(save().onPressed, isNotNull);
      await tester.tap(find.text('Save changes'));
      await tester.pumpAndSettle();
      expect(find.text('Change username?'), findsOneWidget);
      await tester.tap(find.text('Change username'));
      await tester.pumpAndSettle();

      // Only the changed (trimmed) field was sent; the 400 shows under the input.
      expect(patches.single, {'username': 'juan.cruz'});
      expect(find.text('A user with that username already exists.'),
          findsOneWidget);

      // Fix it: error clears as soon as the value changes; success updates the user.
      reject = false;
      await tester.enterText(
          find.widgetWithText(TextFormField, 'First name'), 'Juanito');
      await tester.pump();
      expect(find.text('A user with that username already exists.'),
          findsOneWidget); // username still unchanged
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Username'), 'juan.cruz2');
      await tester.pumpAndSettle(); // let the error text finish fading out
      expect(find.text('A user with that username already exists.'),
          findsNothing);
      await tester.tap(find.text('Save changes'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Change username'));
      await tester.pumpAndSettle();

      expect(patches.last, {'first_name': 'Juanito', 'username': 'juan.cruz2'});
      expect(auth.user!.fullName, 'Juanito Cruz');
      expect(auth.user!.username, 'juan.cruz');
      expect(find.textContaining('Profile updated'), findsOneWidget);
    });
  });
}
