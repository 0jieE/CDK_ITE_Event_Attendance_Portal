import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';

import '../../models/scan_result.dart';
import '../../services/api_service.dart';
import '../../services/auth_provider.dart';
import '../../services/connectivity_service.dart';
import '../../services/offline_scan_service.dart';
import '../../theme/app_theme.dart';
import '../../utils/errors.dart';
import '../../utils/manila_time.dart';
import '../../widgets/profile_avatar.dart';
import '../../widgets/scan_frame.dart';

/// Instructor QR scanner, built for a line of students: it scans
/// **continuously**. Each code is sent to `/api/instructor/scan/` and the
/// result pops up as a coloured card that hides itself after a few seconds,
/// while the camera keeps looking for the next student. The viewfinder
/// follows the QR on screen, and a tally counts this session's scans.
///
/// A code is submitted once while it stays in view (its card stays up as long
/// as it is held there). Shown again after leaving the view, it is submitted
/// again: the server answers "Already recorded" (an amber warning) or records
/// the next slot if a new window has opened.
///
/// With no connection the scan is judged on the phone and queued by
/// [OfflineScanService], which uploads it once the connection is back.
class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key});

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

/// One scan of this session (for the tally and its list).
class _SessionScan {
  final ScanResult result;
  final DateTime at;
  const _SessionScan(this.result, this.at);
}

