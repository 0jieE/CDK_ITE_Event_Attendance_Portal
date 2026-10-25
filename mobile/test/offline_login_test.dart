import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ite_attendance/screens/login_screen.dart';
import 'package:ite_attendance/services/api_service.dart';
import 'package:ite_attendance/services/auth_provider.dart';
import 'package:ite_attendance/services/connectivity_service.dart';
import 'package:ite_attendance/services/offline_credentials.dart';
import 'package:ite_attendance/services/password_hash.dart';
import 'package:ite_attendance/models/user.dart';
import 'package:ite_attendance/theme/app_theme.dart';
import 'package:provider/provider.dart';

import 'test_helpers.dart';

/// Secure storage in memory.
class MemorySecureStore extends SecureStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

String hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

const instructor = User(
  id: 7,
  username: 'ins',
  fullName: 'Ina Structor',
  isAdmin: false,
  isInstructor: true,
  isStudent: false,
  role: 'instructor',
  passwordVersion: 'v1',
);

/// A small fake backend: one account ("ins" / [password]); [down] makes
/// every request fail like a dead network.
class FakeBackend {
  bool down = false;
  String password = 'pw-correct';
  String passwordVersion = 'v1';
  bool admin = false;
  int logins = 0;

  late final client = MockClient((req) async {
    if (down) throw http.ClientException('Network is unreachable');
    final path = req.url.path;
    if (path.endsWith('/auth/login/')) {
      logins++;
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      if (body['username'] == 'ins' && body['password'] == password) {
        return _json({'access': 'access-ok', 'refresh': 'refresh-ok'});
      }
      return _json({'detail': 'No active account found'}, 401);
    }
    if (path.endsWith('/auth/refresh/')) return _json({'detail': 'expired'}, 401);
    if (path.endsWith('/me/')) {
      if (req.headers['Authorization'] != 'Bearer access-ok') {
        return _json({'detail': 'Not authenticated'}, 401);
      }
      return _json({
        'id': 7,
        'username': 'ins',
        'full_name': 'Ina Structor',
        'is_admin': admin,
        'is_instructor': !admin,
        'is_student': false,
        'role': admin ? 'admin' : 'instructor',
        'password_version': passwordVersion,
      });
    }
    return _json({'detail': 'not found'}, 404);
  });

  static http.Response _json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body), status,
      headers: {'content-type': 'application/json'});
}

