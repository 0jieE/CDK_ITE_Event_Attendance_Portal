import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ite_instructors/theme/app_theme.dart';
import 'package:ite_instructors/update/github_releases.dart';
import 'package:ite_instructors/update/update_service.dart';
import 'package:ite_instructors/update/update_ui.dart';
import 'package:provider/provider.dart';

import 'update_test.dart' show FakeInstaller, release;

void main() {
  late bool offline;
  late String latestTag;

  /// While set, GitHub's reply waits for it (a slow network).
  Completer<void>? gate;
  late UpdateService service;

  setUp(() {
    offline = false;
    latestTag = 'instructors-v1.0.2';
    gate = null;
    service = UpdateService(
      installer: const FakeInstaller('1.0.1'),
      releases: GitHubReleaseClient(
        client: MockClient((_) async {
          await gate?.future;
          if (offline) throw const SocketException('offline');
          return http.Response(jsonEncode([release(latestTag)]), 200);
        }),
      ),
    );
  });

  Future<void> pumpHome(WidgetTester tester, Widget action) async {
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: service,
      child: MaterialApp(
        theme: AppTheme.light,
        home: UpdatePrompter(child: Scaffold(body: Center(child: action))),
      ),
    ));
    await tester.pump();
  }

  testWidgets(
      'a manual check that finds an update opens one dialog, not two '
      '(the automatic check had failed offline)', (tester) async {
    offline = true;
    await tester.runAsync(() => service.check());
    expect(service.status, UpdateStatus.failed);
    offline = false;

    await pumpHome(tester, const CheckForUpdatesTile());
    await tester.tap(find.text('Check for updates'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('Later'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  Future<void> tapMenuCheck(WidgetTester tester) async {
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    expect(find.text('Version 1.0.1 (5)'), findsOneWidget);
    gate = Completer<void>();
    await tester.tap(find.text('Check for updates'));
    await tester.pumpAndSettle();
    expect(find.text('Checking for updates…'), findsOneWidget);
    gate!.complete();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
  }

  testWidgets('⋮ → Check for updates: offers the newer release', (tester) async {
    await pumpHome(tester, const UpdateMenuButton());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tapMenuCheck(tester);

    expect(find.text('Update available'), findsOneWidget);
    expect(find.text('1.0.2'), findsOneWidget);
    expect(find.text('Checking for updates…'), findsNothing);
  });

  testWidgets('⋮ → Check for updates: says when it is up to date', (tester) async {
    latestTag = 'instructors-v1.0.1';
    await pumpHome(tester, const UpdateMenuButton());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tapMenuCheck(tester);

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('You have the latest version.'), findsOneWidget);
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
