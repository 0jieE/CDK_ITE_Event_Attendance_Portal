import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../models/attendance_log.dart';
import '../../models/event.dart';
import '../../services/api_service.dart';
import '../../theme/app_theme.dart';
import '../../utils/attendance_groups.dart';
import '../../utils/errors.dart';
import '../../utils/event_dates.dart';
import '../../utils/manila_time.dart';
import '../../widgets/state_message.dart';
import '../../widgets/status_chip.dart';

/// The student's attendance history, filtered by event.
///
/// The filter lists every event (`?all=true`) and defaults to the one closest
/// to today (see [pickClosestEvent]); "All events" shows everything. Logs are
/// grouped by date, newest first.
class HistoryTab extends StatefulWidget {
  const HistoryTab({super.key});

  @override
  State<HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<HistoryTab> {
  List<Event> _events = const [];
  Event? _selected; // null = "All events"
  bool _loadingEvents = true;
  String? _eventsError;

  List<AttendanceLog>? _logs;
  bool _loadingLogs = false;
  String? _logsError;

  /// Ignores responses that belong to an older filter selection.
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _loadEvents();
  }

  /// Loads the event list and (re)selects: the current event if it still
  /// exists, else the default closest to today. [silent] = pull-to-refresh.
  Future<void> _loadEvents({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loadingEvents = true;
        _eventsError = null;
      });
    }
    try {
      final events = await context.read<ApiService>().studentEventsAll();
      if (!mounted) return;
      final keepAll = silent && _selected == null && _events.isNotEmpty;
      final keep = events.where((e) => e.id == _selected?.id).firstOrNull;
      setState(() {
        _events = events;
        _loadingEvents = false;
        _eventsError = null;
        _selected = keepAll
            ? null
            : (keep ?? pickClosestEvent(events, manilaToday()));
      });
      await _loadLogs(silent: silent);
    } on SessionExpired {
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _eventsError = friendlyError(e);
        _loadingEvents = false;
      });
    }
  }

  Future<void> _loadLogs({bool silent = false}) async {
    final seq = ++_seq;
    if (!silent) {
      setState(() {
        _loadingLogs = true;
        _logsError = null;
        _logs = null;
      });
    }
    try {
      final logs = await context
          .read<ApiService>()
          .studentAttendance(event: _selected?.id);
      if (!mounted || seq != _seq) return;
      setState(() {
        _logs = logs;
        _loadingLogs = false;
        _logsError = null;
      });
    } on SessionExpired {
      return;
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _logsError = friendlyError(e);
        _loadingLogs = false;
      });
    }
  }

  Future<void> _pickEvent() async {
    final choice = await showModalBottomSheet<_Choice>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _EventPicker(events: _events, selected: _selected),
    );
    if (choice == null || !mounted) return;
    setState(() => _selected = choice.event);
    _loadLogs();
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
        title: 'Could not load history',
        subtitle: _eventsError,
        actionLabel: 'Retry',
        onAction: _loadEvents,
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: _FilterButton(
            event: _selected,
            enabled: _events.isNotEmpty,
            onTap: _pickEvent,
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => _loadEvents(silent: true),
            child: _buildBody(),
          ),
        ),
      ],
    );
  }

  Widget _buildBody() {
    if (_loadingLogs) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_logsError != null) {
      return RefreshableCenter(
        child: StateMessage(
          icon: Icons.cloud_off,
          isError: true,
          title: 'Could not load attendance',
          subtitle: _logsError,
          actionLabel: 'Retry',
          onAction: _loadLogs,
        ),
      );
    }
    final logs = _logs ?? const <AttendanceLog>[];
    if (logs.isEmpty) {
      return RefreshableCenter(
        child: StateMessage(
          icon: Icons.history,
          title: _selected == null
              ? 'No attendance recorded yet'
              : 'No attendance recorded for this event yet',
          subtitle: 'Scans made by your instructor will show up here.',
        ),
      );
    }
    final groups = groupLogsByDate(logs);
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: groups.length,
      itemBuilder: (context, i) =>
          _DaySection(group: groups[i], showEvent: _selected == null),
    );
  }
}

/// Tappable "field" showing the selected event; opens the picker sheet.
class _FilterButton extends StatelessWidget {
  final Event? event;
  final bool enabled;
  final VoidCallback onTap;
  const _FilterButton({
    required this.event,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final brand = context.brand;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: brand.tint,
                child: Icon(Icons.filter_list, color: brand.accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Event',
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant)),
                    Text(event?.name ?? 'All events',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 16)),
                    if (event != null)
                      Text(_range(event!),
                          style: TextStyle(
                              fontSize: 12, color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
              Icon(Icons.keyboard_arrow_down, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
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

/// Result of the picker: [event] null means "All events".
class _Choice {
  final Event? event;
  const _Choice(this.event);
}

class _EventPicker extends StatelessWidget {
  final List<Event> events;
  final Event? selected;
  const _EventPicker({required this.events, required this.selected});

  @override
  Widget build(BuildContext context) {
    final today = manilaToday();
    final brand = context.brand;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.7;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('Filter by event',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w800)),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: 12),
                children: [
                  ListTile(
                    leading: Icon(Icons.all_inclusive, color: brand.accent),
                    title: const Text('All events',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    trailing: selected == null
                        ? Icon(Icons.check_circle, color: brand.accent)
                        : null,
                    onTap: () => Navigator.pop(context, const _Choice(null)),
                  ),
                  for (final e in events)
                    ListTile(
                      leading: Icon(Icons.event_outlined, color: brand.accent),
                      title: Text(e.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text(_range(e)),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _PhaseBadge(event: e, today: today),
                          if (selected?.id == e.id) ...[
                            const SizedBox(width: 8),
                            Icon(Icons.check_circle, color: brand.accent),
                          ],
                        ],
                      ),
                      onTap: () => Navigator.pop(context, _Choice(e)),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
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
    return StatusChip('', label: upcoming ? 'Upcoming' : 'Past');
  }
}

/// One date: a header plus a card with that day's slot rows.
class _DaySection extends StatelessWidget {
  final DayLogs group;
  final bool showEvent;
  const _DaySection({required this.group, required this.showEvent});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Text(
              DateFormat('EEEE, MMM d, y').format(group.date),
              style: TextStyle(
                  fontWeight: FontWeight.w700, color: scheme.onSurfaceVariant),
            ),
          ),
          Card(
            child: Column(
              children: [
                for (var i = 0; i < group.logs.length; i++) ...[
                  if (i > 0) const Divider(indent: 16, endIndent: 16),
                  _LogRow(log: group.logs[i], showEvent: showEvent),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LogRow extends StatelessWidget {
  final AttendanceLog log;
  final bool showEvent;
  const _LogRow({required this.log, required this.showEvent});

  @override
  Widget build(BuildContext context) {
    final scannedAt = log.scannedAt;
    final time = scannedAt != null
        ? DateFormat('h:mm a').format(toManila(scannedAt))
        : 'No scan recorded';
    final slot = log.attendanceTypeDisplay.isNotEmpty
        ? log.attendanceTypeDisplay
        : log.attendanceType;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      title: Text(slot, style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text(showEvent ? '${log.eventName}\n$time' : time),
      isThreeLine: showEvent,
      trailing: StatusChip(log.status),
    );
  }
}
