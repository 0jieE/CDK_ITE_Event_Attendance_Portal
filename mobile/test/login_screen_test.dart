import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ite_attendance/screens/login_screen.dart';
import 'package:ite_attendance/screens/signup_screen.dart';
import 'package:ite_attendance/services/api_service.dart';
import 'package:ite_attendance/services/auth_provider.dart';
import 'package:ite_attendance/theme/app_theme.dart';
import 'package:ite_attendance/widgets/state_message.dart';
import 'package:provider/provider.dart';

import 'test_helpers.dart';

http.Response json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

const pendingText = 'Your account is waiting for approval by the Department '
    "Adviser. You'll be able to sign in once it is approved.";

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
  testWidgets('shows a "Create an account" entry under Sign in',
      (tester) async {
    await pumpLogin(tester, (_) async => json({}, 404));
    expect(find.text('New student? Create an account'), findsOneWidget);
  });

  testWidgets('403 PENDING_APPROVAL: calm info banner, not an error',
      (tester) async {
    final r = await pumpLogin(
      tester,
      (_) async => json({
        'detail': 'Server wording that the app does not need.',
        'code': 'PENDING_APPROVAL',
      }, 403),
    );
    await signIn(tester);

    expect(find.text(pendingText), findsOneWidget);
    expect(banner(tester).isError, isFalse);
    expect(r.auth.status, isNot(AuthStatus.authenticated));
    // Not a session problem: only the login call, no refresh attempt.
    expect(r.calls, ['POST /api/auth/login/']);
    expect(find.text('Invalid username or password.'), findsNothing);
  });

  testWidgets('403 REGISTRATION_REJECTED: the server message in an error banner',
      (tester) async {
    const msg = 'Your registration was declined: not an ITE student.';
    final r = await pumpLogin(
      tester,
      (_) async =>
          json({'detail': msg, 'code': 'REGISTRATION_REJECTED'}, 403),
    );
    await signIn(tester);

    expect(find.text(msg), findsOneWidget);
    expect(banner(tester).isError, isTrue);
    expect(banner(tester).icon, Icons.block);
    expect(find.text(pendingText), findsNothing);
    expect(r.calls, ['POST /api/auth/login/']);
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

  testWidgets('a later failure replaces the pending banner', (tester) async {
    var pending = true;
    await pumpLogin(
      tester,
      (_) async => pending
          ? json({'detail': 'x', 'code': 'PENDING_APPROVAL'}, 403)
          : json({'detail': 'bad'}, 401),
    );
    await signIn(tester);
    expect(find.text(pendingText), findsOneWidget);

    pending = false;
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();
    expect(find.text(pendingText), findsNothing);
    expect(find.text('Invalid username or password.'), findsOneWidget);
  });

  testWidgets('Create an account opens sign-up; registering pre-fills the '
      'username on return', (tester) async {
    await pumpLogin(tester, (req) async {
      if (req.url.path.endsWith('/auth/register/')) {
        return json({'status': 'PENDING', 'detail': 'Registration received.'},
            201);
      }
      return json({'detail': 'x', 'code': 'PENDING_APPROVAL'}, 403);
    });
    // Leave a stale banner behind: opening sign-up clears it.
    await signIn(tester);
    expect(find.text(pendingText), findsOneWidget);

    await tester.tap(find.text('New student? Create an account'));
    await tester.pumpAndSettle();
    expect(find.byType(SignUpScreen), findsOneWidget);

    Finder f(String l) => find.widgetWithText(TextFormField, l);
    await tester.enterText(f('Student number'), '2024-0100');
    await tester.enterText(f('First name'), 'Ana');
    await tester.enterText(f('Last name'), 'Reyes');
    await tester.enterText(f('Username'), 'ana.reyes');
    await tester.enterText(f('Password'), 'S3cure-pass!');
    await tester.enterText(f('Confirm password'), 'S3cure-pass!');
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1st Year').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Create account'));
    await tester.pumpAndSettle();
    expect(find.text('Registration submitted'), findsOneWidget);

    await tester.tap(find.text('Back to sign in'));
    await tester.pumpAndSettle();

    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.text(pendingText), findsNothing); // stale banner cleared
    expect(
        tester
            .widget<TextFormField>(find.widgetWithText(TextFormField, 'Username'))
            .controller!
            .text,
        'ana.reyes');
  });
}
