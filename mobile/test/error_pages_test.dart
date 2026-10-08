import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ite_attendance/services/api_service.dart';
import 'package:ite_attendance/utils/errors.dart';

import 'test_helpers.dart';

/// Django / proxies answer errors with HTML pages. Those must become a precise
/// [ApiException] (and a sensible message), never a JSON-decoding crash that the UI
/// would present as "Could not reach the server".
void main() {
  ApiService apiWith(http.Response Function(http.Request) respond) => ApiService(
        tokens: FakeTokens(access: 'a', refresh: 'r'),
        client: MockClient((req) async => respond(req)),
      );

  const notFoundPage =
      '<!doctype html><html><head><title>Not Found</title></head><body><h1>Not Found</h1></body></html>';

  test('an HTML 404 (endpoint missing on the server) is an ApiException with a clear message',
      () async {
    final api = apiWith((_) => http.Response(notFoundPage, 404,
        headers: {'content-type': 'text/html; charset=utf-8'}));
    try {
      await api.getJson('/instructor/events/3/attendance/');
      fail('should have thrown');
    } catch (e) {
      expect(e, isA<ApiException>());
      expect((e as ApiException).statusCode, 404);
      expect(friendlyError(e), "This feature isn't available on the server yet.");
      expect(friendlyError(e), isNot(contains('Could not reach')));
    }
  });

  test('an HTML 502/500 page says the server had a problem (not "no connection")', () async {
    for (final code in [500, 502, 503]) {
      final api = apiWith((_) => http.Response('<html>Bad gateway</html>', code));
      try {
        await api.getJson('/me/');
        fail('should have thrown');
      } catch (e) {
        expect(e, isA<ApiException>());
        expect(friendlyError(e), contains('server had a problem'));
      }
    }
  });

  test('a JSON error body keeps its own detail message', () async {
    final api = apiWith((_) =>
        http.Response('{"detail": "Not found."}', 404, headers: {'content-type': 'application/json'}));
    try {
      await api.getJson('/x/');
      fail('should have thrown');
    } catch (e) {
      expect(friendlyError(e), 'Not found.');
    }
  });

  test('a real network failure still reads as "could not reach the server"', () async {
    final api = ApiService(
      tokens: FakeTokens(access: 'a', refresh: 'r'),
      client: MockClient((_) async => throw http.ClientException('socket closed')),
    );
    try {
      await api.getJson('/me/');
      fail('should have thrown');
    } catch (e) {
      expect(friendlyError(e), contains('Could not reach the server'));
    }
  });
}
