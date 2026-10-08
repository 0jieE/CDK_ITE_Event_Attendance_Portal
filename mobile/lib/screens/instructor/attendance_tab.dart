import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/event.dart';
import '../../services/api_service.dart';
import '../../theme/app_theme.dart';
import '../../utils/errors.dart';
import '../../utils/event_status.dart';
import '../../utils/manila_time.dart';
import '../../widgets/state_message.dart';
import '../../widgets/status_chip.dart';
import 'event_attendance_screen.dart';

/// "Attendance" tab: every event (ongoing, upcoming, finished) with a search
/// box. Tapping one opens its class roster ([EventAttendanceScreen]).
class AttendanceTab extends StatefulWidget {
  const AttendanceTab({super.key});

  @override
  State<AttendanceTab> createState() => _AttendanceTabState();
}

class _AttendanceTabState extends State<AttendanceTab> {
  final _search = TextEditingController();

  List<Event> _events = const []; // already in display order
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// [silent] = pull-to-refresh: keep showing the current list meanwhile.
  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final events = await context.read<ApiService>().instructorEventsAll();
      if (!mounted) return;
      setState(() {
        _events = sortEventsForAttendance(events, manilaToday());
        _loading = false;
        _error = null;
      });
    } on SessionExpired {
      return;
    } catch (e) {
      if (!mounted) return;
      if (silent && _events.isNotEmpty) {
        // Keep the list we already have; just say the refresh failed.
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(friendlyError(e))));
        return;
      }
      setState(() {
        _error = friendlyError(e);
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null && _events.isEmpty) {
      return RefreshIndicator(
        onRefresh: () => _load(silent: true),
        child: RefreshableCenter(
          child: StateMessage(
            icon: Icons.cloud_off,
            isError: true,
            title: 'Could not load events',
            subtitle: _error,
            actionLabel: 'Retry',
            onAction: _load,
          ),
        ),
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: TextField(
            controller: _search,
            textInputAction: TextInputAction.search,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: 'Search events',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear search',
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(_search.clear),
                    ),
            ),
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => _load(silent: true),
            child: _buildList(),
          ),
        ),
      ],
    );
  }

  Widget _buildList() {
    if (_events.isEmpty) {
      return const RefreshableCenter(
        child: StateMessage(
          icon: Icons.event_busy,
          title: 'No events yet',
          subtitle: 'Events created by the department will show up here.',
        ),
      );
    }
    final shown = filterEventsByName(_events, _search.text);
    if (shown.isEmpty) {
      return RefreshableCenter(
        child: StateMessage(
          icon: Icons.search_off,
          title: 'No events match "${_search.text.trim()}"',
        ),
      );
    }
    final today = manilaToday();
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: shown.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (context, i) =>
          _EventTile(event: shown[i], status: eventStatus(shown[i], today)),
    );
  }
}

class _EventTile extends StatelessWidget {
  final Event event;
  final EventStatus status;
  const _EventTile({required this.event, required this.status});

  @override
  Widget build(BuildContext context) {
    final brand = context.brand;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final sem = event.semesterLabel;
    return Card(
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => EventAttendanceScreen(event: event),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: brand.tint,
                child: Icon(Icons.event, color: brand.accent),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      event.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      sem.isEmpty
                          ? eventRangeLabel(event)
                          : '${eventRangeLabel(event)} · $sem',
                      style: TextStyle(color: muted, fontSize: 13),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _statusChip(status),
                  const SizedBox(height: 6),
                  Icon(Icons.chevron_right, color: muted),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static Widget _statusChip(EventStatus s) {
    switch (s) {
      case EventStatus.ongoing:
        return StatusChip('PRESENT', label: s.label);
      case EventStatus.upcoming:
        return StatusChip('LATE', label: s.label);
      case EventStatus.finished:
        return StatusChip('FINISHED', label: s.label);
    }
  }
}
