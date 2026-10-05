import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ite_attendance/utils/image_type.dart';

void main() {
  test('detects JPEG / PNG / WebP by magic bytes', () {
    expect(detectImageType(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0])),
        ImageType.jpeg);
    expect(
        detectImageType(Uint8List.fromList(
            [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0])),
        ImageType.png);
    expect(
        detectImageType(Uint8List.fromList(
            [...'RIFF'.codeUnits, 1, 2, 3, 4, ...'WEBP'.codeUnits])),
        ImageType.webp);
  });

  test('rejects other formats and short input', () {
    expect(detectImageType(Uint8List.fromList('GIF89a....'.codeUnits)), isNull);
    expect(detectImageType(Uint8List(0)), isNull);
    expect(detectImageType(Uint8List.fromList([0xFF, 0xD8])), isNull);
  });
}
