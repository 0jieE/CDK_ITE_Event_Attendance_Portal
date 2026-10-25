// End to end, offline: sign in online once -> the network dies -> the app is
// restarted -> offline sign-in -> every screen's data is there.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ite_students/screens/student/generate_qr_tab.dart';
import 'package:ite_students/services/api_service.dart';
import 'package:ite_students/services/auth_provider.dart';
import 'package:ite_students/services/connectivity_service.dart';
import 'package:ite_students/services/offline_credentials.dart';
import 'package:ite_students/services/offline_prefetch.dart';
import 'package:ite_students/theme/app_theme.dart';
import 'package:ite_students/utils/manila_time.dart';
import 'package:ite_students/widgets/qr_code_view.dart';
import 'package:provider/provider.dart';

import 'offline_login_test.dart' show MemorySecureStore;
import 'test_helpers.dart';

/// The server for one student (id 9) with one event running today. [down]
/// kills the network; [requests] counts attempts.
class Backend {
  bool down = false;
  int requests = 0;
  final today = ymd(manilaToday());

  late final client = MockClient((req) async {
    requests++;
    if (down) throw http.ClientException('Network is unreachable');
    final path = req.url.path;
    final q = req.url.queryParameters;
    final event = eventJson(3, 'Tech Week', today, today);
    if (path.endsWith('/auth/login/')) {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      return body['password'] == 'pw'
          ? _json({'access': 'a', 'refresh': 'r'})
          : _json({'detail': 'No active account found'}, 401);
    }
    if (path.endsWith('/me/')) {
      return _json({
        'id': 9,
        'username': 'user',
        'full_name': 'Stu Dent',
        'is_student': true,
        'role': 'student',
      });
    }
    if (path.endsWith('/student/events/')) return _json({'results': [event]});
    if (path.endsWith('/student/qr/')) {
      expect(q, {'event': '3', 'date': today});
      return _json({
        'results': [
          {'id': 1, 'token': 'MY-QR-TOKEN', 'event': 3, 'date': today},
        ],
      });
    }
    if (path.endsWith('/student/attendance/')) {
      return _json({
        'results': [
          {'id': 1, 'event': 3, 'event_name': 'Tech Week', 'date': today,
           'attendance_type': 'AM_IN', 'status': 'PRESENT',
           'scanned_at': '${today}T07:15:00+08:00'},
          {'id': 2, 'event': 4, 'event_name': 'Other', 'date': today,
           'attendance_type': 'AM_IN', 'status': 'ABSENT'},
        ],
      });
    }
    if (path.endsWith('/student/fines/')) {
      return _json({
        'results': [
          {'id': 1, 'event': 4, 'event_name': 'Other', 'amount': '50.00',
           'missed_slots': 1, 'status': 'UNPAID'},
        ],
      });
    }
    if (path.endsWith('/student/balance/')) {
      return _json({'total_fines': '50.00', 'total_paid': '0.00', 'outstanding': '50.00'});
    }
    if (path.endsWith('/student/profile/')) {
      return _json({'id': 1, 'student_number': 'S-1', 'username': 'user', 'full_name': 'Stu Dent'});
    }
    return _json({'detail': 'not found'}, 404);
  });

  static http.Response _json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body), status,
      headers: {'content-type': 'application/json'});
}

/// One "app run": fresh objects over the same phone storage (prefs + store).
class AppRun {
  final ConnectivityService connectivity = ConnectivityService(listen: false);
  late final AuthProvider auth;

  AppRun(Backend server, MemorySecureStore store) {
    auth = AuthProvider(
      apiService: ApiService(
          tokens: FakeTokens(access: null, refresh: null), client: server.client),
      offlineLogin:
          OfflineCredentials(store: store, iterations: 10, useIsolate: false),
      connectivity: connectivity,
      allowedUser: (u) => u.isStudent,
    );
    // Wired exactly as in main.dart.
    auth.api
      ..onReachable = connectivity.reportReachable
      ..onUnreachable = connectivity.reportUnreachable
      ..isKnownOffline = (() => !connectivity.isOnline);
  }

  ApiService get api => auth.api;
}

void main() {
  late MemorySecureStore store;
  setUp(() => store = MemorySecureStore());

  /// Online sign-in + the download that follows it, then log out.
  Future<void> firstRunOnline(Backend server) async {
    final run = AppRun(server, store);
    expect(await run.auth.login('user', 'pw'), isTrue);
    await prefetchForOffline(run.api, run.auth.user!);
    await Future<void>.delayed(const Duration(milliseconds: 20)); // hash saved
    await run.auth.logout();
  }

  test('everything is there after an offline cold start', () async {
    final server = Backend();
    await firstRunOnline(server);

    server.down = true;
    final run = AppRun(server, store); // restarted
    await run.auth.bootstrap();
    expect(run.auth.status, AuthStatus.unauthenticated); // logged out before
    expect(await run.auth.login('user', 'pw'), isTrue);
    expect(run.auth.offlineSession, isTrue);

    final today = manilaToday();
    final before = server.requests;
    final api = run.api;
    expect((await api.studentEvents()).single.name, 'Tech Week');
    expect((await api.studentEventsAll()).single.name, 'Tech Week');
    expect((await api.studentQrs(event: 3, date: apiDate(today))).single.token,
        'MY-QR-TOKEN');
    // History for one event, from the saved copy of all of them.
    final history = await api.studentAttendance(event: 3);
    expect(history.single.isPresent, isTrue);
    expect((await api.studentFines()).single.amount, '50.00');
    expect((await api.studentBalance()).outstanding, '50.00');
    expect((await api.studentProfile()).studentNumber, 'S-1');
    // Known offline: none of that even tried the network.
    expect(server.requests, before);
    expect(api.offlineDataTime.value, isNotNull); // "data saved <time>"
  });

  test('nothing downloaded yet: a clear message, never an empty list', () async {
    final server = Backend()..down = true;
    final run = AppRun(server, store);
    run.auth.api.cacheOwner = 9;
    await expectLater(
        run.api.studentEvents(),
        throwsA(isA<OfflineDataMissing>().having((e) => e.message, 'message',
            contains('Open the app once with internet'))));
  });

  testWidgets('the QR screen shows the saved QR offline', (tester) async {
    final server = Backend();
    await tester.runAsync(() => firstRunOnline(server));

    server.down = true;
    final run = AppRun(server, store);
    await tester.runAsync(() => run.auth.login('user', 'pw'));
    expect(run.auth.offlineSession, isTrue);

    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: run.connectivity),
        ChangeNotifierProvider.value(value: run.auth),
        Provider<ApiService>.value(value: run.api),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        home: const Scaffold(body: GenerateQrTab()),
      ),
    ));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(find.text('Tech Week'), findsWidgets);
    expect(find.byType(QrCodeView), findsOneWidget);
    // Generating stays off while offline.
    expect(find.text('Generate QR'), findsNothing);
  });
}
