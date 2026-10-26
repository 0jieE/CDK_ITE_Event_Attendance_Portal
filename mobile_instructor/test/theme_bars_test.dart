import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ite_instructors/screens/instructor/event_attendance_screen.dart';
import 'package:ite_instructors/services/api_service.dart';
import 'package:ite_instructors/theme/app_theme.dart';
import 'package:provider/provider.dart';

import 'test_helpers.dart';

/// The color an [Icon] (found by its glyph) is actually drawn in.
Color? iconColor(WidgetTester tester, IconData icon) {
  final e = tester.element(find.byIcon(icon));
  return (e.widget as Icon).color ?? IconTheme.of(e).color;
}

void main() {
  testWidgets('green bars: white title, action icons (incl. the ⋮ menu) and tabs',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Instructor'),
          actions: [
            IconButton(onPressed: () {}, icon: const Icon(Icons.logout)),
            PopupMenuButton<void>(itemBuilder: (_) => const []),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: 0,
          destinations: const [
            NavigationDestination(icon: Icon(Icons.qr_code_scanner), label: 'Scan'),
            NavigationDestination(icon: Icon(Icons.fact_check), label: 'Attendance'),
          ],
        ),
      ),
    ));

    final bar = tester.widget<Material>(find
        .descendant(of: find.byType(AppBar), matching: find.byType(Material))
        .first);
    expect(bar.color, AppTheme.barBackground);
    expect(
        DefaultTextStyle.of(tester.element(find.text('Instructor'))).style.color,
        AppTheme.onBar);
    expect(iconColor(tester, Icons.logout), AppTheme.onBar);
    expect(iconColor(tester, Icons.more_vert), AppTheme.onBar);

    // Selected tab: green icon on the white pill; the other tab is white.
    expect(iconColor(tester, Icons.qr_code_scanner), AppTheme.greenText);
    expect(iconColor(tester, Icons.fact_check)!.toARGB32() & 0xFFFFFF,
        AppTheme.onBar.toARGB32() & 0xFFFFFF);
  });

  testWidgets("the roster's date subtitle stays readable on the green bar",
      (tester) async {
    final api = ApiService(
      tokens: FakeTokens(),
      client: MockClient((_) async => http.Response('{}', 404)),
    );
    await tester.pumpWidget(Provider<ApiService>.value(
      value: api,
      child: MaterialApp(
        theme: AppTheme.light,
        home: EventAttendanceScreen(event: ev(3, '2026-10-06', '2026-10-10')),
      ),
    ));
    final subtitle = find.descendant(
        of: find.byType(AppBar), matching: find.textContaining('Oct'));
    final color = tester.widget<Text>(subtitle).style!.color!;
    expect(color.toARGB32() & 0xFFFFFF, AppTheme.onBar.toARGB32() & 0xFFFFFF);
  });
}