class _ScannerScreenState extends State<ScannerScreen> {
  /// `normal` reports a code repeatedly while it is in view (every
  /// [detectionTimeoutMs]), which is what lets the frame track it.
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
    detectionTimeoutMs: 150,
    formats: const [BarcodeFormat.qrCode],
  );

  /// A QR unseen for this long has left the view; shown again, it is read
  /// again. (While in view it is reported every ~150 ms.)
  static const _sameCodeGap = Duration(milliseconds: 1200);

  bool _processing = false;
  ScanResult? _result;
  Timer? _resultTimer;

  /// The QR whose card is showing, and when that card will hide.
  String? _resultToken;
  DateTime _resultHideAt = DateTime.fromMillisecondsSinceEpoch(0);

  String? _lastToken;
  DateTime _lastTokenSeenAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Where the QR in view is on screen (null: searching), and the timer that
  /// lets the frame go back to searching once the code leaves the view.
  Rect? _target;
  Timer? _lostTimer;
  Size _previewSize = Size.zero;

  final List<_SessionScan> _session = [];

  @override
  void initState() {
    super.initState();
    // Pick up QR codes generated since the last download, while we can.
    final offline = context.read<OfflineScanService?>();
    if (offline != null &&
        (context.read<ConnectivityService?>()?.isOnline ?? true)) {
      unawaited(offline.refreshPackQuietly());
    }
  }

  @override
  void dispose() {
    _resultTimer?.cancel();
    _lostTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    final barcode = capture.barcodes
        .where((b) => (b.rawValue ?? '').isNotEmpty)
        .firstOrNull;
    if (barcode == null) return;
    _track(capture, barcode);

    final raw = barcode.rawValue!;
    final now = DateTime.now();
    if (raw == _lastToken && now.difference(_lastTokenSeenAt) < _sameCodeGap) {
      _lastTokenSeenAt = now; // still the same student in front of the camera
      // Keep their card up while they hold the code there.
      if (_result != null && raw == _resultToken) {
        _hideCardAfter(const Duration(milliseconds: 1500), extendOnly: true);
      }
      return;
    }
    if (_processing) return;
    _lastToken = raw;
    _lastTokenSeenAt = now;
    unawaited(_handle(raw));
  }

  /// Move the frame onto the code; back to searching when it is gone.
  void _track(BarcodeCapture capture, Barcode barcode) {
    final orientation = _controller.value.deviceOrientation;
    final rect = barcodeRectOnScreen(
      corners: barcode.corners,
      imageSize: capture.size,
      previewSize: _previewSize,
      landscape: orientation == DeviceOrientation.landscapeLeft ||
          orientation == DeviceOrientation.landscapeRight,
    );
    if (rect != null && mounted) setState(() => _target = rect);
    _lostTimer?.cancel();
    _lostTimer = Timer(const Duration(milliseconds: 450), () {
      if (mounted) setState(() => _target = null);
    });
  }

  Future<void> _handle(String token) async {
    setState(() => _processing = true);
    final result = await _submit(token);
    if (!mounted) return;

    // Feedback: a firm buzz for "recorded", a double one for problems.
    if (result.ok && result.created) {
      unawaited(HapticFeedback.mediumImpact());
    } else {
      unawaited(HapticFeedback.heavyImpact());
      unawaited(Future.delayed(
          const Duration(milliseconds: 150), HapticFeedback.heavyImpact));
    }
    unawaited(SystemSound.play(SystemSoundType.click));

    setState(() {
      _result = result;
      _resultToken = token;
      _processing = false;
      _session.add(_SessionScan(result, DateTime.now()));
    });
    // Hide the card by itself so the next student can step up; warnings and
    // problems stay a little longer to be read.
    _hideCardAfter(result.ok && result.created
        ? const Duration(milliseconds: 2500)
        : const Duration(seconds: 4));
  }

  /// (Re)schedule hiding the card [delay] from now. With [extendOnly] it only
  /// ever postpones, never shortens, the current deadline.
  void _hideCardAfter(Duration delay, {bool extendOnly = false}) {
    final at = DateTime.now().add(delay);
    if (extendOnly && !at.isAfter(_resultHideAt)) return;
    _resultHideAt = at;
    _resultTimer?.cancel();
    _resultTimer = Timer(delay, _clearResult);
  }

  /// Online: the server records it. No connection (known up front, or found
  /// out by the request failing): judged on the phone and queued.
  Future<ScanResult> _submit(String token) async {
    final api = context.read<ApiService>();
    final offline = context.read<OfflineScanService?>();
    final connectivity = context.read<ConnectivityService?>();
    final offlineSession =
        context.read<AuthProvider?>()?.offlineSession ?? false;
    // No connection, or signed in offline (no server session to send with).
    if (offline != null &&
        (offlineSession || (connectivity != null && !connectivity.isOnline))) {
      return offline.scanOffline(token);
    }
    try {
      final result = await api.scan(token).timeout(const Duration(seconds: 8));
      connectivity?.reportReachable();
      if (offline != null && offline.pendingCount > 0) {
        unawaited(offline.sync());
      }
      return result;
    } catch (e) {
      if (offline != null && isNetworkError(e)) {
        connectivity?.reportUnreachable();
        return offline.scanOffline(token);
      }
      if (e is SessionExpired) {
        // Keep the scan: it syncs after signing in again.
        if (offline != null) return offline.scanOffline(token);
        return ScanResult.failure(friendlyError(e), null);
      }
      return ScanResult.failure('Network error — please try again.', null);
    }
  }

  void _clearResult() {
    _resultTimer?.cancel();
    _resultToken = null;
    if (mounted) setState(() => _result = null);
  }

  /// Frame colour: the last result while its card shows, green while a code
  /// is being recorded or held in view, white while searching.
  Color get _frameColor {
    final r = _result;
    if (r != null) return ScanResultCard.colorFor(r);
    if (_processing || _target != null) return AppTheme.green;
    return Colors.white;
  }

  void _showSession() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _SessionSheet(scans: _session.reversed.toList()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final online = context.watch<ConnectivityService?>()?.isOnline ?? true;
    final pending = context.watch<OfflineScanService?>()?.pendingCount ?? 0;
    final recorded = _session.where((s) => s.result.ok && s.result.created).length;
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
          ValueListenableBuilder(
            valueListenable: _controller,
            builder: (context, state, _) => IconButton(
              tooltip: 'Toggle torch',
              icon: Icon(state.torchState == TorchState.on
                  ? Icons.flash_on
                  : Icons.flash_off),
              onPressed: () => _controller.toggleTorch(),
            ),
          ),
          IconButton(
            tooltip: 'Switch camera',
            icon: const Icon(Icons.cameraswitch),
            onPressed: () => _controller.switchCamera(),
          ),
        ],
      ),
      body: LayoutBuilder(builder: (context, box) {
        _previewSize = box.biggest;
        return Stack(
          fit: StackFit.expand,
          children: [
            MobileScanner(
              controller: _controller,
              onDetect: _onDetect,
              errorBuilder: (context, error) => _CameraError(error: error),
            ),
            IgnorePointer(
              child: ScanFrame(target: _target, color: _frameColor),
            ),
            // Status + tally along the top.
            Positioned(
              top: 12,
              left: 12,
              right: 12,
              child: Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  ActionChip(
                    avatar: const Icon(Icons.how_to_reg, size: 18),
                    label: Text('$recorded recorded'
                        '${_session.length > recorded ? ' · ${_session.length} scans' : ''}'),
                    onPressed: _session.isEmpty ? null : _showSession,
                  ),
                  if (!online || pending > 0)
                    Chip(
                      avatar: Icon(online ? Icons.cloud_upload : Icons.cloud_off,
                          size: 18),
                      label: Text([
                        if (!online) 'Offline',
                        if (pending > 0) '$pending saved on phone',
                      ].join(' · ')),
                    ),
                ],
              ),
            ),
            // Hint under the frame while nothing is on show.
            if (_result == null)
              Positioned(
                left: 24,
                right: 24,
                top: ScanFrame.idleRect(box.biggest).bottom + 24,
                child: Text(
                  _processing
                      ? 'Recording…'
                      : 'Point the camera at the student\'s QR code.\n'
                          'Scanning continues for the next student.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    shadows: [Shadow(blurRadius: 6)],
                  ),
                ),
              ),
            Positioned(
              left: 12,
              right: 12,
              bottom: 24,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                transitionBuilder: (child, anim) => SlideTransition(
                  position: Tween(begin: const Offset(0, 0.3), end: Offset.zero)
                      .animate(anim),
                  child: FadeTransition(opacity: anim, child: child),
                ),
                child: _result == null
                    ? const SizedBox.shrink()
                    : ScanResultCard(
                        // A new key per scan so each one animates in.
                        key: ValueKey(_session.length),
                        result: _result!,
                        onDismiss: _clearResult,
                      ),
              ),
            ),
          ],
        );
      }),
    );
  }
}

