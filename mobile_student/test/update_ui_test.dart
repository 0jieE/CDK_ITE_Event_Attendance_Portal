import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ite_students/theme/app_theme.dart';
import 'package:ite_students/update/github_releases.dart';
import 'package:ite_students/update/update_service.dart';
import 'package:ite_students/update/update_ui.dart';
import 'package:provider/provider.dart';

import 'update_test.dart' show FakeInstaller, release;

void main() {
  late bool offline;
  late String latestTag;
  late UpdateService service;

  setUp(() {
    offline = false;
    latestTag = 'students-v1.0.2';
    service = UpdateService(
      installer: const FakeInstaller('1.0.1'),
      releases: GitHubReleaseClient(
        client: MockClient((_) async {
          if (offline) throw const SocketException('offline');
          return http.Response(jsonEncode([release(latestTag)]), 200);
        }),
      ),
    );
  });

  /// The signed-in home (with its prompter) showing [child], like Profile.
  Future<void> pumpHome(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: service,
      child: MaterialApp(
        theme: AppTheme.light,
        home: UpdatePrompter(child: Scaffold(body: Center(child: child))),
      ),
    ));
    await tester.pump();
  }

  Future<void> tapCheck(WidgetTester tester) async {
    await tester.tap(find.text('Check for updates'));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'Profile → Check for updates finding an update opens one dialog, not two '
      '(the automatic check had failed offline)', (tester) async {
    offline = true;
    await tester.runAsync(() => service.check());
    expect(service.status, UpdateStatus.failed);
    offline = false;

    await pumpHome(tester, const CheckForUpdatesTile());
    await tapCheck(tester);

    expect(find.byType(AlertDialog), findsOneWidget);
    final dialog = find.byType(AlertDialog);
    expect(find.descendant(of: dialog, matching: find.text('Update available')),
        findsOneWidget);
    expect(find.descendant(of: dialog, matching: find.text('1.0.2')),
        findsOneWidget);
    await tester.tap(find.text('Later'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(service.shouldPrompt, isFalse); // not offered again this session
  });

  testWidgets('Check for updates when up to date: a message, no dialog',
      (tester) async {
    latestTag = 'students-v1.0.1';
    await pumpHome(tester, const CheckForUpdatesTile());
    await tapCheck(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('You have the latest version.'), findsOneWidget);
  });

  testWidgets('the update dialog shows versions, size and notes',
      (tester) async {
    await tester.runAsync(() => service.loadInstalled());
    await pumpHome(tester, const SizedBox());
    await tester.runAsync(() => service.check());
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('Update available'), findsOneWidget);
    expect(find.text('1.0.1'), findsOneWidget); // installed
    expect(find.text('1.0.2'), findsOneWidget); // latest
    expect(find.text('1 KB'), findsOneWidget); // 1234 bytes
    expect(find.text('Bug fixes'), findsOneWidget);
    expect(find.text('Update now'), findsOneWidget);
  });

  testWidgets('sign-in screen: a button, shown only when an update exists',
      (tester) async {
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: service,
      child: const MaterialApp(home: Scaffold(body: UpdateAvailableButton())),
    ));
    expect(find.byType(TextButton), findsNothing);

    await tester.runAsync(() => service.check());
    await tester.pump();
    expect(find.text('Update available: 1.0.2'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing); // never pops up by itself
  });
}
