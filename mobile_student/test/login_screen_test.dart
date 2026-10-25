import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ite_students/screens/login_screen.dart';
import 'package:ite_students/services/api_service.dart';
import 'package:ite_students/services/auth_provider.dart';
import 'package:ite_students/theme/app_theme.dart';
import 'package:ite_students/widgets/state_message.dart';
import 'package:provider/provider.dart';

import 'test_helpers.dart';

http.Response json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

/// Pumps the login screen against [handler] and returns what was requested.
Future<({AuthProvider auth, List<String> calls, FakeTokens tokens})> pumpLogin(
  WidgetTester tester,
  MockClientHandler handler,
) async {
  tester.view.physicalSize = const Size(900, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final calls = <String>[];
  final tokens = FakeTokens(access: null, refresh: null);
  final api = ApiService(
    tokens: tokens,
    client: MockClient((req) async {
      calls.add('${req.method} ${req.url.path}');
      return handler(req);
    }),
  );
  final auth = AuthProvider(apiService: api);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: auth),
        Provider<ApiService>.value(value: api),
      ],
      child: MaterialApp(theme: AppTheme.light, home: const LoginScreen()),
    ),
  );
  return (auth: auth, calls: calls, tokens: tokens);
}

Future<void> signIn(WidgetTester tester) async {
  await tester.enterText(find.widgetWithText(TextFormField, 'Username'), 'ana');
  await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'pw');
  await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
  await tester.pumpAndSettle();
}

InlineBanner banner(WidgetTester tester) =>
    tester.widget<InlineBanner>(find.byType(InlineBanner));

void main() {
  testWidgets('has no "Create an account" button; shows the adviser hint',
      (tester) async {
    await pumpLogin(tester, (_) async => json({}, 404));
    expect(find.textContaining('Create an account'), findsNothing);
    expect(find.byType(TextButton), findsNothing);
    expect(
      find.text('No account yet? Your Department Adviser gives you your '
          'username and password.'),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.info_outline), findsOneWidget);
  });

  testWidgets('401 keeps "Invalid username or password."', (tester) async {
    final r = await pumpLogin(
      tester,
      (_) async => json(
          {'detail': 'No active account found with the given credentials'},
          401),
    );
    await signIn(tester);

    expect(find.text('Invalid username or password.'), findsOneWidget);
    expect(banner(tester).isError, isTrue);
    expect(r.calls, ['POST /api/auth/login/']);
  });
}
