import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ite_attendance/widgets/scan_frame.dart';

void main() {
  group('barcodeRectOnScreen', () {
    const corners = [Offset(400, 600), Offset(600, 600), Offset(600, 800), Offset(400, 800)];

    test('same aspect ratio: a plain scale', () {
      // 1000x2000 camera image shown on a 500x1000 preview -> half size.
      final r = barcodeRectOnScreen(
        corners: corners,
        imageSize: const Size(1000, 2000),
        previewSize: const Size(500, 1000),
      );
      expect(r, const Rect.fromLTRB(200, 300, 300, 400));
    });

    test('cover crops the overflowing side and centres it', () {
      // 1000x1000 image on a 500x1000 preview: scaled x1 by height, 250px
      // cropped from each side horizontally.
      final r = barcodeRectOnScreen(
        corners: corners,
        imageSize: const Size(1000, 1000),
        previewSize: const Size(500, 1000),
      )!;
      expect(r.left, 150);
      expect(r.right, 350);
      expect(r.top, 600);
      expect(r.bottom, 800);
    });

    test('a tilted code gets its bounding box', () {
      final r = barcodeRectOnScreen(
        corners: const [Offset(50, 0), Offset(100, 50), Offset(50, 100), Offset(0, 50)],
        imageSize: const Size(100, 100),
        previewSize: const Size(100, 100),
      );
      expect(r, const Rect.fromLTRB(0, 0, 100, 100));
    });

    test('nothing to place', () {
      expect(
          barcodeRectOnScreen(
              corners: const [], imageSize: const Size(1, 1), previewSize: const Size(1, 1)),
          isNull);
      expect(
          barcodeRectOnScreen(
              corners: corners, imageSize: Size.zero, previewSize: const Size(1, 1)),
          isNull);
    });
  });

  testWidgets('the frame searches, then glides to a detected code', (tester) async {
    Future<void> show(Rect? target) => tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 800,
              child: ScanFrame(target: target),
            ),
          ),
        ));

    await show(null);
    await tester.pump(const Duration(milliseconds: 500)); // sweeping, no errors
    await show(const Rect.fromLTWH(50, 500, 120, 120));
    await tester.pump(const Duration(milliseconds: 300)); // glide finished
    expect(find.byType(ScanFrame), findsOneWidget);
    await show(null);
    await tester.pump(const Duration(milliseconds: 300));
  });
}
