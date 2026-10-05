import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ite_attendance/main.dart';

void main() {
  testWidgets('App boots into the splash/auth shell', (tester) async {
    await tester.pumpWidget(const IteAttendanceApp());
    // The root router renders without throwing on first frame.
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
