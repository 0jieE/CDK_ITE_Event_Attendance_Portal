import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../models/attendance_log.dart';
import '../../models/event.dart';
import '../../models/missed_slot.dart';
import '../../services/api_service.dart';
import '../../theme/app_theme.dart';
import '../../utils/attendance_groups.dart';
import '../../utils/errors.dart';
import '../../utils/event_dates.dart';
import '../../utils/manila_time.dart';
import '../../widgets/state_message.dart';
import '../../widgets/status_chip.dart';

/// The student's attendance history as one expandable card per event
/// (`?all=true`, newest first). Expanding a card drops down the slots the
/// student missed (date, slot, scan window, fine), then the slots attended.
/// The event closest to today (see [pickClosestEvent]) starts expanded.
class HistoryTab extends StatefulWidget {
  const HistoryTab({super.key});

  @override
  State<HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<HistoryTab> {
  List<Event> _events = const [];
  Map<int, List<AttendanceLog>> _attended = const {};

  /// Missed slots per event; null when they couldn't be loaded (the cards
  /// still show, with a note instead of the list).
  Map<int, List<MissedSlot>>? _missed;
  bool _loading = true;
  String? _error;

  /// Ids of the expanded cards; null until the first load picks the default.
  Set<int>? _open;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Loads events, scans and missed slots together. [silent] = pull-to-refresh
  /// (keeps the current list on screen and which cards are open).
  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    final api = context.read<ApiService>();
    // Missed slots are optional: a failure there must not hide the history.
    final missedF = api.studentMissedSlots().then<List<MissedSlot>?>(
      (v) => v,
      onError: (Object e) {
        if (e is SessionExpired) throw e;
        return null;
      },
    );
    try {
      final results = await Future.wait<Object?>([
        api.studentEventsAll(),
        api.studentAttendance(),
        missedF,
      ]);
      if (!mounted) return;
      final events = results[0] as List<Event>;
      final logs = results[1] as List<AttendanceLog>;
      final missed = results[2] as List<MissedSlot>?;
      setState(() {
        _events = events;
        _attended = _byEvent(logs.where((l) => l.isPresent), (l) => l.event);
        _missed = missed == null ? null : _byEvent(missed, (m) => m.event);
        _open ??= {?pickClosestEvent(events, manilaToday())?.id};
        _loading = false;
        _error = null;
      });
    } on SessionExpired {
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = friendlyError(e);
        _loading = false;
      });
    }
  }

  static Map<int, List<T>> _byEvent<T>(Iterable<T> items, int Function(T) id) {
    final out = <int, List<T>>{};
    for (final i in items) {
      out.putIfAbsent(id(i), () => []).add(i);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return StateMessage(
        icon: Icons.cloud_off,
        isError: true,
        title: 'Could not load history',
        subtitle: _error,
        actionLabel: 'Retry',
        onAction: _load,
      );
    }
    return RefreshIndicator(
      onRefresh: () => _load(silent: true),
      child: _events.isEmpty
          ? const RefreshableCenter(
              child: StateMessage(
                icon: Icons.history,
                title: 'No events yet',
                subtitle: 'Events and your attendance will show up here.',
              ),
            )
          : ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              itemCount: _events.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (context, i) {
                final e = _events[i];
                return _EventCard(
                  key: ValueKey(e.id),
                  event: e,
                  attended: _attended[e.id] ?? const [],
                  missed: _missed == null ? null : (_missed![e.id] ?? const []),
                  initiallyExpanded: _open?.contains(e.id) ?? false,
                  onExpansionChanged: (open) =>
                      open ? _open?.add(e.id) : _open?.remove(e.id),
                );
              },
            ),
    );
  }
}

String _range(Event e) {
  final df = DateFormat('MMM d');
  final dfy = DateFormat('MMM d, y');
  return daysBetween(e.startDate, e.endDate) == 0
      ? dfy.format(e.startDate)
      : '${df.format(e.startDate)} – ${dfy.format(e.endDate)}';
}

/// "07:00:00" -> "7:00 AM".
String _clock(String raw) {
  final p = raw.split(':').map(int.tryParse).toList();
  if (p.length < 2 || p[0] == null || p[1] == null) return raw;
  return DateFormat('h:mm a').format(DateTime(2000, 1, 1, p[0]!, p[1]!));
}

/// One event: header with its phase and missed count; expands to the slot list.
class _EventCard extends StatelessWidget {
  final Event event;
  final List<AttendanceLog> attended;
  final List<MissedSlot>? missed;
  final bool initiallyExpanded;
  final ValueChanged<bool> onExpansionChanged;

