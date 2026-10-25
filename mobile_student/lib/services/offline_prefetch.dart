import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../models/user.dart';
import '../utils/event_dates.dart';
import '../utils/manila_time.dart';
import 'api_service.dart';
import 'auth_provider.dart';
import 'connectivity_service.dart';

/// Download (and so save on the phone, see [ApiService]'s read cache)
/// everything the student's screens show, so they still work after going offline
/// - without waiting for each tab to be opened. Failures are ignored: this is
/// best effort, and the screens fetch for themselves too.
Future<void> prefetchForOffline(ApiService api, User user) async {
  Future<void> quietly(Future<void> Function() load) async {
    try {
      await load();
    } catch (_) {
      /* best effort */
    }
  }

  if (!user.isStudent) return;
  final today = manilaToday();
  await Future.wait([
    quietly(() async {
      final events = await api.studentEvents();
      // Today's QR for every event running today.
      await Future.wait([
        for (final e in events)
          if (isRunningOn(e, today))
            quietly(() => api.studentQrs(event: e.id, date: apiDate(today))),
      ]);
    }),
    quietly(api.studentEventsAll),
    quietly(api.studentAttendance),
    quietly(api.studentFines),
    quietly(api.studentBalance),
    quietly(api.studentProfile),
  ]);
}

/// Runs [prefetchForOffline] whenever a real (online) session starts, the
/// connection comes back, or the app returns to the foreground - at most
/// every [minGap] unless a sign-in just happened.
class OfflinePrefetcher extends StatefulWidget {
  final Widget child;
  const OfflinePrefetcher({super.key, required this.child});

  static const minGap = Duration(minutes: 2);

  @override
  State<OfflinePrefetcher> createState() => _OfflinePrefetcherState();
}

class _OfflinePrefetcherState extends State<OfflinePrefetcher>
    with WidgetsBindingObserver {
  late final AuthProvider _auth;
  ConnectivityService? _connectivity;
  DateTime? _lastRun;
  bool _wasOnline = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _auth = context.read<AuthProvider>();
    _auth.onOnlineSession = (_) => _run(force: true);
    _connectivity = context.read<ConnectivityService?>()
      ?..addListener(_onConnectivity);
    _wasOnline = _connectivity?.isOnline ?? true;
    _run();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _connectivity?.removeListener(_onConnectivity);
    _auth.onOnlineSession = null;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _run();
  }

  void _onConnectivity() {
    final online = _connectivity?.isOnline ?? true;
    if (online && !_wasOnline) _run();
    _wasOnline = online;
  }

  void _run({bool force = false}) {
    final user = _auth.user;
    if (user == null ||
        _auth.status != AuthStatus.authenticated ||
        _auth.offlineSession ||
        !(_connectivity?.isOnline ?? true)) {
      return;
    }
    final now = DateTime.now();
    final last = _lastRun;
    if (!force &&
        last != null &&
        now.difference(last) < OfflinePrefetcher.minGap) {
      return;
    }
    _lastRun = now;
    unawaited(prefetchForOffline(_auth.api, user));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
