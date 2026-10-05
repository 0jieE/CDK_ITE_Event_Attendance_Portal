import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';

import '../../models/qr_slot.dart';
import '../../services/api_service.dart';
import '../../theme/app_theme.dart';
import '../../utils/manila_time.dart';
import '../../widgets/profile_avatar.dart';

/// Instructor QR scanner. Each detected code is sent to `/api/instructor/scan/`;
/// the result is shown as a colored card. Repeated reads of the same code are
/// debounced, and scanning pauses while a scan is in flight.
class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key});

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [BarcodeFormat.qrCode],
  );

  bool _processing = false;
  ScanResult? _result;
  String? _lastToken;
  DateTime _lastHandledAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_processing) return;
    final raw = capture.barcodes.isNotEmpty ? capture.barcodes.first.rawValue : null;
    if (raw == null || raw.isEmpty) return;

    // Debounce: ignore the same token within a short cooldown.
    final now = DateTime.now();
    if (raw == _lastToken && now.difference(_lastHandledAt).inSeconds < 3) {
      return;
    }
    _lastToken = raw;
    _lastHandledAt = now;

    setState(() => _processing = true);
    final api = context.read<ApiService>();
    ScanResult result;
    try {
      result = await api.scan(raw);
    } catch (_) {
      result = ScanResult.failure('Network error — please try again.', null);
    }
    if (!mounted) return;

    // Feedback: haptic + a short click; distinct enough for success/failure.
    await HapticFeedback.mediumImpact();
    await SystemSound.play(SystemSoundType.click);

    setState(() {
      _result = result;
      _processing = false;
    });
  }

  void _clearResult() => setState(() => _result = null);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        systemOverlayStyle: SystemUiOverlayStyle.light,
        shape: const Border(),
        title: const Text('Scan Attendance QR',
            style: TextStyle(color: Colors.white)),
        actions: [
          IconButton(
            tooltip: 'Toggle torch',
            icon: const Icon(Icons.flash_on),
            onPressed: () => _controller.toggleTorch(),
          ),
          IconButton(
            tooltip: 'Switch camera',
            icon: const Icon(Icons.cameraswitch),
            onPressed: () => _controller.switchCamera(),
          ),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) => _CameraError(error: error),
          ),
          // Targeting frame.
          IgnorePointer(
            child: Center(
              child: Container(
                width: 240,
                height: 240,
                decoration: BoxDecoration(
                  border: Border.all(color: AppTheme.green, width: 4),
                  borderRadius: BorderRadius.circular(24),
                ),
              ),
            ),
          ),
          if (_processing)
            const Positioned(
              top: 16,
              left: 0,
              right: 0,
              child: Center(
                child: Chip(
                  avatar: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  label: Text('Recording…'),
                ),
              ),
            ),
          if (_result != null)
            Positioned(
              left: 12,
              right: 12,
              bottom: 24,
              child: _ResultCard(result: _result!, onDismiss: _clearResult),
            ),
        ],
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  final ScanResult result;
  final VoidCallback onDismiss;
  const _ResultCard({required this.result, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final (Color color, IconData icon, String title) = _style();
    return Card(
      color: color,
      elevation: 6,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (result.ok && (result.studentPhoto ?? '').isNotEmpty)
              ProfileAvatar(
                imageUrl: result.studentPhoto,
                name: result.studentName ?? '',
                radius: 32,
              )
            else
              Icon(icon, color: Colors.white, size: 36),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 16)),
                  const SizedBox(height: 4),
                  if (result.ok) ...[
                    Text('${result.studentName} (${result.studentNumber})',
                        style: const TextStyle(color: Colors.white)),
                    Text(
                      '${result.attendanceTypeDisplay} · ${result.eventName}',
                      style: const TextStyle(color: Colors.white70),
                    ),
                    if (result.scannedAt != null)
                      Text(
                        DateFormat('MMM d, h:mm a')
                            .format(toManila(result.scannedAt!)),
                        style: const TextStyle(color: Colors.white70),
                      ),
                  ] else
                    Text(result.detail,
                        style: const TextStyle(color: Colors.white)),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, color: Colors.white),
              onPressed: onDismiss,
            ),
          ],
        ),
      ),
    );
  }

  (Color, IconData, String) _style() {
    if (!result.ok) {
      return (AppTheme.statusColor('ABSENT'), Icons.cancel, _failTitle());
    }
    if (!result.created) {
      return (AppTheme.statusColor('LATE'), Icons.info, 'Already recorded');
    }
    return (AppTheme.statusColor('PRESENT'), Icons.check_circle, 'Recorded');
  }

  String _failTitle() {
    switch (result.code) {
      case 'INVALID_TOKEN':
        return 'Invalid QR code';
      case 'STALE_QR':
        return 'Expired QR code';
      case 'EVENT_INACTIVE':
        return 'Event not active';
      case 'EVENT_NOT_TODAY':
        return 'Event not today';
      case 'OUTSIDE_WINDOW':
        return 'Outside attendance time';
      default:
        return 'Scan failed';
    }
  }
}

class _CameraError extends StatelessWidget {
  final MobileScannerException error;
  const _CameraError({required this.error});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.no_photography, color: Colors.white54, size: 56),
            const SizedBox(height: 12),
            Text(
              'Camera unavailable.\nGrant camera permission and try again.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
            ),
          ],
        ),
      ),
    );
  }
}
