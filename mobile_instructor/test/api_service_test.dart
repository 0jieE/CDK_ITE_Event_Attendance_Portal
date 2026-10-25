import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ite_instructors/services/api_service.dart';
import 'package:ite_instructors/utils/errors.dart';

import 'test_helpers.dart';

http.Response json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

const meJson = {
  'id': 7,
  'username': 'ina',
  'full_name': 'Ina Structor',
  'is_admin': false,
  'is_instructor': true,
  'is_student': false,
  'role': 'instructor',
};

void main() {
  group('pagination', () {
    test('instructorEventsAll re-sends only the page number of `next`',
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
          'next': 'http://internal:8000/api/instructor/events/?all=true&page=2',
          'results': [eventJson(1, 'New', '2026-10-01', '2026-10-02')],
        });
      });
      final api = ApiService(tokens: FakeTokens(), client: client);
      final events = await api.instructorEventsAll();
      expect(events.map((e) => e.id), [1, 2]);
      expect(seen.length, 2);
      expect(seen[0].queryParameters, {'all': 'true'});
      expect(seen[1].queryParameters, {'all': 'true', 'page': '2'});
      expect(seen[1].host, seen[0].host);
    });
  });

  group('token refresh', () {
    test('a POST refreshes on 401 and retries with the new token', () async {
      final auths = <String?>[];
      final bodies = <String>[];
      var refreshCalls = 0;
      final tokens = FakeTokens();
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/auth/refresh/')) {
          refreshCalls++;
          return json({'access': 'access-2', 'refresh': 'refresh-2'});
        }
        expect(req.url.path, endsWith('/instructor/scan/'));
        expect(req.method, 'POST');
        auths.add(req.headers['Authorization']);
        bodies.add(req.body);
        if (auths.length == 1) return json({'detail': 'expired'}, 401);
        return json({'detail': 'Recorded.'}, 201);
      });
      final api = ApiService(tokens: tokens, client: client);

      final result = await api.scan('TOKEN-1');

      expect(result.ok, isTrue);
      expect(refreshCalls, 1);
      expect(auths, ['Bearer access-1', 'Bearer access-2']);
      // The retry carries the same body.
      expect(bodies.map(jsonDecode), [
        {'token': 'TOKEN-1'},
        {'token': 'TOKEN-1'},
      ]);
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

      await expectLater(api.fetchMe(), throwsA(isA<SessionExpired>()));
      expect(expired, isTrue);
      expect(await tokens.hasTokens, isFalse);
    });

    test('GET requests refresh and retry too', () async {
      var calls = 0;
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/auth/refresh/')) {
          return json({'access': 'access-2'});
        }
        calls++;
        return calls == 1 ? json({'detail': 'x'}, 401) : json(meJson);
      });
      final api = ApiService(tokens: FakeTokens(), client: client);
      expect((await api.fetchMe()).username, 'ina');
      expect(calls, 2);
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
