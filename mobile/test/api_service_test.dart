import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ite_attendance/services/api_service.dart';
import 'package:ite_attendance/utils/errors.dart';
import 'package:ite_attendance/utils/image_type.dart';

import 'test_helpers.dart';

http.Response json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

const profileJson = {
  'id': 1,
  'student_number': '2023-0001',
  'full_name': 'Juan Cruz',
  'first_name': 'Juan',
  'middle_name': '',
  'last_name': 'Cruz',
  'username': 'jcruz2',
  'year_level': '3',
  'year_level_display': '3rd Year',
  'section': 'A',
  'year_section': '3A',
  'profile_image': null,
};

void main() {
  group('pagination', () {
    test('studentEventsAll follows `next` by page number and keeps all=true',
        () async {
      final seen = <Uri>[];
      final client = MockClient((req) async {
        seen.add(req.url);
        if (req.url.queryParameters['page'] == '2') {
          return json({
            'count': 2,
            'next': null,
            'results': [eventJson(2, 'Old', '2026-01-01', '2026-01-02')],
          });
        }
        return json({
          'count': 2,
          // Proxy-style absolute URL on another host: only `page` is used.
          'next': 'http://internal:8000/api/student/events/?all=true&page=2',
          'results': [eventJson(1, 'New', '2026-10-01', '2026-10-02')],
        });
      });
      final api = ApiService(tokens: FakeTokens(), client: client);
      final events = await api.studentEventsAll();
      expect(events.map((e) => e.id), [1, 2]);
      expect(seen.length, 2);
      expect(seen[0].queryParameters, {'all': 'true'});
      expect(seen[1].queryParameters, {'all': 'true', 'page': '2'});
      expect(seen[1].host, seen[0].host);
    });

    test('studentAttendance passes the event filter on every page', () async {
      final seen = <Uri>[];
      final client = MockClient((req) async {
        seen.add(req.url);
        final page2 = req.url.queryParameters['page'] == '2';
        return json({
          'next': page2 ? null : 'http://x/api/student/attendance/?event=7&page=2',
          'results': [
            {
              'id': page2 ? 2 : 1,
              'event': 7,
              'event_name': 'E',
              'date': '2026-10-06',
              'attendance_type': 'AM_IN',
              'attendance_type_display': 'AM Time-In',
              'status': 'PRESENT',
              'scanned_at': '2026-10-06T08:00:00+08:00',
            }
          ],
        });
      });
      final api = ApiService(tokens: FakeTokens(), client: client);
      final logs = await api.studentAttendance(event: 7);
      expect(logs.map((l) => l.id), [1, 2]);
      expect(seen.every((u) => u.queryParameters['event'] == '7'), isTrue);
    });
  });

  group('token refresh', () {
    test('multipart upload refreshes on 401 and retries with the new token',
        () async {
      final auths = <String?>[];
      final bodies = <String>[];
      var refreshCalls = 0;
      final tokens = FakeTokens();
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/auth/refresh/')) {
          refreshCalls++;
          return json({'access': 'access-2', 'refresh': 'refresh-2'});
        }
        expect(req.url.path, endsWith('/me/photo/'));
        expect(req.method, 'POST');
        expect(req.headers['content-type'], startsWith('multipart/form-data'));
        auths.add(req.headers['Authorization']);
        bodies.add(latin1.decode(req.bodyBytes));
        if (auths.length == 1) return json({'detail': 'expired'}, 401);
        return json({'profile_image': 'http://x/p.png'}, 201);
      });
      final api = ApiService(tokens: tokens, client: client);

      final url = await api.uploadPhoto(
        Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3]),
        ImageType.png,
      );

      expect(url, 'http://x/p.png');
      expect(refreshCalls, 1);
      expect(auths, ['Bearer access-1', 'Bearer access-2']);
      // The retry carries a complete, fresh multipart body.
      for (final b in bodies) {
        expect(b, contains('name="image"'));
        expect(b, contains('filename="profile.png"'));
        expect(b, contains('image/png'));
      }
      expect(await tokens.refresh, 'refresh-2'); // rotated token stored
    });

    test('a 401 that survives the refresh ends the session', () async {
      final tokens = FakeTokens();
      var expired = false;
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/auth/refresh/')) {
          return json({'detail': 'bad'}, 401);
        }
        return json({'detail': 'nope'}, 401);
      });
      final api = ApiService(tokens: tokens, client: client)
        ..onUnauthorized = () => expired = true;

      await expectLater(
        api.uploadPhoto(Uint8List.fromList([0xFF, 0xD8, 0xFF]), ImageType.jpeg),
        throwsA(isA<SessionExpired>()),
      );
      expect(expired, isTrue);
      expect(await tokens.hasTokens, isFalse);
    });

    test('JSON requests still refresh and retry', () async {
      var calls = 0;
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/auth/refresh/')) {
          return json({'access': 'access-2'});
        }
        calls++;
        return calls == 1 ? json({'detail': 'x'}, 401) : json(profileJson);
      });
      final api = ApiService(tokens: FakeTokens(), client: client);
      expect((await api.studentProfile()).username, 'jcruz2');
      expect(calls, 2);
    });
  });

  group('profile endpoints', () {
    test('updateProfile PATCHes only the given fields', () async {
      late http.Request seen;
      final client = MockClient((req) async {
        seen = req;
        return json(profileJson);
      });
      final api = ApiService(tokens: FakeTokens(), client: client);
      final p = await api.updateProfile({'username': 'jcruz2'});
      expect(seen.method, 'PATCH');
      expect(seen.url.path, endsWith('/student/profile/'));
      expect(jsonDecode(seen.body), {'username': 'jcruz2'});
      expect(seen.headers['Authorization'], 'Bearer access-1');
      expect(p.username, 'jcruz2');
      expect(p.firstName, 'Juan');
    });

    test('field errors surface on ApiException.data', () async {
      final client = MockClient((req) async => json({
            'username': ['A user with that username already exists.']
          }, 400));
      final api = ApiService(tokens: FakeTokens(), client: client);
      try {
        await api.updateProfile({'username': 'taken'});
        fail('expected ApiException');
      } on ApiException catch (e) {
        expect(e.statusCode, 400);
        expect(fieldErrors(e),
            {'username': 'A user with that username already exists.'});
        expect(friendlyError(e), 'A user with that username already exists.');
      }
    });

    test('changePassword accepts an empty 204 and reports validator errors',
        () async {
      var ok = true;
      late Map<String, dynamic> sent;
      final client = MockClient((req) async {
        sent = jsonDecode(req.body) as Map<String, dynamic>;
        return ok
            ? http.Response('', 204)
            : json({
                'new_password': ['Too common.', 'Too short.']
              }, 400);
      });
      final api = ApiService(tokens: FakeTokens(), client: client);
      await api.changePassword(currentPassword: 'old', newPassword: 'newpass123');
      expect(sent, {'current_password': 'old', 'new_password': 'newpass123'});

      ok = false;
      try {
        await api.changePassword(currentPassword: 'old', newPassword: 'x');
        fail('expected ApiException');
      } on ApiException catch (e) {
        expect(fieldErrors(e)['new_password'], 'Too common. Too short.');
      }
    });

    test('deletePhoto sends DELETE and accepts 204', () async {
      late http.Request seen;
      final client = MockClient((req) async {
        seen = req;
        return http.Response('', 204);
      });
      final api = ApiService(tokens: FakeTokens(), client: client);
      await api.deletePhoto();
      expect(seen.method, 'DELETE');
      expect(seen.url.path, endsWith('/me/photo/'));
    });
  });

  group('register', () {
    const detail = 'Registration received. The Department Adviser must '
        'approve your account before you can sign in.';

    Future<String> reg(ApiService api, {bool photo = false}) => api.register(
          studentNumber: '2024-0100',
          firstName: 'Ana',
          lastName: 'Reyes',
          username: 'ana.reyes',
          password: 'S3cure-pass!',
          yearLevel: '2',
          photo: photo
              ? Uint8List.fromList(
                  [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 7, 7])
              : null,
          photoType: photo ? ImageType.png : null,
        );

    test('sends JSON without Authorization or optional blanks', () async {
      late http.Request seen;
      final paths = <String>[];
      final client = MockClient((req) async {
        paths.add(req.url.path);
        seen = req;
        return json({'status': 'PENDING', 'detail': detail}, 201);
      });
      // Tokens exist (e.g. a stale session) but must not be attached.
      final api = ApiService(tokens: FakeTokens(), client: client);

      expect(await reg(api), detail);
      expect(seen.method, 'POST');
      expect(seen.url.path, endsWith('/auth/register/'));
      expect(seen.headers['content-type'], startsWith('application/json'));
      expect(seen.headers.containsKey('Authorization'), isFalse);
      expect(jsonDecode(seen.body), {
        'student_number': '2024-0100',
        'first_name': 'Ana',
        'last_name': 'Reyes',
        'username': 'ana.reyes',
        'password': 'S3cure-pass!',
        'year_level': '2',
      });
      expect(paths.length, 1);
    });

    test('sends optional middle name and section when given', () async {
      late Map<String, dynamic> sent;
      final client = MockClient((req) async {
        sent = jsonDecode(req.body) as Map<String, dynamic>;
        return json({'detail': detail}, 201);
      });
      final api = ApiService(tokens: FakeTokens(), client: client);
      await api.register(
        studentNumber: '1',
        firstName: 'A',
        middleName: 'B',
        lastName: 'C',
        username: 'abc',
        password: 'x',
        yearLevel: '1',
        section: 'A',
      );
      expect(sent['middle_name'], 'B');
      expect(sent['section'], 'A');
    });

    test('uses multipart (profile_image) when a photo is attached', () async {
      late http.Request seen;
      final client = MockClient((req) async {
        seen = req;
        return json({'detail': detail}, 201);
      });
      final api = ApiService(tokens: FakeTokens(), client: client);

      await reg(api, photo: true);
      final body = latin1.decode(seen.bodyBytes);
      expect(seen.url.path, endsWith('/auth/register/'));
      expect(seen.headers['content-type'], startsWith('multipart/form-data'));
      expect(seen.headers.containsKey('Authorization'), isFalse);
      expect(body, contains('name="profile_image"'));
      expect(body, contains('filename="profile.png"'));
      expect(body, contains('image/png'));
      expect(body, contains('name="student_number"'));
      expect(body, contains('2024-0100'));
      expect(body, contains('name="year_level"'));
      expect(body, isNot(contains('name="middle_name"')));
    });

    test('falls back to a default message when the body has no detail',
        () async {
      final client = MockClient((req) async => json({}, 201));
      final api = ApiService(tokens: FakeTokens(), client: client);
      expect(await reg(api), contains('Department Adviser'));
    });

    test('400 carries per-field errors', () async {
      final client = MockClient((req) async => json({
            'student_number': [
              'A student with that number is already registered.'
            ],
            'password': ['This password is too common.', 'Too short.'],
          }, 400));
      final api = ApiService(tokens: FakeTokens(), client: client);
      try {
        await reg(api);
        fail('expected ApiException');
      } on ApiException catch (e) {
        expect(e.statusCode, 400);
        expect(fieldErrors(e), {
          'student_number': 'A student with that number is already registered.',
          'password': 'This password is too common. Too short.',
        });
      }
    });

    test('429 becomes a friendly rate-limit error', () async {
      final client = MockClient((req) async => json({
            'detail':
                'Request was throttled. Expected available in 3000 seconds.'
          }, 429));
      final api = ApiService(tokens: FakeTokens(), client: client);
      try {
        await reg(api);
        fail('expected ApiException');
      } on ApiException catch (e) {
        expect(e.isRateLimited, isTrue);
        expect(friendlyError(e), 'Too many attempts, try again later.');
      }
    });

    test('a 401 is not treated as an expired session (no refresh, no logout)',
        () async {
      final paths = <String>[];
      var expired = false;
      final tokens = FakeTokens();
      final client = MockClient((req) async {
        paths.add(req.url.path);
        return json({'detail': 'nope'}, 401);
      });
      final api = ApiService(tokens: tokens, client: client)
        ..onUnauthorized = () => expired = true;
      await expectLater(reg(api), throwsA(isA<ApiException>()));
      expect(paths.single, endsWith('/auth/register/'));
      expect(expired, isFalse);
      expect(await tokens.hasTokens, isTrue);
    });

    test('a non-JSON error page still gives an ApiException', () async {
      final client = MockClient(
          (req) async => http.Response('<html>Bad gateway</html>', 502));
      final api = ApiService(tokens: FakeTokens(), client: client);
      await expectLater(
        reg(api),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 502)),
      );
    });
  });

  group('login outcomes', () {
    ApiService apiFor(http.Response Function() respond, List<String> paths,
        {void Function()? onExpired}) {
      return ApiService(
        tokens: FakeTokens(access: null, refresh: null),
        client: MockClient((req) async {
          paths.add(req.url.path);
          return respond();
        }),
      )..onUnauthorized = onExpired;
    }

    test('403 PENDING_APPROVAL exposes its code and is not a session expiry',
        () async {
      final paths = <String>[];
      var expired = false;
      final api = apiFor(
        () => json({
          'detail': 'Waiting for approval.',
          'code': 'PENDING_APPROVAL',
        }, 403),
        paths,
        onExpired: () => expired = true,
      );
      try {
        await api.login('ana', 'pw');
        fail('expected ApiException');
      } on ApiException catch (e) {
        expect(e.statusCode, 403);
        expect(e.code, ApiCodes.pendingApproval);
        expect(e.isPendingApproval, isTrue);
        expect(e.isRegistrationRejected, isFalse);
        expect(e.message, 'Waiting for approval.');
      }
      expect(paths, hasLength(1)); // login only: no /auth/refresh/ call
      expect(paths.single, endsWith('/auth/login/'));
      expect(expired, isFalse);
    });

    test('403 REGISTRATION_REJECTED keeps the adviser reason in the message',
        () async {
      final api = apiFor(
        () => json({
          'detail': 'Your registration was declined: wrong section.',
          'code': 'REGISTRATION_REJECTED',
        }, 403),
        [],
      );
      try {
        await api.login('ana', 'pw');
        fail('expected ApiException');
      } on ApiException catch (e) {
        expect(e.code, ApiCodes.registrationRejected);
        expect(e.isRegistrationRejected, isTrue);
        expect(e.message, contains('wrong section'));
      }
    });

    test('401 wrong credentials: friendly message and no code', () async {
      final api = apiFor(
        () => json(
            {'detail': 'No active account found with the given credentials'},
            401),
        [],
      );
      try {
        await api.login('ana', 'bad');
        fail('expected ApiException');
      } on ApiException catch (e) {
        expect(e.statusCode, 401);
        expect(e.code, isNull);
        expect(e.message, 'Invalid username or password.');
      }
    });

    test('a non-string code is ignored', () {
      expect(ApiException(400, 'x', {'code': 5}).code, isNull);
      expect(ApiException(400, 'x', ['a']).code, isNull);
      expect(ApiException(400, 'x').code, isNull);
    });
  });

  test('friendlyError maps non-API errors to a connection message', () {
    expect(friendlyError(Exception('boom')), contains('Could not reach'));
    expect(friendlyError(SessionExpired()), contains('session'));
  });
}
