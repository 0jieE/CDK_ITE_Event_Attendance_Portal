// End to end, offline: sign in online once -> the network dies -> the app is
// restarted -> offline sign-in -> every screen's data is there.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ite_instructors/services/api_service.dart';
import 'package:ite_instructors/services/auth_provider.dart';
import 'package:ite_instructors/services/connectivity_service.dart';
import 'package:ite_instructors/services/offline_credentials.dart';
import 'package:ite_instructors/services/offline_prefetch.dart';
import 'package:ite_instructors/services/offline_scan_service.dart';
import 'package:ite_instructors/utils/manila_time.dart';

import 'instructor_fixtures.dart';
import 'offline_login_test.dart' show MemorySecureStore;
import 'test_helpers.dart';

/// The server for one instructor (id 7), or a student (id 9) who opens this
/// app by mistake, with one event running today. [down] kills the network;
/// [requests] counts attempts.
class Backend {
  final bool instructor;
  Backend({this.instructor = true});

  bool down = false;
  int requests = 0;
  final today = ymd(manilaToday());

  late final client = MockClient((req) async {
    requests++;
    if (down) throw http.ClientException('Network is unreachable');
    final path = req.url.path;
    final event = eventJson(3, 'Tech Week', today, today);
    if (path.endsWith('/auth/login/')) {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      return body['password'] == 'pw'
          ? _json({'access': 'a', 'refresh': 'r'})
          : _json({'detail': 'No active account found'}, 401);
    }
    if (path.endsWith('/me/')) {
      return _json({
        'id': instructor ? 7 : 9,
        'username': 'user',
        'full_name': instructor ? 'Ina Structor' : 'Stu Dent',
        'is_instructor': instructor,
        'is_student': !instructor,
        'role': instructor ? 'instructor' : 'student',
      });
    }
    if (path.endsWith('/instructor/offline-pack/')) {
      return _json({
        'server_time': DateTime.now().toIso8601String(),
        'date': today,
        'events': [event],
        'codes': [],
      });
    }
    if (path.endsWith('/instructor/events/3/attendance/')) {
      return _json(sampleAttendanceJson(date: today, dates: [today]));
    }
    if (path.endsWith('/instructor/events/')) return _json({'results': [event]});
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
  late final OfflineScanService scans;

  AppRun(Backend server, MemorySecureStore store) {
    auth = AuthProvider(
      apiService: ApiService(
          tokens: FakeTokens(access: null, refresh: null), client: server.client),
      offlineLogin:
          OfflineCredentials(store: store, iterations: 10, useIsolate: false),
      connectivity: connectivity,
    );
    // Wired exactly as in main.dart.
    auth.api
      ..onReachable = connectivity.reportReachable
      ..onUnreachable = connectivity.reportUnreachable
      ..isKnownOffline = (() => !connectivity.isOnline);
    scans = OfflineScanService(api: auth.api, connectivity: connectivity);
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
    await run.scans.attach(run.auth.user!.isInstructor ? run.auth.user!.id : null);
    await prefetchForOffline(run.api, run.auth.user!, scans: run.scans);
    await Future<void>.delayed(const Duration(milliseconds: 20)); // hash saved
    await run.auth.logout();
  }

  test('instructor: events, pack and roster after an offline cold start', () async {
    final server = Backend();
    await firstRunOnline(server);

    server.down = true;
    final run = AppRun(server, store);
    await run.auth.bootstrap();
    expect(await run.auth.login('user', 'pw'), isTrue);
    expect(run.auth.offlineSession, isTrue);

    final events = run.scans.loadEvents(); // asked before the pack loads
    await run.scans.attach(run.auth.user!.id);
    expect((await events).single.name, 'Tech Week');
    expect(run.scans.pack, isNotNull);
    expect((await run.api.instructorEventsAll()).single.name, 'Tech Week');
    final roster = await run.api.instructorEventAttendance(3);
    expect(roster.students, hasLength(3));
    expect(run.api.offlineDataTime.value, isNotNull); // "data saved <time>"
  });

  test('a student is neither remembered for offline sign-in nor prefetched',
      () async {
    final server = Backend(instructor: false);
    await firstRunOnline(server);
    // Only the login and /me/ were asked for: nothing to download.
    expect(server.requests, 2);

    server.down = true;
    final run = AppRun(server, store);
    await run.auth.bootstrap();
    expect(await run.auth.login('user', 'pw'), isFalse);
    expect(run.auth.status, AuthStatus.unauthenticated);
  });

  test('nothing downloaded yet: a clear message, never an empty list', () async {
    final server = Backend()..down = true;
    final run = AppRun(server, store);
    run.auth.api.cacheOwner = 7;
    await expectLater(
        run.api.instructorEventsAll(),
        throwsA(isA<OfflineDataMissing>().having((e) => e.message, 'message',
            contains('Open the app once with internet'))));
  });
}