/// This session's scans, newest first.
class _SessionSheet extends StatelessWidget {
  final List<_SessionScan> scans;
  const _SessionSheet({required this.scans});

  @override
  Widget build(BuildContext context) {
    final time = DateFormat('h:mm:ss a');
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.7),
        child: ListView.separated(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          itemCount: scans.length + 1,
          separatorBuilder: (_, i) =>
              i == 0 ? const SizedBox(height: 4) : const Divider(height: 1),
          itemBuilder: (context, i) {
            if (i == 0) {
              return Text('This session',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w800));
            }
            final s = scans[i - 1];
            final r = s.result;
            final (color, icon, title) = ScanResultCard.styleFor(r);
            return ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(icon, color: color),
              title: Text(r.ok
                  ? (r.studentName == null
                      ? 'Unknown student'
                      : '${r.studentName} (${r.studentNumber})')
                  : title),
              subtitle: Text(r.ok ? title : r.detail),
              trailing: Text(time.format(toManila(s.at)),
                  style: Theme.of(context).textTheme.bodySmall),
            );
          },
        ),
      ),
    );
  }
}

/// The coloured card shown after each scan (public so widget tests can render
/// it without a camera).
class ScanResultCard extends StatelessWidget {
  final ScanResult result;
  final VoidCallback onDismiss;
  const ScanResultCard({super.key, required this.result, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final (Color color, IconData icon, String title) = styleFor(result);
    return Card(
      color: color,
      elevation: 6,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The photo is large so the instructor can compare faces.
            if (result.ok && (result.studentPhoto ?? '').isNotEmpty)
              ProfileAvatar(
                imageUrl: result.studentPhoto,
                name: result.studentName ?? '',
                radius: 40,
              )
            else
              Icon(icon, color: Colors.white, size: 40),
            const SizedBox(width: 14),
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
                    Text(
                        result.studentName == null
                            ? 'Unknown student'
                            : '${result.studentName} (${result.studentNumber})',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.w700)),
                    if (_where.isNotEmpty)
                      Text(_where,
                          style: const TextStyle(color: Colors.white70)),
                    if (result.scannedAt != null)
                      Text(
                        DateFormat('MMM d, h:mm a')
                            .format(toManila(result.scannedAt!)),
                        style: const TextStyle(color: Colors.white70),
                      ),
                    if (result.offline)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(result.detail,
                            style: const TextStyle(
                                color: Colors.white,
                                fontStyle: FontStyle.italic)),
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

  /// "AM Time-In · Event" with whichever parts are known.
  String get _where => [result.attendanceTypeDisplay, result.eventName]
      .whereType<String>()
      .join(' · ');

  /// Saved-offline blue: clearly not the green "recorded on the server".
  static const offlineColor = Color(0xFF1D5C96);

  static Color colorFor(ScanResult result) => styleFor(result).$1;

  /// Colour, icon and title for a result (shared with the session list).
  static (Color, IconData, String) styleFor(ScanResult result) {
    if (!result.ok) {
      return (AppTheme.statusColor('ABSENT'), Icons.cancel, _failTitle(result.code));
    }
    if (!result.created) {
      return (AppTheme.warning, Icons.info, 'Already recorded');
    }
    if (result.offline) {
      return (
        offlineColor,
        Icons.cloud_upload,
        result.unverified ? 'Saved offline (not verified yet)' : 'Saved offline',
      );
    }
    return (AppTheme.statusColor('PRESENT'), Icons.check_circle, 'Recorded');
  }

  static String _failTitle(String? code) {
    switch (code) {
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
