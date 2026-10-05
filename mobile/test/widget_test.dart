import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ite_attendance/screens/login_screen.dart';
import 'package:ite_attendance/screens/student/generate_qr_tab.dart';
import 'package:ite_attendance/screens/student/qr_display_screen.dart';
import 'package:ite_attendance/services/api_service.dart';
import 'package:ite_attendance/services/auth_provider.dart';
import 'package:ite_attendance/theme/app_theme.dart';
import 'package:ite_attendance/utils/manila_time.dart';
import 'package:ite_attendance/widgets/qr_code_view.dart';
import 'package:provider/provider.dart';

import 'test_helpers.dart';

http.Response json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

const secretToken = 'SECRET-TOKEN-VALUE-123';

Map<String, dynamic> qrJson(int event, String date) => {
      'id': 9,
      'token': secretToken,
      'event': event,
      'date': date,
      'image_url': null,
    };

/// Builds the QR tab against a fake backend.
///  * [start]/[end]: the event's date range (relative to Manila "today").
///  * [existingQr]: whether today's QR already exists on the server.
Future<({ApiService api, List<String> calls})> pumpQrTab(
  WidgetTester tester, {
  required int startOffset,
  required int endOffset,
  required bool existingQr,
}) async {
  tester.view.physicalSize = const Size(800, 2000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final today = manilaToday();
  String day(int offset) =>
      ymd(DateTime(today.year, today.month, today.day + offset));
  final todayStr = ymd(today);
  final calls = <String>[];
  var created = existingQr;

  final client = MockClient((req) async {
    calls.add('${req.method} ${req.url.path}');
    final path = req.url.path;
    if (path.endsWith('/student/events/')) {
      return json({
        'count': 1,
        'next': null,
        'results': [eventJson(5, 'Foundation Day', day(startOffset), day(endOffset))],
      });
    }
    if (path.endsWith('/student/qr/generate/')) {
      created = true;
      return json(qrJson(5, todayStr), 201);
    }
    if (path.endsWith('/student/qr/')) {
      expect(req.url.queryParameters['event'], '5');
      expect(req.url.queryParameters['date'], todayStr);
      return json({
        'count': created ? 1 : 0,
        'next': null,
        'results': created ? [qrJson(5, todayStr)] : [],
      });
    }
    return json({'detail': 'not found'}, 404);
  });
  final api = ApiService(tokens: FakeTokens(), client: client);

  await tester.pumpWidget(
    Provider<ApiService>.value(
      value: api,
      child: MaterialApp(
        theme: AppTheme.light,
        home: const Scaffold(body: GenerateQrTab()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (api: api, calls: calls);
}

void main() {
  testWidgets('login screen renders with the brand theme', (tester) async {
    final auth = AuthProvider(
      apiService: ApiService(
        tokens: FakeTokens(access: null, refresh: null),
        client: MockClient((_) async => json({}, 404)),
      ),
    );
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: auth,
        child: MaterialApp(theme: AppTheme.light, home: const LoginScreen()),
      ),
    );
    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text('Username'), findsOneWidget);
    final scheme = Theme.of(tester.element(find.byType(LoginScreen))).colorScheme;
    expect(scheme.primary, AppTheme.green);
    expect(scheme.onPrimary, AppTheme.onGreen);
  });

  testWidgets('dark theme builds and keeps the green primary', (tester) async {
    final auth = AuthProvider(
      apiService: ApiService(
        tokens: FakeTokens(access: null, refresh: null),
        client: MockClient((_) async => json({}, 404)),
      ),
    );
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: auth,
        child: MaterialApp(
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: ThemeMode.dark,
          home: const LoginScreen(),
        ),
      ),
    );
    final theme = Theme.of(tester.element(find.byType(LoginScreen)));
    expect(theme.brightness, Brightness.dark);
    expect(theme.colorScheme.primary, AppTheme.green);
    expect(find.text('Sign in'), findsOneWidget);
  });

  group('Generate QR tab', () {
    testWidgets('no QR yet: shows Generate; generating switches to the QR view',
        (tester) async {
      final r = await pumpQrTab(tester,
          startOffset: -1, endOffset: 1, existingQr: false);

      expect(find.text('Generate QR'), findsOneWidget);
      expect(find.byType(QrCodeView), findsNothing);
      expect(r.calls, contains('GET /api/student/qr/'));

      await tester.tap(find.text('Generate QR'));
      await tester.pumpAndSettle();

      // Generate button is gone; the QR is shown inline, token never as text.
      expect(find.text('Generate QR'), findsNothing);
      expect(find.byType(QrCodeView), findsOneWidget);
      expect(find.text('Show full screen'), findsOneWidget);
      expect(find.textContaining(secretToken), findsNothing);
      expect(r.calls.where((c) => c == 'POST /api/student/qr/generate/').length, 1);
    });

    testWidgets("today's QR already exists: Generate is hidden, QR shown inline",
        (tester) async {
      final r = await pumpQrTab(tester,
          startOffset: 0, endOffset: 2, existingQr: true);

      expect(find.text('Generate QR'), findsNothing);
      expect(find.byType(QrCodeView), findsOneWidget);
      expect(find.textContaining(secretToken), findsNothing);
      expect(r.calls.where((c) => c.startsWith('POST')), isEmpty);

      // "Show full screen" opens the white full-screen view with a close button.
      await tester.tap(find.text('Show full screen'));
      await tester.pumpAndSettle();
      expect(find.byType(QrDisplayScreen), findsOneWidget);
      expect(find.text('Foundation Day'), findsWidgets);
      expect(find.textContaining(secretToken), findsNothing);
      expect(
          tester.widget<Scaffold>(find.byType(Scaffold).last).backgroundColor,
          Colors.white);

      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(QrDisplayScreen), findsNothing);
    });

    testWidgets('multi-day event: past/upcoming days are muted with hints',
        (tester) async {
      await pumpQrTab(tester, startOffset: -1, endOffset: 1, existingQr: false);

      await tester.tap(find.byType(DropdownButtonFormField<DateTime>));
      await tester.pumpAndSettle();
      expect(find.text('Past'), findsOneWidget);
      expect(find.text('Upcoming'), findsOneWidget);
      expect(find.text('Today'), findsWidgets);
    });

    testWidgets("event not running today: explains and disables Generate",
        (tester) async {
      final r = await pumpQrTab(tester,
          startOffset: 2, endOffset: 4, existingQr: false);

      expect(find.textContaining("This event isn't running today"), findsOneWidget);
      final button = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(button.onPressed, isNull);
      expect(find.byType(QrCodeView), findsNothing);
      // Nothing to look up when no day is selectable.
      expect(r.calls.where((c) => c.contains('/student/qr/')), isEmpty);
    });

    testWidgets('server 400 on generate shows a friendly error with retry',
        (tester) async {
      final today = manilaToday();
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final client = MockClient((req) async {
        final path = req.url.path;
        if (path.endsWith('/student/events/')) {
          return json({
            'results': [
              eventJson(5, 'Foundation Day', ymd(today), ymd(today)),
            ],
          });
        }
        if (path.endsWith('/student/qr/generate/')) {
          return json({
            'date': ['You can only generate a QR for today (${ymd(today)}).']
          }, 400);
        }
        return json({'results': []});
      });
      await tester.pumpWidget(
        Provider<ApiService>.value(
          value: ApiService(tokens: FakeTokens(), client: client),
          child: MaterialApp(
            theme: AppTheme.light,
            home: const Scaffold(body: GenerateQrTab()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Generate QR'));
      await tester.pumpAndSettle();

      expect(find.textContaining('You can only generate a QR for today'),
          findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });
  });
}
