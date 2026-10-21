import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/attendance_type.dart';
import '../models/event.dart';
import '../models/offline_pack.dart';
import '../models/qr_slot.dart';
import '../utils/errors.dart';
import '../utils/manila_time.dart';
import 'api_service.dart';
import 'connectivity_service.dart';

/// A queued scan the server refused when it finally synced.
class RejectedScan {
  final String label; // "Name (number)" or "Unknown student"
  final DateTime scannedAt;
  final String reason;
  const RejectedScan(this.label, this.scannedAt, this.reason);
}

/// Outcome of one sync of the offline queue.
class SyncReport {
  final int recorded;
  final int alreadyRecorded;
  final List<RejectedScan> rejected;
  const SyncReport(this.recorded, this.alreadyRecorded, this.rejected);
}

/// Lets an instructor keep scanning with no connection.
///
/// While online it keeps an [OfflinePack] (today's events and today's student
/// QR codes, by hash). Offline, a scan is judged on the phone against that
/// pack - name, slot, duplicates - and queued with its scan time. The queue is
/// stored on the phone (per instructor, surviving restarts and log-outs) and
/// uploaded automatically once the connection is back; the server then judges
/// each scan at its original time.
class OfflineScanService extends ChangeNotifier {
  final ApiService api;
  final ConnectivityService connectivity;
  final DateTime Function() _clock;

