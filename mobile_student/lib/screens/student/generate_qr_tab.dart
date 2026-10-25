import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../models/event.dart';
import '../../models/qr_slot.dart';
import '../../services/api_service.dart';
import '../../services/auth_provider.dart';
import '../../services/connectivity_service.dart';
import '../../theme/app_theme.dart';
import '../../utils/errors.dart';
import '../../utils/event_dates.dart';
import '../../utils/manila_time.dart';
import '../../widgets/qr_code_view.dart';
import '../../widgets/state_message.dart';
import 'qr_display_screen.dart';

/// Pick an event -> (today's) date -> generate the **daily** QR.
///
/// A student can generate a QR only once per event-day, and only for today:
/// when today's QR already exists it is shown inline (with a "Show full
/// screen" button) and the Generate button is hidden. The server is the
/// authority on all of this; the UI just guides.
///
/// Offline: generating needs the server, so it is disabled, but the events
/// and today's QR are kept on the phone - a QR generated earlier today still
/// shows (the instructor can scan it offline too).
class GenerateQrTab extends StatefulWidget {
  const GenerateQrTab({super.key});

  @override
  State<GenerateQrTab> createState() => _GenerateQrTabState();
}

class _GenerateQrTabState extends State<GenerateQrTab>
    with WidgetsBindingObserver {
  List<Event>? _events;
  int _eventsVersion = 0; // bumps on every reload (re-keys the dropdown)
  bool _loadingEvents = true;
  String? _eventsError;

  Event? _event;
  DateTime _today = manilaToday();
  DateTime? _date; // the selected day: always today, or null when not running

  QrSlot? _qr; // today's QR for the selected event, once known
  bool _checking = false;
  String? _checkError;

  bool _busy = false;
  String? _genError;

  /// The last request failed for lack of a connection.
  bool _offline = false;

  /// [_qr] came from the phone's cache, not the server.
  bool _fromCache = false;

  ConnectivityService? _connectivity;
  bool _wasOnline = true;

  static const _offlineMessage =
      "You're offline. Connect to the internet to generate your QR.";

  /// Guards against a slow response for an older selection overwriting a
  /// newer one.
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadEvents();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final c = context.read<ConnectivityService?>();
    if (c != _connectivity) {
      _connectivity?.removeListener(_onConnectivity);
      _connectivity = c?..addListener(_onConnectivity);
      _wasOnline = c?.isOnline ?? true;
    }
  }

  @override
  void dispose() {
    _connectivity?.removeListener(_onConnectivity);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Back online after an offline load: refresh quietly.
  void _onConnectivity() {
    final online = _connectivity?.isOnline ?? true;
    if (online && !_wasOnline && mounted) {
      if (_events == null) {
        _loadEvents();
      } else {
        _loadEvents(silent: true);
      }
    }
    if (mounted) setState(() => _wasOnline = online);
  }

  // -- offline cache (per student) ------------------------------------------
  String get _cachePrefix =>
      'student:${context.read<AuthProvider?>()?.user?.id ?? 0}';

  Future<void> _cacheEvents(List<Event> events) =>
      context.read<ApiService>().cache.writeJson(
          '$_cachePrefix:events', [for (final e in events) e.toJson()]);

  Future<List<Event>> _cachedEvents() async {
    final json =
        await context.read<ApiService>().cache.readJson('$_cachePrefix:events');
    if (json is! List) return const [];
    try {
      return [
        for (final e in json) Event.fromJson(Map<String, dynamic>.from(e as Map)),
      ];
    } catch (_) {
      return const [];
    }
  }

  String _qrKey(int event, DateTime date) =>
      '$_cachePrefix:qr:$event:${apiDate(date)}';

  Future<void> _cacheQr(QrSlot qr) => context
      .read<ApiService>()
      .cache
      .writeJson(_qrKey(qr.event, qr.date), qr.toJson());

  Future<QrSlot?> _cachedQr(int event, DateTime date) async {
    final json =
        await context.read<ApiService>().cache.readJson(_qrKey(event, date));
    if (json is! Map) return null;
    try {
      return QrSlot.fromJson(Map<String, dynamic>.from(json));
    } catch (_) {
      return null;
    }
  }

  /// The app may sit in the background past midnight: re-evaluate "today" (and
  /// whether today's QR exists) when it comes back.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    final now = manilaToday();
    if (_event != null && now != _today) _selectEvent(_event!);
  }

  /// Loads the events. [silent] (pull-to-refresh) keeps the page on screen and
  /// the current selection instead of showing the full-page spinner.
  Future<void> _loadEvents({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loadingEvents = true;
        _eventsError = null;
      });
    }
    try {
      List<Event> events;
      try {
        events = await context.read<ApiService>().studentEvents();
        _offline = false;
        if (mounted) _cacheEvents(events);
      } catch (e) {
        if (!isNetworkError(e) || !mounted) rethrow;
        // Offline: use the events saved on the phone, if any.
        events = await _cachedEvents();
        if (events.isEmpty) rethrow;
        _offline = true;
      }
      if (!mounted) return;
      setState(() {
        _events = events;
        _eventsVersion++;
        _loadingEvents = false;
        _eventsError = null;
      });
      if (events.isNotEmpty) {
        // Keep the current event if it is still listed; otherwise prefer one
        // that is running today, else the first.
        final today = manilaToday();
        final keep = events.where((e) => e.id == _event?.id).firstOrNull;
        final pick = keep ??
            events.firstWhere(
              (e) => isRunningOn(e, today),
              orElse: () => events.first,
            );
        _selectEvent(pick);
      } else {
        setState(() => _event = null);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _eventsError = isNetworkError(e)
            ? "You're offline and no events are saved on this phone yet. "
                'Connect to the internet and try again.'
            : friendlyError(e);
        _loadingEvents = false;
      });
    }
  }

  void _selectEvent(Event e) {
    final today = manilaToday();
    final day = selectableDay(e, today);
    setState(() {
      _event = e;
      _today = today;
      _date = day;
      _qr = null;
      _fromCache = false;
      _checkError = null;
      _genError = null;
      _checking = false;
    });
    if (day != null) _checkExisting();
  }

  /// Does today's QR for the selected event already exist? (contract C)
  Future<void> _checkExisting() async {
    final event = _event;
    final date = _date;
    if (event == null || date == null) return;
    final seq = ++_seq;
    setState(() {
      _checking = true;
      _checkError = null;
    });
    try {
      final list = await context.read<ApiService>().studentQrs(
            event: event.id,
            date: apiDate(date),
          );
      if (!mounted || seq != _seq) return;
      final qr = list.where((q) => q.event == event.id).firstOrNull;
      if (qr != null) _cacheQr(qr);
      setState(() {
        _qr = qr;
        _fromCache = false;
        _offline = false;
        _checking = false;
      });
    } on SessionExpired {
      return; // the router is already sending the user to the login screen
    } catch (e) {
      if (!mounted || seq != _seq) return;
      if (isNetworkError(e)) {
        // Offline: today's QR from the phone, if it was generated here.
        final cached = await _cachedQr(event.id, date);
        if (!mounted || seq != _seq) return;
        setState(() {
          _qr = cached;
          _fromCache = cached != null;
          _offline = true;
          _checking = false;
        });
        return;
      }
      setState(() {
        _checkError = friendlyError(e);
        _checking = false;
      });
    }
  }

  Future<void> _generate() async {
    final event = _event;
    final date = _date;
    if (event == null || date == null) return;
    if (!(_connectivity?.isOnline ?? true)) {
      setState(() => _genError = _offlineMessage);
      return;
    }
    final seq = ++_seq;
    setState(() {
      _busy = true;
      _genError = null;
    });
    try {
      // 201 (new) and 200 (already existed) both return the QR.
      final slot = await context.read<ApiService>().generateQr(
            event: event.id,
            date: apiDate(date),
          );
      if (!mounted || seq != _seq) return;
      _cacheQr(slot);
      setState(() {
        _qr = slot;
        _fromCache = false;
        _offline = false;
      });
    } on SessionExpired {
      return;
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        if (isNetworkError(e)) _offline = true;
        _genError = isNetworkError(e) ? _offlineMessage : friendlyError(e);
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _openFullScreen() {
    final qr = _qr;
    final event = _event;
    if (qr == null || event == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => QrDisplayScreen(slot: qr, event: event),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loadingEvents) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_eventsError != null) {
      return StateMessage(
        icon: Icons.cloud_off,
        isError: true,
        title: 'Could not load events',
        subtitle: _eventsError,
        actionLabel: 'Retry',
        onAction: _loadEvents,
      );
    }
    final events = _events ?? const <Event>[];
    if (events.isEmpty) {
      return StateMessage(
        icon: Icons.event_busy,
        title: 'No active events to generate a QR for',
        actionLabel: 'Refresh',
        onAction: _loadEvents,
      );
    }
    final event = _event;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return RefreshIndicator(
      onRefresh: () => _loadEvents(silent: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Generate your daily attendance QR and show it to the instructor. '
            'You can create one per event each day; it is scanned within each '
            "slot's time window.",
            style: TextStyle(color: muted),
          ),
          const SizedBox(height: 20),
          DropdownButtonFormField<Event>(
            key: ValueKey('event-${event?.id}-$_eventsVersion'),
            initialValue: event,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Event',
              prefixIcon: Icon(Icons.event_outlined),
            ),
            items: events
                .map((e) => DropdownMenuItem(
                      value: e,
                      child: Text(e.name, overflow: TextOverflow.ellipsis),
                    ))
                .toList(),
            onChanged: (e) {
              if (e != null) _selectEvent(e);
            },
          ),
          const SizedBox(height: 16),
          if (event != null) _buildDateField(event),
          if (event != null && _date == null) ...[
            const SizedBox(height: 16),
            InlineBanner(
              isError: false,
              icon: Icons.event_busy,
              message: "This event isn't running today. You can only generate "
                  'a QR on a day the event runs '
                  '(${_rangeLabel(event)}).',
            ),
          ],
          if (event != null && event.schedule.isNotEmpty) ...[
            const SizedBox(height: 16),
            _ScheduleCard(event: event),
          ],
          const SizedBox(height: 20),
          _buildAction(),
        ],
      ),
    );
  }

  String _rangeLabel(Event e) {
    final df = DateFormat('MMM d');
    final dfy = DateFormat('MMM d, y');
    return daysBetween(e.startDate, e.endDate) == 0
        ? dfy.format(e.startDate)
        : '${df.format(e.startDate)} – ${dfy.format(e.endDate)}';
  }

  Widget _buildDateField(Event event) {
    final days = eventDays(event, _today);
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return DropdownButtonFormField<DateTime>(
      key: ValueKey('date-${event.id}-$_today-${_date != null}'),
      initialValue: _date,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: 'Date',
        prefixIcon: const Icon(Icons.calendar_today_outlined),
        helperText: _date == null ? null : 'Only today can be generated',
      ),
      hint: Text('Not available today', style: TextStyle(color: muted)),
      items: [
        for (final d in days)
          DropdownMenuItem<DateTime>(
            value: d.date,
            enabled: d.selectable,
            child: _DayRow(day: d),
          ),
      ],
      // Opening the list is allowed (to see the range) but only today is
      // enabled, so a past/future day can never be chosen.
      onChanged: (d) {
        if (d == null || daysBetween(_today, d) != 0) return;
        if (_date == null || daysBetween(_date!, d) != 0) {
          setState(() => _date = d);
          _checkExisting();
        }
      },
    );
  }

  Widget _buildAction() {
    if (_date == null) {
      return const FilledButton(
        onPressed: null,
        child: Text('Generate QR'),
      );
    }
    if (_checking) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(strokeWidth: 3)),
              SizedBox(height: 12),
              Text('Checking your QR for today…'),
            ],
          ),
        ),
      );
    }
    if (_checkError != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InlineBanner(message: _checkError!),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _checkExisting,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        ],
      );
    }
    final qr = _qr;
    if (qr != null) {
      return _QrCard(
          slot: qr, onFullScreen: _openFullScreen, savedOnPhone: _fromCache);
    }
    final online = _connectivity?.isOnline ?? true;
    if (_offline || !online) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const InlineBanner(
            isError: false,
            icon: Icons.cloud_off,
            message: _offlineMessage,
          ),
          const SizedBox(height: 12),
          const FilledButton(
            onPressed: null,
            child: Text('Generate QR'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _checkExisting,
            icon: const Icon(Icons.refresh),
            label: const Text('Try again'),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_genError != null) ...[
          InlineBanner(message: _genError!),
          const SizedBox(height: 12),
        ],
        FilledButton.icon(
          style: AppTheme.wide,
          onPressed: _busy ? null : _generate,
          icon: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: AppTheme.onGreen))
              : Icon(_genError != null ? Icons.refresh : Icons.qr_code_2),
          label: Text(_busy
              ? 'Generating…'
              : _genError != null
                  ? 'Try again'
                  : 'Generate QR'),
        ),
      ],
    );
  }
}

