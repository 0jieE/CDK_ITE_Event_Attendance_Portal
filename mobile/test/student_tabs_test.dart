import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ite_attendance/screens/student/history_tab.dart';
import 'package:ite_attendance/screens/student/profile_tab.dart';
import 'package:ite_attendance/services/api_service.dart';
import 'package:ite_attendance/services/auth_provider.dart';
import 'package:ite_attendance/theme/app_theme.dart';
import 'package:ite_attendance/utils/manila_time.dart';
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
  testWidgets('History defaults to the event closest to today, groups by date',
      (tester) async {
    bigScreen(tester);
    final today = manilaToday();
    String day(int o) => ymd(DateTime(today.year, today.month, today.day + o));
    final attendanceQueries = <Map<String, String>>[];

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
        attendanceQueries.add(req.url.queryParameters);
        return json({
          'results': [
            logJson(1, day(-1), 'AM_IN', 'AM Time-In', 'LATE',
                '${day(-1)}T08:20:00+08:00'),
            logJson(2, day(0), 'AM_OUT', 'AM Time-Out', 'PRESENT',
                '${day(0)}T11:45:00+08:00'),
            logJson(3, day(0), 'AM_IN', 'AM Time-In', 'PRESENT',
                '${day(0)}T07:30:00+08:00'),
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
          home: const Scaffold(body: HistoryTab()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Default selection = the event whose range contains today.
    expect(find.text('Running Event'), findsOneWidget);
    expect(attendanceQueries.single, {'event': '2'});

    // Today's group comes first, slots in natural order, soft badges + time.
    final amIn = tester.getTopLeft(find.text('AM Time-In').first).dy;
    final amOut = tester.getTopLeft(find.text('AM Time-Out')).dy;
    final yesterdayAmIn = tester.getTopLeft(find.text('AM Time-In').last).dy;
    expect(amIn < amOut, isTrue);
    expect(amOut < yesterdayAmIn, isTrue);
    expect(find.text('Late'), findsOneWidget);
    expect(find.text('Present'), findsNWidgets(2));
    expect(find.text('7:30 AM'), findsOneWidget);

    // Switch to "All events": request has no event filter.
    await tester.tap(find.text('Running Event'));
    await tester.pumpAndSettle();
    expect(find.text('Future Event'), findsOneWidget);
    expect(find.text('Old Event'), findsOneWidget);
    await tester.tap(find.text('All events').last);
    await tester.pumpAndSettle();
    expect(attendanceQueries.last, isEmpty);
    expect(find.text('All events'), findsOneWidget);
  });

  testWidgets('History empty state for an event without logs', (tester) async {
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
      return json({'results': []});
    });
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
    expect(find.text('No attendance recorded for this event yet'), findsOneWidget);
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
      'email': 'juan@example.com',
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
      'email': 'juan@example.com',
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