  OfflineScanService({
    required this.api,
    required this.connectivity,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    connectivity.addListener(_onConnectivity);
  }

  int? _userId;
  OfflinePack? _pack;
  List<QueuedScan> _queue = [];
  bool _syncing = false;
  SyncReport? _lastSync;
  String? _syncError;
  Timer? _retry;
  bool _wasOnline = true;

  OfflinePack? get pack => _pack;
  List<QueuedScan> get queue => List.unmodifiable(_queue);
  int get pendingCount => _queue.length;
  bool get syncing => _syncing;
  SyncReport? get lastSync => _lastSync;
  String? get syncError => _syncError;

  /// Now, corrected by the server-vs-phone clock difference seen at download.
  DateTime get now => _clock().add(_pack?.clockOffset ?? Duration.zero);

  String get _packKey => 'instructor:$_userId:offline_pack';
  String get _queueKey => 'instructor:$_userId:scan_queue';

  /// Switch to [userId]'s pack and queue (null = signed out: forget them in
  /// memory; they stay on the phone for that instructor's next sign-in).
  Future<void> attach(int? userId) async {
    if (userId == _userId) return;
    _userId = userId;
    _pack = null;
    _queue = [];
    _lastSync = null;
    _syncError = null;
    _retry?.cancel();
    if (userId != null) {
      _pack = OfflinePack.fromStore(await api.cache.readJson(_packKey));
      final stored = await api.cache.readJson(_queueKey);
      if (stored is List) {
        _queue = [
          for (final q in stored)
            if (q is Map) QueuedScan.fromJson(Map<String, dynamic>.from(q)),
        ];
      }
    }
    notifyListeners();
    if (_queue.isNotEmpty) unawaited(sync());
  }

  // -------------------------------------------------------------------------
  // Pack
  // -------------------------------------------------------------------------
  /// Download a fresh pack (throws on failure).
  Future<OfflinePack> refreshPack() async {
    final pack = await api
        .instructorOfflinePack(receivedAt: _clock())
        .timeout(const Duration(seconds: 15));
    connectivity.reportReachable();
    _pack = pack;
    if (_userId != null) await api.cache.writeJson(_packKey, pack.toStore());
    notifyListeners();
    return pack;
  }

  /// [refreshPack] that never throws (used opportunistically).
  Future<void> refreshPackQuietly() async {
    try {
      await refreshPack();
    } catch (e) {
      if (isNetworkError(e)) connectivity.reportUnreachable();
    }
  }

  /// Today's scannable events: fresh from the server when online (which also
  /// refreshes the pack), else the downloaded pack if it is for today.
  Future<List<Event>> loadEvents() async {
    try {
      return (await refreshPack()).events;
    } catch (e) {
      // A server without offline support yet: plain list, no offline pack.
      if (e is ApiException && e.statusCode == 404) return api.instructorEvents();
      if (!isNetworkError(e)) rethrow;
      connectivity.reportUnreachable();
      final pack = _pack;
      if (pack != null && daysBetween(pack.date, manilaToday(now)) == 0) {
        return pack.events;
      }
      rethrow;
    }
  }

  // -------------------------------------------------------------------------
  // Offline scanning
  // -------------------------------------------------------------------------
  /// Judge [token] on the phone and queue it. Mirrors the server's checks as
  /// far as the pack allows; the server has the final word at sync.
  Future<ScanResult> scanOffline(String token) async {
    final scannedAt = now;
    final local = toManila(scannedAt);
    final pack = _pack;
    final packIsToday =
        pack != null && daysBetween(pack.date, manilaToday(scannedAt)) == 0;
    final code = packIsToday ? pack.codes[hashToken(token)] : null;

    if (code != null) {
      final event = pack!.eventById(code.eventId);
      final slot = event?.slotAt(local);
      if (event == null || slot == null) return _outsideWindow();
      final already = code.credited.contains(slot) ||
          _queue.any((q) => q.token == token && q.slot == slot && _sameDay(q, scannedAt));
      final result = ScanResult(
        ok: true,
        created: !already,
        offline: true,
        detail: already
            ? 'Attendance was already recorded for this slot.'
            : "Saved on this phone. It will sync when you're back online.",
        studentName: code.studentName,
        studentNumber: code.studentNumber,
        eventName: event.name,
        attendanceTypeDisplay: AttendanceType.labelFor(slot),
        scannedAt: scannedAt,
      );
      if (!already) {
        await _enqueue(QueuedScan(
          token: token,
          scannedAt: scannedAt,
          studentName: code.studentName,
          studentNumber: code.studentNumber,
          eventId: event.id,
          slot: slot,
        ));
      }
      return result;
    }

    // Not in the pack: a QR generated after the last download, or not a real
    // code. Queue it anyway (the server decides) unless no window is open.
    String? openSlot;
    if (packIsToday) {
      openSlot = pack.events.map((e) => e.slotAt(local)).nonNulls.firstOrNull;
      if (openSlot == null) return _outsideWindow();
    }
    final already = _queue.any((q) =>
        q.token == token &&
        q.slot == openSlot &&
        _sameDay(q, scannedAt) &&
        (openSlot != null || scannedAt.difference(q.scannedAt).inMinutes < 30));
    if (!already) {
      await _enqueue(QueuedScan(token: token, scannedAt: scannedAt, slot: openSlot));
    }
    return ScanResult(
      ok: true,
      created: !already,
      offline: true,
      unverified: true,
      detail: already
          ? 'This QR is already saved on this phone.'
          : "Saved on this phone. This QR isn't in the downloaded list, so the "
              'student will be confirmed when it syncs.',
      attendanceTypeDisplay:
          openSlot == null ? null : AttendanceType.labelFor(openSlot),
      scannedAt: scannedAt,
    );
  }

  ScanResult _outsideWindow() => ScanResult.failure(
        'No attendance slot is open right now. Scanning is only allowed '
        'during the scheduled time windows.',
        'OUTSIDE_WINDOW',
        offline: true,
      );

  bool _sameDay(QueuedScan q, DateTime at) =>
      daysBetween(manilaToday(q.scannedAt), manilaToday(at)) == 0;

  Future<void> _enqueue(QueuedScan scan) async {
    _queue = [..._queue, scan];
    await _saveQueue();
    notifyListeners();
    _scheduleRetry();
  }

  Future<void> _saveQueue() async {
    if (_userId == null) return;
    await api.cache.writeJson(_queueKey, [for (final q in _queue) q.toJson()]);
  }

  // -------------------------------------------------------------------------
  // Sync
  // -------------------------------------------------------------------------
  static const _batch = 500;

  /// Upload the queue. Scans the server answered are removed (recorded,
  /// already recorded or rejected - see [lastSync]); on a network failure
  /// they stay for the next try. Returns null when nothing was sent.
  Future<SyncReport?> sync() async {
    if (_syncing || _queue.isEmpty || _disposed) return null;
    _syncing = true;
    _syncError = null;
    notifyListeners();
    var recorded = 0, already = 0;
    final rejected = <RejectedScan>[];
    var sentAny = false;
    try {
      while (_queue.isNotEmpty) {
        final batch = _queue.take(_batch).toList();
        final results =
            await api.syncScans(batch).timeout(const Duration(seconds: 60));
        connectivity.reportReachable();
        sentAny = true;
        for (var i = 0; i < batch.length && i < results.length; i++) {
          final status = results[i]['http_status'];
          if (status == 201) {
            recorded++;
          } else if (status == 200) {
            already++;
          } else {
            rejected.add(RejectedScan(
              batch[i].label,
              batch[i].scannedAt,
              '${results[i]['detail'] ?? 'Rejected by the server.'}',
            ));
          }
        }
        final done = results.length.clamp(0, batch.length);
        _queue = _queue.sublist(done);
        await _saveQueue();
        if (done == 0) break; // malformed reply: don't spin
      }
    } catch (e) {
      if (isNetworkError(e)) {
        connectivity.reportUnreachable();
        _syncError = "Still offline. Saved scans will sync when you're back online.";
      } else {
        _syncError = friendlyError(e);
      }
    } finally {
      _syncing = false;
    }
    SyncReport? report;
    if (sentAny) {
      report = SyncReport(recorded, already, rejected);
      _lastSync = report;
      unawaited(refreshPackQuietly()); // pick up the newly credited slots
    }
    notifyListeners();
    _scheduleRetry();
    return report;
  }

  /// Back online: send what is waiting.
  void _onConnectivity() {
    final online = connectivity.isOnline;
    if (online && !_wasOnline && _queue.isNotEmpty) unawaited(sync());
    _wasOnline = online;
  }

  /// Keep trying every minute while scans are waiting (covers a Wi-Fi that
  /// comes back without the radio state changing).
  void _scheduleRetry() {
    _retry?.cancel();
    if (_queue.isEmpty || _userId == null || _disposed) return;
    _retry = Timer(const Duration(minutes: 1), () => unawaited(sync()));
  }

  bool _disposed = false;

  /// A sync or download may finish after the service is gone.
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _retry?.cancel();
    connectivity.removeListener(_onConnectivity);
    super.dispose();
  }
}