/// One row of the date dropdown: the date plus a "Today / Upcoming / Past"
/// hint; non-selectable days are muted.
class _DayRow extends StatelessWidget {
  final EventDay day;
  const _DayRow({required this.day});

  @override
  Widget build(BuildContext context) {
    final brand = context.brand;
    final scheme = Theme.of(context).colorScheme;
    final label = DateFormat('EEE, MMM d, y').format(day.date);
    final textColor = day.selectable
        ? scheme.onSurface
        : scheme.onSurface.withValues(alpha: 0.42);
    return Row(
      children: [
        Expanded(
          child: Text(label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: textColor,
                fontWeight: day.selectable ? FontWeight.w700 : FontWeight.w400,
              )),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: day.selectable ? brand.presentBg : brand.neutralBg,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            day.hint,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: day.selectable
                  ? brand.presentFg
                  : brand.neutralFg.withValues(alpha: 0.8),
            ),
          ),
        ),
      ],
    );
  }
}

/// Today's QR shown inline, with a button to open it full screen.
class _QrCard extends StatelessWidget {
  final QrSlot slot;
  final VoidCallback onFullScreen;

  /// Shown from the phone's copy while offline.
  final bool savedOnPhone;
  const _QrCard({
    required this.slot,
    required this.onFullScreen,
    this.savedOnPhone = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final width = MediaQuery.sizeOf(context).width;
    final size = (width - 32 - 2 * 20 - 2 * 12).clamp(160.0, 280.0);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.check_circle, color: context.brand.accent, size: 20),
                const SizedBox(width: 8),
                Text("Today's QR is ready",
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w800)),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              DateFormat('EEEE, MMM d, y').format(slot.date),
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: context.brand.border),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: QrCodeView(data: slot.token, size: size),
                ),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: onFullScreen,
              icon: const Icon(Icons.fullscreen),
              label: const Text('Show full screen'),
            ),
            const SizedBox(height: 10),
            if (savedOnPhone) ...[
              Text(
                "Offline: showing the copy saved on this phone. It still "
                'works for scanning.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: context.brand.accent,
                    fontSize: 13,
                    fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
            ],
            Text(
              'One QR per event each day — show this one to your instructor '
              'during each slot window.',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shows the event's per-slot scan windows.
class _ScheduleCard extends StatelessWidget {
  final Event event;
  const _ScheduleCard({required this.event});

  @override
  Widget build(BuildContext context) {
    final brand = context.brand;
    return Card(
      color: brand.tint,
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.schedule, size: 18, color: brand.accent),
                const SizedBox(width: 6),
                Text('Scan windows',
                    style: TextStyle(
                        fontWeight: FontWeight.w700, color: brand.accent)),
              ],
            ),
            const SizedBox(height: 8),
            ...event.schedule.map(
              (w) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(w.label),
                    Text('${w.start} – ${w.end}',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
