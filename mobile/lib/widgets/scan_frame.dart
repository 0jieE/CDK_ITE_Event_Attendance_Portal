import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart' show ScanWindowUtils;

/// Where a detected QR sits on screen: the bounding box of its [corners]
/// (camera-image coordinates, image of [imageSize]) mapped onto a preview of
/// [previewSize] shown with [BoxFit.cover] - the scanner's default fit.
/// Null when there isn't enough to place it.
Rect? barcodeRectOnScreen({
  required List<Offset> corners,
  required Size imageSize,
  required Size previewSize,
  bool landscape = false,
}) {
  if (corners.length < 4 || imageSize.isEmpty || previewSize.isEmpty) {
    return null;
  }
  final image = landscape ? imageSize.flipped : imageSize;
  final r = ScanWindowUtils.calculateBoxFitRatio(
    boxFit: BoxFit.cover,
    cameraPreviewSize: image,
    size: previewSize,
  );
  final padX = (image.width * r.widthRatio - previewSize.width) / 2;
  final padY = (image.height * r.heightRatio - previewSize.height) / 2;
  final xs = [for (final c in corners) c.dx * r.widthRatio - padX];
  final ys = [for (final c in corners) c.dy * r.heightRatio - padY];
  return Rect.fromLTRB(
    xs.reduce(math.min),
    ys.reduce(math.min),
    xs.reduce(math.max),
    ys.reduce(math.max),
  );
}

/// The scanner's viewfinder: corner brackets over a dimmed camera view.
///
/// With no [target] it waits in the middle with a sweeping scan line; given
/// a [target] (the QR's place on screen) it glides there and hugs the code,
/// like a phone's built-in QR scanner.
class ScanFrame extends StatefulWidget {
  /// The detected QR's rectangle on screen, or null while searching.
  final Rect? target;
  final Color color;

  const ScanFrame({super.key, this.target, this.color = Colors.white});

  /// The waiting frame for a preview of [size]: a centred square.
  static Rect idleRect(Size size) {
    final side = (size.shortestSide * 0.68).clamp(160.0, 300.0);
    return Rect.fromCenter(
      center: Offset(size.width / 2, size.height * 0.42),
      width: side,
      height: side,
    );
  }

  @override
  State<ScanFrame> createState() => _ScanFrameState();
}

class _ScanFrameState extends State<ScanFrame>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  @override
  void initState() {
    super.initState();
    _syncSweep();
  }

  @override
  void didUpdateWidget(ScanFrame old) {
    super.didUpdateWidget(old);
    _syncSweep();
  }

  /// The scan line only runs while searching.
  void _syncSweep() {
    if (widget.target == null) {
      if (!_sweep.isAnimating) _sweep.repeat(reverse: true);
    } else {
      _sweep.stop();
    }
  }

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final size = box.biggest;
      // A little breathing room around a detected code.
      final target = widget.target?.inflate(14) ?? ScanFrame.idleRect(size);
      return TweenAnimationBuilder<Rect?>(
        tween: RectTween(end: target),
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        builder: (context, rect, _) => AnimatedBuilder(
          animation: _sweep,
          builder: (context, _) => CustomPaint(
            size: size,
            painter: _FramePainter(
              rect: rect ?? target,
              color: widget.color,
              sweep: widget.target == null ? _sweep.value : null,
            ),
          ),
        ),
      );
    });
  }
}

class _FramePainter extends CustomPainter {
  final Rect rect;
  final Color color;

  /// Scan line position 0..1 from the top, or null for none.
  final double? sweep;

  _FramePainter({required this.rect, required this.color, this.sweep});

  @override
  void paint(Canvas canvas, Size size) {
    final radius = math.min(20.0, rect.shortestSide / 6);
    final hole = RRect.fromRectAndRadius(rect, Radius.circular(radius));

    // Dim everything but the frame.
    canvas.drawPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(Offset.zero & size)
        ..addRRect(hole),
      Paint()..color = Colors.black.withValues(alpha: 0.45),
    );

    // Corner brackets.
    final arm = math.min(34.0, rect.shortestSide / 3.2);
    final pen = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;
    final r = radius;
    canvas
      ..drawPath(
          Path()
            ..moveTo(rect.left, rect.top + arm)
            ..lineTo(rect.left, rect.top + r)
            ..arcToPoint(Offset(rect.left + r, rect.top), radius: Radius.circular(r))
            ..lineTo(rect.left + arm, rect.top),
          pen)
      ..drawPath(
          Path()
            ..moveTo(rect.right - arm, rect.top)
            ..lineTo(rect.right - r, rect.top)
            ..arcToPoint(Offset(rect.right, rect.top + r), radius: Radius.circular(r))
            ..lineTo(rect.right, rect.top + arm),
          pen)
      ..drawPath(
          Path()
            ..moveTo(rect.right, rect.bottom - arm)
            ..lineTo(rect.right, rect.bottom - r)
            ..arcToPoint(Offset(rect.right - r, rect.bottom),
                radius: Radius.circular(r))
            ..lineTo(rect.right - arm, rect.bottom),
          pen)
      ..drawPath(
          Path()
            ..moveTo(rect.left + arm, rect.bottom)
            ..lineTo(rect.left + r, rect.bottom)
            ..arcToPoint(Offset(rect.left, rect.bottom - r),
                radius: Radius.circular(r))
            ..lineTo(rect.left, rect.bottom - arm),
          pen);

    // Sweeping scan line, fading out at both ends.
    final s = sweep;
    if (s != null) {
      final y = rect.top + 14 + s * (rect.height - 28);
      final line = Rect.fromLTRB(rect.left + 14, y - 1.5, rect.right - 14, y + 1.5);
      canvas.drawRRect(
        RRect.fromRectAndRadius(line, const Radius.circular(2)),
        Paint()
          ..shader = LinearGradient(colors: [
            color.withValues(alpha: 0),
            color,
            color.withValues(alpha: 0),
          ]).createShader(line),
      );
    }
  }

  @override
  bool shouldRepaint(_FramePainter old) =>
      old.rect != rect || old.color != color || old.sweep != sweep;
}
