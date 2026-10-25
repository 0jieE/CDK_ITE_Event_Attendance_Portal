import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// Whether the phone can reach the server right now.
///
/// Two signals: the radio (Wi-Fi / mobile data on or off, from
/// connectivity_plus) and what requests actually experience - a Wi-Fi with no
/// internet still says "connected", so a request that fails for lack of a
/// network calls [reportUnreachable], and the next success calls
/// [reportReachable].
class ConnectivityService extends ChangeNotifier {
  final Connectivity? _connectivity;
  StreamSubscription<List<ConnectivityResult>>? _sub;

  bool _radio = true;
  bool _reachable = true;

  ConnectivityService({Connectivity? connectivity, bool listen = true})
      : _connectivity = listen ? (connectivity ?? Connectivity()) : null {
    _start();
  }

  bool get isOnline => _radio && _reachable;

  Future<void> _start() async {
    final c = _connectivity;
    if (c == null) return;
    try {
      _applyRadio(await c.checkConnectivity());
      _sub = c.onConnectivityChanged.listen(_applyRadio, onError: (_) {});
    } catch (_) {
      // Plugin unavailable: assume online and let requests tell us otherwise.
    }
  }

  void _applyRadio(List<ConnectivityResult> results) {
    final on = results.any((r) => r != ConnectivityResult.none);
    // A radio change is a fresh start: give the network another chance.
    if (on == _radio && (!on || _reachable)) return;
    _radio = on;
    _reachable = true;
    notifyListeners();
  }

  void reportUnreachable() {
    if (!_reachable) return;
    _reachable = false;
    notifyListeners();
    _scheduleProbe();
  }

  void reportReachable() {
    _probeTimer?.cancel();
    if (_reachable) return;
    _reachable = true;
    notifyListeners();
  }

  /// Checks whether the server answers again (set once the API exists).
  /// While unreachable with the radio on (e.g. Wi-Fi without internet) it is
  /// tried every [probeEvery], since nothing else would notice the return.
  Future<bool> Function()? probe;
  static const probeEvery = Duration(seconds: 20);
  Timer? _probeTimer;

  void _scheduleProbe() {
    _probeTimer?.cancel();
    if (probe == null) return;
    _probeTimer = Timer(probeEvery, () async {
      if (_reachable) return;
      if (_radio && (await probe?.call() ?? false)) {
        reportReachable();
      } else {
        _scheduleProbe();
      }
    });
  }

  @override
  void dispose() {
    _probeTimer?.cancel();
    _sub?.cancel();
    super.dispose();
  }
}
