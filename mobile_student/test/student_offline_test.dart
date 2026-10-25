import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ite_students/screens/student/generate_qr_tab.dart';
import 'package:ite_students/services/api_service.dart';
import 'package:ite_students/theme/app_theme.dart';
import 'package:ite_students/utils/manila_time.dart';
import 'package:ite_students/widgets/qr_code_view.dart';
import 'package:provider/provider.dart';

import 'test_helpers.dart';

http.Response json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

void main() {
  /// A student backend for one event running today; [offline] cuts it off.
  late bool offline;
  late bool generated;
  late ApiService api;

  setUp(() {
    offline = false;
    generated = false;
    final today = ymd(manilaToday());
    final qr = {'id': 9, 'token': 'TOKEN-1', 'event': 5, 'date': today, 'image_url': null};
    api = ApiService(
      tokens: FakeTokens(),
      client: MockClient((req) async {
        if (offline) throw http.ClientException('Network is unreachable');
        final path = req.url.path;
        if (path.endsWith('/student/events/')) {
          return json({
            'next': null,
            'results': [eventJson(5, 'Foundation Day', today, today)],
          });
        }
        if (path.endsWith('/student/qr/generate/')) {
          generated = true;
          return json(qr, 201);
        }
        if (path.endsWith('/student/qr/')) {
          return json({'results': generated ? [qr] : []});
        }
        return json({'detail': 'not found'}, 404);
      }),
    );
  });

  /// A fresh QR tab (as after an app restart: nothing kept in memory).
  Future<void> openTab(WidgetTester tester, String key) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(Provider<ApiService>.value(
      value: api,
      child: MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(body: GenerateQrTab(key: ValueKey(key))),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('a QR generated earlier today still shows offline', (tester) async {
    await openTab(tester, 'online');
    await tester.tap(find.text('Generate QR'));
    await tester.pumpAndSettle();
    expect(find.byType(QrCodeView), findsOneWidget);

    offline = true;
    await openTab(tester, 'offline');
    expect(find.text('Foundation Day'), findsWidgets); // events from the phone
    expect(find.byType(QrCodeView), findsOneWidget);
    expect(find.textContaining('copy saved on this phone'), findsOneWidget);
  });

  testWidgets('offline without a QR: generating is disabled', (tester) async {
    await openTab(tester, 'online'); // caches the events, no QR yet
    offline = true;
    await openTab(tester, 'offline');

    expect(find.byType(QrCodeView), findsNothing);
    expect(find.textContaining("You're offline"), findsOneWidget);
    final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Generate QR'));
    expect(button.onPressed, isNull);

    // Back online: "Try again" finds the server and generating works again.
    offline = false;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Generate QR'));
    await tester.pumpAndSettle();
    expect(find.byType(QrCodeView), findsOneWidget);
  });

  testWidgets('offline with nothing saved: a clear message', (tester) async {
    offline = true;
    await openTab(tester, 'offline');
    expect(find.textContaining('no events are saved on this phone'), findsOneWidget);
  });
}
