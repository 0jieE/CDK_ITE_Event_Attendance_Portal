import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// Black-on-white QR drawn from a token, with a white quiet-zone around it so it
/// scans reliably in both light and dark themes. The token itself is never
/// shown as text.
class QrCodeView extends StatelessWidget {
  final String data;
  final double size;
  final double padding;

  const QrCodeView({
    super.key,
    required this.data,
    required this.size,
    this.padding = 12,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Attendance QR code',
      image: true,
      child: Container(
        padding: EdgeInsets.all(padding),
        color: Colors.white,
        child: QrImageView(
          data: data,
          version: QrVersions.auto,
          size: size,
          backgroundColor: Colors.white,
          eyeStyle: const QrEyeStyle(
            eyeShape: QrEyeShape.square,
            color: Colors.black,
          ),
          dataModuleStyle: const QrDataModuleStyle(
            dataModuleShape: QrDataModuleShape.square,
            color: Colors.black,
          ),
        ),
      ),
    );
  }
}
