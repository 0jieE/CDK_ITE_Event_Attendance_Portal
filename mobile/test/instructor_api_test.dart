import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ite_attendance/models/event_attendance.dart';
import 'package:ite_attendance/services/api_service.dart';

import 'instructor_fixtures.dart';
import 'test_helpers.dart';

http.Response json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  group('instructorEventsAll', () {
    test('sends all=true, follows `next` and sends the bearer token', () async {
      final seen = <http.Request>[];
      final client = MockClient((req) async {
        seen.add(req);
        if (req.url.queryParameters['page'] == '2') {
          return json({
            'count': 2,
            'next': null,
            'results': [eventJson(2, 'Old', '2026-01-01', '2026-01-02')],
          });
        }
        return json({
          'count': 2,
          'next': 'http://internal:8000/api/instructor/events/?all=true&page=2',
          'results': [eventJson(1, 'New', '2026-10-01', '2026-10-02')],
        });
      });
      final api = ApiService(tokens: FakeTokens(), client: client);
      final events = await api.instructorEventsAll();
      expect(events.map((e) => e.id), [1, 2]);
      expect(seen.length, 2);
      expect(seen[0].url.path, endsWith('/instructor/events/'));
      expect(seen[0].url.queryParameters, {'all': 'true'});
      expect(seen[1].url.queryParameters, {'all': 'true', 'page': '2'});
      expect(seen[0].headers['Authorization'], 'Bearer access-1');
    });

    test(
      'the scanner list stays on the plain endpoint (no all=true)',
      () async {
        Uri? url;
        final client = MockClient((req) async {
          url = req.url;
          return json({'results': []});
        });
        await ApiService(
          tokens: FakeTokens(),
          client: client,
        ).instructorEvents();
        expect(url!.queryParameters, isEmpty);
      },
    );

    test('403 for a non-instructor maps to ApiException', () async {
      final client = MockClient(
        (_) async => json({
          'detail': 'You do not have permission to perform this action.',
        }, 403),
      );
      final api = ApiService(tokens: FakeTokens(), client: client);
      await expectLater(
        api.instructorEventsAll(),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 403)),
      );
    });
  });

  group('instructorEventAttendance', () {
    test('omits ?date= when no date is given', () async {
      Uri? url;
      final client = MockClient((req) async {
        url = req.url;
        return json(sampleAttendanceJson());
      });
      final api = ApiService(tokens: FakeTokens(), client: client);
      final data = await api.instructorEventAttendance(3);
      expect(url!.path, endsWith('/instructor/events/3/attendance/'));
      expect(url!.queryParameters, isEmpty);
      expect(data, isA<EventAttendance>());
      expect(data.students.length, 3);
    });

    test('sends the date as YYYY-MM-DD', () async {
      Uri? url;
      final client = MockClient((req) async {
        url = req.url;
        return json(sampleAttendanceJson(date: '2026-10-06', isToday: false));
      });
      final api = ApiService(tokens: FakeTokens(), client: client);
      final data = await api.instructorEventAttendance(
        3,
        date: DateTime(2026, 10, 6),
      );
      expect(url!.queryParameters, {'date': '2026-10-06'});
      expect(data.date, DateTime(2026, 10, 6));
      expect(data.isToday, isFalse);
    });

    test('400 carries the field error message and data', () async {
      final client = MockClient(
        (_) async => json({
          'date': ['Date is outside the event.'],
        }, 400),
      );
      final api = ApiService(tokens: FakeTokens(), client: client);
      await expectLater(
        api.instructorEventAttendance(3, date: DateTime(2027, 1, 1)),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'status', 400)
              .having((e) => e.message, 'message', 'Date is outside the event.')
              .having((e) => (e.data as Map)['date'], 'data', isA<List>()),
        ),
      );
    });

    test('404 for an unknown event', () async {
      final client = MockClient(
        (_) async => json({'detail': 'Not found.'}, 404),
      );
      final api = ApiService(tokens: FakeTokens(), client: client);
      await expectLater(
        api.instructorEventAttendance(999),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'status', 404)
              .having((e) => e.message, 'message', 'Not found.'),
        ),
      );
    });

    test('403 for a student account', () async {
      final client = MockClient(
        (_) async => json({
          'detail': 'You do not have permission to perform this action.',
        }, 403),
      );
      final api = ApiService(tokens: FakeTokens(), client: client);
      await expectLater(
        api.instructorEventAttendance(3),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 403)),
      );
    });

    test('refreshes the token once on 401 and retries', () async {
      var calls = 0;
      final tokens = FakeTokens();
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/auth/refresh/')) {
          return json({'access': 'access-2', 'refresh': 'refresh-2'});
        }
        calls++;
        if (req.headers['Authorization'] == 'Bearer access-1') {
          return json({'detail': 'expired'}, 401);
        }
        return json(sampleAttendanceJson());
      });
      final api = ApiService(tokens: tokens, client: client);
      final data = await api.instructorEventAttendance(3);
      expect(calls, 2);
      expect(data.event.id, 3);
      expect(await tokens.access, 'access-2');
    });
  });
}
