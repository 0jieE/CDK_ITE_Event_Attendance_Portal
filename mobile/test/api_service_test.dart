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
  'email': 'juan@example.com',
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

  test('friendlyError maps non-API errors to a connection message', () {
    expect(friendlyError(Exception('boom')), contains('Could not reach'));
    expect(friendlyError(SessionExpired()), contains('session'));
  });
}
