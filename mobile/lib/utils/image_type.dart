import 'dart:typed_data';

/// A supported upload image type (the server accepts JPG, PNG and WebP).
class ImageType {
  final String mime;
  final String extension;
  const ImageType(this.mime, this.extension);

  static const jpeg = ImageType('image/jpeg', 'jpg');
  static const png = ImageType('image/png', 'png');
  static const webp = ImageType('image/webp', 'webp');
}

/// Sniffs the real format from the file's magic bytes (file names and
/// extensions from pickers can't be trusted). Null when unsupported.
ImageType? detectImageType(Uint8List b) {
  if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) {
    return ImageType.jpeg;
  }
  if (b.length >= 8 &&
      b[0] == 0x89 &&
      b[1] == 0x50 &&
      b[2] == 0x4E &&
      b[3] == 0x47 &&
      b[4] == 0x0D &&
      b[5] == 0x0A &&
      b[6] == 0x1A &&
      b[7] == 0x0A) {
    return ImageType.png;
  }
  if (b.length >= 12 &&
      String.fromCharCodes(b.sublist(0, 4)) == 'RIFF' &&
      String.fromCharCodes(b.sublist(8, 12)) == 'WEBP') {
    return ImageType.webp;
  }
  return null;
}
