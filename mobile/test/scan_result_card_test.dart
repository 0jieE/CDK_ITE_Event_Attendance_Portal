import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ite_attendance/models/qr_slot.dart';
import 'package:ite_attendance/screens/instructor/scanner_screen.dart';
import 'package:ite_attendance/theme/app_theme.dart';

Future<Color?> cardColor(WidgetTester tester, ScanResult result) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        body: ScanResultCard(result: result, onDismiss: () {}),
      ),
    ),
  );
  return tester.widget<Card>(find.byType(Card)).color;
}

ScanResult ok({required bool created}) => ScanResult(
      ok: true,
      created: created,
      detail: 'x',
      studentName: 'Maria Santos',
      studentNumber: 'DEMO-001',
      eventName: 'Tech Week',
      attendanceTypeDisplay: 'AM Time-In',
    );

void main() {
  testWidgets('"Already recorded" keeps the amber warning look', (tester) async {
    final color = await cardColor(tester, ok(created: false));
    expect(find.text('Already recorded'), findsOneWidget);
    expect(color, AppTheme.warning);
    expect(color, const Color(0xFF9A5B00));
    expect(find.byIcon(Icons.info), findsOneWidget);
    expect(find.textContaining('Late'), findsNothing);
  });

  testWidgets('"Recorded" is green and failures are red', (tester) async {
    expect(await cardColor(tester, ok(created: true)),
        AppTheme.statusColor('PRESENT'));
    expect(find.text('Recorded'), findsOneWidget);

    expect(
      await cardColor(tester, ScanResult.failure('nope', 'STALE_QR')),
      AppTheme.statusColor('ABSENT'),
    );
  });

  test('statusColor/badge no longer know a LATE status', () {
    expect(AppTheme.statusColor('LATE'), AppTheme.muted);
    expect(
      AppTheme.light.extension<BrandColors>()!.badge('LATE').bg,
      AppTheme.light.extension<BrandColors>()!.neutralBg,
    );
  });
}