void main() {
  test('PBKDF2-HMAC-SHA256 matches the published test vectors', () {
    List<int> run(int c) => pbkdf2Sha256(utf8.encode('password'), utf8.encode('salt'), c, 32);
    expect(hex(run(1)), '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b');
    expect(hex(run(2)), 'ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43');
    expect(constantTimeEquals([1, 2], [1, 2]), isTrue);
    expect(constantTimeEquals([1, 2], [1, 3]), isFalse);
  });

  group('OfflineCredentials', () {
    late MemorySecureStore store;
    late DateTime now;
    OfflineCredentials creds() => OfflineCredentials(
        store: store, iterations: 10, useIsolate: false, clock: () => now);

    setUp(() {
      store = MemorySecureStore();
      now = DateTime.utc(2026, 10, 1, 8);
    });

    test('stores only a salted hash, and verifies the password', () async {
      final c = creds();
      await c.remember('ins', 'pw-correct', instructor);
      final raw = store.values.values.single;
      expect(raw, isNot(contains('pw-correct')));
      expect(store.values.keys.single, isNot(contains('ins')));
      expect(jsonDecode(raw)['salt'], isNotEmpty);

      final ok = await c.verify('ins', 'pw-correct');
      expect(ok.status, OfflineLoginStatus.ok);
      expect(ok.user!.fullName, 'Ina Structor');
      expect((await c.verify('nobody', 'x')).status, OfflineLoginStatus.unknownAccount);
    });

    test('the same password gets a different salt and hash each time', () async {
      final c = creds();
      await c.remember('ins', 'same', instructor);
      final first = store.values.values.single;
      await c.remember('ins', 'same', instructor);
      expect(store.values.values.single, isNot(first));
    });

    test('wrong passwords: 5 tries, then a wait that doubles', () async {
      final c = creds();
      await c.remember('ins', 'pw-correct', instructor);
      for (var left = 4; left >= 1; left--) {
        final r = await c.verify('ins', 'nope');
        expect(r.status, OfflineLoginStatus.wrongPassword);
        expect(r.attemptsLeft, left);
      }
      var r = await c.verify('ins', 'nope');
      expect(r.status, OfflineLoginStatus.locked);
      expect(r.retryAfter, const Duration(seconds: 30));
      // Locked even for the right password.
      expect((await c.verify('ins', 'pw-correct')).status, OfflineLoginStatus.locked);
      expect((await c.verify('ins', 'pw-correct')).message, contains('Try again in'));

      now = now.add(const Duration(seconds: 31));
      r = await c.verify('ins', 'nope');
      expect(r.retryAfter, const Duration(minutes: 1));

      now = now.add(const Duration(minutes: 2));
      expect((await c.verify('ins', 'pw-correct')).status, OfflineLoginStatus.ok);
      // A success resets the count.
      expect((await c.verify('ins', 'nope')).attemptsLeft, 4);
    });

    test('expires 30 days after the last online sign-in', () async {
      final c = creds();
      await c.remember('ins', 'pw-correct', instructor);
      now = now.add(const Duration(days: 29));
      expect((await c.verify('ins', 'pw-correct')).status, OfflineLoginStatus.ok);
      now = now.add(const Duration(days: 2));
      final r = await c.verify('ins', 'pw-correct');
      expect(r.status, OfflineLoginStatus.expired);
      expect(r.message, contains('Connect to the internet to sign in again'));
      expect(await c.has('ins'), isFalse);
    });

    test('forgetIfMatches drops only the remembered password', () async {
      final c = creds();
      await c.remember('ins', 'pw-correct', instructor);
      await c.forgetIfMatches('ins', 'typo');
      expect(await c.has('ins'), isTrue);
      await c.forgetIfMatches('ins', 'pw-correct');
      expect(await c.has('ins'), isFalse);
    });
  });

  group('AuthProvider offline sign-in', () {
    late FakeBackend server;
    late MemorySecureStore store;
    late ConnectivityService connectivity;
    late FakeTokens tokens;

    AuthProvider auth() => AuthProvider(
          apiService: ApiService(tokens: tokens, client: server.client),
          offlineLogin: OfflineCredentials(
              store: store, iterations: 10, useIsolate: false),
          connectivity: connectivity,
        );

    /// Let fire-and-forget work (storing the hash) finish.
    Future<void> settle() => Future.delayed(const Duration(milliseconds: 20));

    setUp(() {
      server = FakeBackend();
      store = MemorySecureStore();
      connectivity = ConnectivityService(listen: false);
      tokens = FakeTokens(access: null, refresh: null);
    });

    test('after one online sign-in, the account signs in offline', () async {
      final a = auth();
      expect(await a.login('ins', 'pw-correct'), isTrue);
      expect(a.offlineSession, isFalse);
      await settle();
      await a.logout();

      server.down = true;
      expect(await a.login(' ins ', 'pw-correct'), isTrue);
      expect(a.status, AuthStatus.authenticated);
      expect(a.offlineSession, isTrue);
      expect(a.user!.isInstructor, isTrue);
      expect(connectivity.isOnline, isFalse); // the failed request said so
    });

    test('known offline: no request is even tried', () async {
      final a = auth();
      await a.login('ins', 'pw-correct');
      await settle();
      await a.logout();
      final before = server.logins;
      connectivity.reportUnreachable();
      expect(await a.login('ins', 'pw-correct'), isTrue);
      expect(server.logins, before);
    });

    test('offline: wrong password, and an account never used here', () async {
      final a = auth();
      await a.login('ins', 'pw-correct');
      await settle();
      await a.logout();
      server.down = true;

      expect(await a.login('ins', 'wrong'), isFalse);
      expect(a.error, contains('4 tries left'));
      expect(await a.login('someone', 'x'), isFalse);
      expect(a.error, contains("hasn't signed in on this phone"));
      expect(a.status, AuthStatus.unauthenticated);
    });

    test('admins are never remembered for offline sign-in', () async {
      server.admin = true;
      final a = auth();
      await a.login('ins', 'pw-correct');
      await settle();
      expect(store.values, isEmpty);
    });

    test('a password refused online drops the stored one; a typo does not', () async {
      final a = auth();
      await a.login('ins', 'pw-correct');
      await settle();
      await a.logout();

      expect(await a.login('ins', 'typo'), isFalse);
      await settle();
      expect(store.values, isNotEmpty);

      server.password = 'changed-by-adviser';
      expect(await a.login('ins', 'pw-correct'), isFalse);
      await settle();
      expect(store.values, isEmpty);
    });

    test('back online without a server session: sign in again', () async {
      final a = auth();
      await a.login('ins', 'pw-correct');
      await settle();
      await a.logout(); // tokens gone
      server.down = true;
      await a.login('ins', 'pw-correct');
      expect(a.offlineSession, isTrue);

      server.down = false;
      connectivity.reportReachable(); // the connection is back
      await settle();
      expect(a.status, AuthStatus.unauthenticated);
      expect(a.notice, contains('Sign in again'));
      expect(a.lastUsername, 'ins');
      // Offline sign-in itself is still there for next time.
      expect(store.values, isNotEmpty);
    });

    test('back online with a valid session: carries on online', () async {
      final a = auth();
      await a.login('ins', 'pw-correct');
      await settle();
      // App restarted with no connection: opens from the cached user.
      server.down = true;
      final restarted = auth();
      await restarted.bootstrap();
      expect(restarted.status, AuthStatus.authenticated);
      expect(restarted.offlineSession, isTrue);

      server.down = false;
      connectivity.reportReachable();
      await settle();
      expect(restarted.status, AuthStatus.authenticated);
      expect(restarted.offlineSession, isFalse);
    });

    test('back online after the password changed elsewhere: signed out', () async {
      final a = auth();
      await a.login('ins', 'pw-correct');
      await settle();
      server.down = true;
      final restarted = auth();
      await restarted.bootstrap();
      expect(restarted.offlineSession, isTrue);

      server
        ..down = false
        ..passwordVersion = 'v2';
      connectivity.reportReachable();
      await settle();
      expect(restarted.status, AuthStatus.unauthenticated);
      expect(store.values, isEmpty); // the stale hash is gone
      expect(await tokens.hasTokens, isFalse);
    });

    test('"Forget this phone" turns offline sign-in off', () async {
      final a = auth();
      await a.login('ins', 'pw-correct');
      await settle();
      await a.logout(forgetDevice: true);
      expect(store.values, isEmpty);
      expect(a.lastUsername, isNull);
    });
  });

  testWidgets('login screen: offline note and the back-online notice', (tester) async {
    final connectivity = ConnectivityService(listen: false);
    final server = FakeBackend()..down = true;
    final a = AuthProvider(
      apiService: ApiService(tokens: FakeTokens(access: null, refresh: null), client: server.client),
      offlineLogin: OfflineCredentials(store: MemorySecureStore(), iterations: 10, useIsolate: false),
      connectivity: connectivity,
    );
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: a),
        ChangeNotifierProvider.value(value: connectivity),
      ],
      child: MaterialApp(theme: AppTheme.light, home: const LoginScreen()),
    ));
    expect(find.textContaining("You're offline"), findsNothing);
    connectivity.reportUnreachable();
    await tester.pump();
    expect(find.textContaining('signed in on this phone before'), findsOneWidget);
  });
}