  const _EventCard({
    super.key,
    required this.event,
    required this.attended,
    required this.missed,
    required this.initiallyExpanded,
    required this.onExpansionChanged,
  });

  @override
  Widget build(BuildContext context) {
    final today = manilaToday();
    final upcoming = daysBetween(today, event.startDate) > 0;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: ExpansionTile(
        initiallyExpanded: initiallyExpanded,
        onExpansionChanged: onExpansionChanged,
        shape: const Border(),
        collapsedShape: const Border(),
        tilePadding: const EdgeInsets.fromLTRB(16, 6, 12, 6),
        childrenPadding: const EdgeInsets.only(bottom: 8),
        title: Text(event.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(_range(event),
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
              _PhaseBadge(event: event, today: today),
              if (!upcoming && missed != null)
                missed!.isEmpty
                    ? const StatusChip('PRESENT', label: 'No misses')
                    : StatusChip('ABSENT', label: '${missed!.length} missed'),
            ],
          ),
        ),
        children: upcoming
            ? [const _Note("This event hasn't started yet.")]
            : [
                const Divider(indent: 16, endIndent: 16),
                _SectionHeader(
                    missed == null || missed!.isEmpty
                        ? 'Missed slots'
                        : 'Missed slots (${missed!.length})'),
                if (missed == null)
                  const _Note("Missed slots couldn't be loaded. "
                      'Pull down to refresh.')
                else if (missed!.isEmpty)
                  const _Note("You haven't missed any slot so far.")
                else
                  for (final m in missed!) _MissedRow(slot: m),
                _SectionHeader(attended.isEmpty
                    ? 'Attended'
                    : 'Attended (${attended.length})'),
                if (attended.isEmpty)
                  const _Note('No scans recorded yet.')
                else
                  for (final g in groupLogsByDate(attended))
                    for (final l in g.logs) _AttendedRow(log: l),
              ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(text,
          style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.onSurfaceVariant)),
    );
  }
}

class _Note extends StatelessWidget {
  final String text;
  const _Note(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Text(text,
          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
    );
  }
}

/// A missed slot: which slot, which day, when its scan window was, and its fine.
class _MissedRow extends StatelessWidget {
  final MissedSlot slot;
  const _MissedRow({required this.slot});

  @override
  Widget build(BuildContext context) {
    final brand = context.brand;
    final label = slot.attendanceTypeDisplay.isNotEmpty
        ? slot.attendanceTypeDisplay
        : slot.attendanceType;
    final day = DateFormat('EEE, MMM d, y').format(slot.date);
    final start = slot.windowStart, end = slot.windowEnd;
    final window = start != null && end != null
        ? 'Scan window ${_clock(start)} – ${_clock(end)}'
        : null;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      leading: Icon(Icons.cancel_outlined, color: brand.absentFg),
      title: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text(window == null ? day : '$day\n$window'),
      isThreeLine: window != null,
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text('₱${slot.rate}',
              style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          StatusChip(slot.paid ? 'PAID' : 'UNPAID'),
        ],
      ),
    );
  }
}

class _AttendedRow extends StatelessWidget {
  final AttendanceLog log;
  const _AttendedRow({required this.log});

  @override
  Widget build(BuildContext context) {
    final brand = context.brand;
    final label = log.attendanceTypeDisplay.isNotEmpty
        ? log.attendanceTypeDisplay
        : log.attendanceType;
    final day = DateFormat('EEE, MMM d, y').format(log.date);
    final at = log.scannedAt;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      leading: Icon(Icons.check_circle_outline, color: brand.presentFg),
      title: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text(at == null
          ? day
          : '$day · ${DateFormat('h:mm a').format(toManila(at))}'),
      trailing: StatusChip(log.status),
    );
  }
}

/// "Ongoing" / "Upcoming" / "Past" tag for an event relative to [today].
class _PhaseBadge extends StatelessWidget {
  final Event event;
  final DateTime today;
  const _PhaseBadge({required this.event, required this.today});

  @override
  Widget build(BuildContext context) {
    if (isRunningOn(event, today)) {
      return const StatusChip('PRESENT', label: 'Ongoing');
    }
    final upcoming = daysBetween(today, event.startDate) > 0;
    return upcoming
        ? const StatusChip('UPCOMING', label: 'Upcoming')
        : const StatusChip('', label: 'Past');
  }
}
