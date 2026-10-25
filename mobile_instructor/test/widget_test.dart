import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ite_instructors/main.dart';
import 'package:ite_instructors/screens/instructor/instructor_home.dart';
import 'package:ite_instructors/screens/login_screen.dart';
import 'package:ite_instructors/services/api_service.dart';
import 'package:ite_instructors/services/auth_provider.dart';
import 'package:ite_instructors/theme/app_theme.dart';
import 'package:provider/provider.dart';

import 'test_helpers.dart';

http.Response json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

/// Signs in a [role] account (student or admin) against a fake backend.
Future<AuthProvider> signedInAs(String role) async {
  final auth = AuthProvider(
    apiService: ApiService(
      tokens: FakeTokens(access: null, refresh: null),
      client: MockClient((req) async {
        if (req.url.path.endsWith('/auth/login/')) {
          return json({'access': 'a', 'refresh': 'r'});
        }
        if (req.url.path.endsWith('/me/')) {
          return json({
            'id': 4,
            'username': 'user',
            'full_name': 'Some One',
            'is_admin': role == 'admin',
            'is_instructor': false,
            'is_student': role == 'student',
            'role': role,
          });
        }
        return json({'detail': 'not found'}, 404);
      }),
    ),
  );
  expect(await auth.login('user', 'pw'), isTrue);
  return auth;
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

  testWidgets('stays light + green even when the phone is in dark mode',
      (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
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
          themeMode: AppTheme.themeMode, // same wiring as main.dart (no darkTheme)
          home: const LoginScreen(),
        ),
      ),
    );
    final theme = Theme.of(tester.element(find.byType(LoginScreen)));
    expect(AppTheme.themeMode, ThemeMode.light);
    expect(theme.brightness, Brightness.light);
    expect(theme.scaffoldBackgroundColor, AppTheme.light.scaffoldBackgroundColor);
    expect(theme.colorScheme.primary, AppTheme.green);
    expect(find.text('Sign in'), findsOneWidget);
  });

  for (final role in ['student', 'admin']) {
    testWidgets('a $role is told this app is for instructors', (tester) async {
      final auth = await signedInAs(role);
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: auth,
          child: MaterialApp(theme: AppTheme.light, home: const RootRouter()),
        ),
      );
      expect(find.text('This app is for instructors'), findsOneWidget);
      expect(find.textContaining('Students use the ITE Students app'),
          findsOneWidget);
      expect(find.byType(InstructorHome), findsNothing);
      expect(find.byTooltip('Log out'), findsOneWidget);
    });
  }
}
