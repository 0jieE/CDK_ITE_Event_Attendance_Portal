import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../models/event.dart';
import '../../models/event_attendance.dart';
import '../../services/api_service.dart';
import '../../theme/app_theme.dart';
import '../../utils/attendance_filter.dart';
import '../../utils/errors.dart';
import '../../utils/event_dates.dart';
import '../../utils/event_status.dart';
import '../../utils/manila_time.dart';
import '../../widgets/profile_avatar.dart';
import '../../widgets/state_message.dart';

/// The class roster of one event: pick a day, see per-slot totals, then every
/// student's PRESENT / LATE / ABSENT / PENDING result for each required slot.
class EventAttendanceScreen extends StatefulWidget {
  final Event event;

  /// Time source (overridable in tests). "Today" and the Open / Not yet hint
  /// of a slot are derived from it in Manila time.
  final DateTime Function()? clock;

  const EventAttendanceScreen({super.key, required this.event, this.clock});

  @override
  State<EventAttendanceScreen> createState() => _EventAttendanceScreenState();
}

class _EventAttendanceScreenState extends State<EventAttendanceScreen> {
  final _search = TextEditingController();

  EventAttendance? _data;

  /// The day the user picked; null until a response (the server then picks the
  /// default day) arrives.
  DateTime? _selected;
  bool _loading = true;
  String? _error;
  int _seq = 0; // drops responses that belong to an older day selection

  AttendanceFilter _filter = AttendanceFilter.all;
  List<StudentAttendance> _visible = const [];
  Map<AttendanceFilter, int> _counts = const {};

  DateTime get _now => (widget.clock ?? DateTime.now)();
  DateTime get _today => manilaToday(_now);

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

  void _recompute() {
    final data = _data;
    if (data == null) return;
    _visible = filterStudents(data, filter: _filter, query: _search.text);
    _counts = filterCounts(data);
  }

  /// [silent] = pull-to-refresh: the current content stays until the new one
  /// arrives (and is kept if the refresh fails).
  Future<void> _load({bool silent = false}) async {
    final seq = ++_seq;
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final data = await context.read<ApiService>().instructorEventAttendance(
        widget.event.id,
        date: _selected,
      );
      if (!mounted || seq != _seq) return;
      setState(() {
        _data = data;
        _selected = dateOnly(data.date);
        _loading = false;
        _error = null;
        _recompute();
      });
    } on SessionExpired {
      return;
    } catch (e) {
      if (!mounted || seq != _seq) return;
      if (silent && _data != null && _error == null) {
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

  void _selectDate(DateTime day) {
    final current = _selected;
    if (current != null && daysBetween(current, day) == 0 && _error == null) {
      return;
    }
    _selected = dateOnly(day);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final event = widget.event;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final dates = _data?.selectableDates ?? event.dateRange;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 64,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(event.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(
              eventRangeLabel(event),
              style: TextStyle(
                color: muted,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          _DateSelector(
            dates: dates,
            selected: _selected,
            today: _today,
            onSelect: _selectDate,
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => _load(silent: true),
              child: _buildBody(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    final data = _data;
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null || data == null) {
      return RefreshableCenter(
        child: StateMessage(
          icon: Icons.cloud_off,
          isError: true,
          title: 'Could not load attendance',
          subtitle: _error,
          actionLabel: 'Retry',
          onAction: _load,
        ),
      );
    }

    final upcoming =
        dayAvailability(data.date, _today) == DayAvailability.upcoming;
    final nowManila = toManila(_now);
    final headline = attendanceHeadline(data);
    final filtered =
        _filter != AttendanceFilter.all || _search.text.trim().isNotEmpty;

    final header = <Widget>[
      if (data.slots.isNotEmpty) _SummaryRow(data: data, nowManila: nowManila),
      if (upcoming)
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: InlineBanner(
            isError: false,
            icon: Icons.schedule,
            message:
                "This day hasn't started yet. Everyone shows as Pending "
                'until the scan windows open.',
          ),
        ),
      _SearchAndFilters(
        controller: _search,
        filter: _filter,
        counts: _counts,
        onQuery: () => setState(_recompute),
        onFilter: (f) => setState(() {
          _filter = f;
          _recompute();
        }),
      ),
      if (headline != null || filtered)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  headline ?? '${data.students.length} students',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
              ),
              if (filtered)
                Text(
                  'Showing ${_visible.length} of ${data.students.length}',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
            ],
          ),
        ),
    ];

    final rows = _visible;
    final emptyMessage = data.students.isEmpty
        ? const StateMessage(
            icon: Icons.groups_outlined,
            title: 'No students to show',
            subtitle: 'No approved students are on this class list yet.',
          )
        : const StateMessage(
            icon: Icons.search_off,
            title: 'No students match',
            subtitle: 'Try a different name, number or filter.',
          );

    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: header.length + (rows.isEmpty ? 1 : rows.length),
      itemBuilder: (context, i) {
        if (i < header.length) return header[i];
        if (rows.isEmpty) return emptyMessage;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: _StudentRow(student: rows[i - header.length]),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Date selector
// ---------------------------------------------------------------------------
class _DateSelector extends StatefulWidget {
  final List<DateTime> dates;
  final DateTime? selected;
  final DateTime today;
  final ValueChanged<DateTime> onSelect;

  const _DateSelector({
    required this.dates,
    required this.selected,
    required this.today,
    required this.onSelect,
  });

  @override
  State<_DateSelector> createState() => _DateSelectorState();
}

class _DateSelectorState extends State<_DateSelector> {
  static const _itemWidth = 60.0;
  static const _gap = 8.0;
  static const _pad = 16.0;

  final _controller = ScrollController();

  @override
  void initState() {
    super.initState();
    _scheduleReveal();
  }

  @override
  void didUpdateWidget(_DateSelector old) {
    super.didUpdateWidget(old);
    final a = old.selected, b = widget.selected;
    if ((a == null) != (b == null) || (a != null && daysBetween(a, b!) != 0)) {
      _scheduleReveal();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Scrolls the selected day into the middle of the strip.
  void _scheduleReveal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final sel = widget.selected;
      if (!mounted || sel == null || !_controller.hasClients) return;
      final i = widget.dates.indexWhere((d) => daysBetween(d, sel) == 0);
      if (i < 0) return;
      final pos = _controller.position;
      final centre = _pad + i * (_itemWidth + _gap) + _itemWidth / 2;
      final target = (centre - pos.viewportDimension / 2).clamp(
        0.0,
        pos.maxScrollExtent,
      );
      _controller.animateTo(
        target,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final brand = context.brand;
    return Container(
      height: 92,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(bottom: BorderSide(color: brand.border)),
      ),
      child: ListView.separated(
        controller: _controller,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: _pad, vertical: 8),
        itemCount: widget.dates.length,
        separatorBuilder: (_, _) => const SizedBox(width: _gap),
        itemBuilder: (context, i) {
          final day = widget.dates[i];
          final sel = widget.selected;
          return _DayChip(
            day: day,
            width: _itemWidth,
            selected: sel != null && daysBetween(day, sel) == 0,
            isToday: daysBetween(day, widget.today) == 0,
            onTap: () => widget.onSelect(day),
          );
        },
      ),
    );
  }
}

class _DayChip extends StatelessWidget {
  final DateTime day;
  final double width;
  final bool selected;
  final bool isToday;
  final VoidCallback onTap;

  const _DayChip({
    required this.day,
    required this.width,
    required this.selected,
    required this.isToday,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final brand = context.brand;
    final fg = selected
        ? AppTheme.onGreen
        : Theme.of(context).colorScheme.onSurface;
    final sub = selected ? AppTheme.onGreen : brand.muted;
    return Semantics(
      button: true,
      selected: selected,
      label:
          DateFormat('EEEE, MMMM d').format(day) + (isToday ? ', today' : ''),
      child: Material(
        color: selected ? AppTheme.green : brand.tint,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Container(
            width: width,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: isToday
                  ? Border.all(color: brand.accent, width: 2)
                  : null,
            ),
            // Scales down instead of overflowing when the phone's text size
            // is turned up.
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      isToday ? 'Today' : DateFormat('EEE').format(day),
                      style: TextStyle(
                        color: sub,
                        fontSize: 11,
                        height: 1.2,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      '${day.day}',
                      style: TextStyle(
                        color: fg,
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        height: 1.15,
                      ),
                    ),
                    Text(
                      DateFormat('MMM').format(day),
                      style: TextStyle(color: sub, fontSize: 11, height: 1.2),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Slot summary
// ---------------------------------------------------------------------------
class _SummaryRow extends StatelessWidget {
  final EventAttendance data;
  final DateTime nowManila;
  const _SummaryRow({required this.data, required this.nowManila});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final slot in data.slots) ...[
            _SlotCard(
              slot: slot,
              total: slotTotal(data, slot),
              phase: slotPhase(
                slot,
                isToday: data.isToday,
                nowManila: nowManila,
              ),
            ),
            const SizedBox(width: 10),
          ],
        ],
      ),
    );
  }
}

class _SlotCard extends StatelessWidget {
  final SlotSummary slot;
  final int total;
  final SlotPhase phase;
  const _SlotCard({
    required this.slot,
    required this.total,
    required this.phase,
  });

  @override
  Widget build(BuildContext context) {
    final brand = context.brand;
    final muted = brand.muted;
    final closed = phase == SlotPhase.closed;
    final window = (slot.windowStart != null && slot.windowEnd != null)
        ? '${formatClock(slot.windowStart)} – ${formatClock(slot.windowEnd)}'
        : '';
    final value = total == 0 ? 0.0 : (slot.present / total).clamp(0.0, 1.0);
    return Opacity(
      // Not closed yet: the numbers are still moving, so dim the card.
      opacity: closed ? 1 : 0.6,
      child: SizedBox(
        width: 168,
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        slot.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    if (!closed) _PhaseTag(phase: phase),
                  ],
                ),
                if (window.isNotEmpty)
                  Text(window, style: TextStyle(color: muted, fontSize: 12)),
                const SizedBox(height: 8),
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '${slot.present}',
                        style: TextStyle(
                          color: brand.presentFg,
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      TextSpan(
                        text: ' present',
                        style: TextStyle(color: muted, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${slot.absent} absent · ${slot.pending} pending',
                  style: TextStyle(color: muted, fontSize: 12),
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: value,
                    minHeight: 6,
                    color: AppTheme.green,
                    backgroundColor: brand.neutralBg,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PhaseTag extends StatelessWidget {
  final SlotPhase phase;
  const _PhaseTag({required this.phase});

  @override
  Widget build(BuildContext context) {
    final brand = context.brand;
    final open = phase == SlotPhase.open;
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: open ? brand.presentBg : brand.neutralBg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        open ? 'Open' : 'Not yet',
        style: TextStyle(
          color: open ? brand.presentFg : brand.neutralFg,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Search + filter chips
// ---------------------------------------------------------------------------
class _SearchAndFilters extends StatelessWidget {
  final TextEditingController controller;
  final AttendanceFilter filter;
  final Map<AttendanceFilter, int> counts;
  final VoidCallback onQuery;
  final ValueChanged<AttendanceFilter> onFilter;

  const _SearchAndFilters({
    required this.controller,
    required this.filter,
    required this.counts,
    required this.onQuery,
    required this.onFilter,
  });

  static const _labels = {
    AttendanceFilter.all: 'All',
    AttendanceFilter.missing: 'Missing',
    AttendanceFilter.complete: 'Complete',
  };

  @override
  Widget build(BuildContext context) {
    final brand = context.brand;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: controller,
            textInputAction: TextInputAction.search,
            onChanged: (_) => onQuery(),
            decoration: InputDecoration(
              hintText: 'Search name or student number',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: controller.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear search',
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        controller.clear();
                        onQuery();
                      },
                    ),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final f in AttendanceFilter.values)
                ChoiceChip(
                  label: Text('${_labels[f]} ${counts[f] ?? 0}'),
                  selected: filter == f,
                  showCheckmark: false,
                  selectedColor: AppTheme.green,
                  backgroundColor: brand.tint,
                  labelStyle: TextStyle(
                    color: filter == f
                        ? AppTheme.onGreen
                        : AppTheme.greenTintInk,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                  onSelected: (_) => onFilter(f),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Student rows
// ---------------------------------------------------------------------------
class _StudentRow extends StatelessWidget {
  final StudentAttendance student;
  const _StudentRow({required this.student});

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final info = [
      if (student.studentNumber.isNotEmpty) student.studentNumber,
      if (student.yearSection.isNotEmpty) student.yearSection,
    ].join(' · ');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ProfileAvatar(
              imageUrl: student.photo,
              name: student.fullName,
              radius: 22,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    student.fullName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                  if (info.isNotEmpty)
                    Text(
                      info,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: muted, fontSize: 12.5),
                    ),
                  if (student.slots.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final cell in student.slots) _SlotPill(cell: cell),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Soft status pill for one slot: green Present, amber Late, red Absent,
/// grey Pending. The status word / scan time keeps it readable without colour.
class _SlotPill extends StatelessWidget {
  final SlotCell cell;
  const _SlotPill({required this.cell});

  @override
  Widget build(BuildContext context) {
    final c = context.brand.badge(cell.status.code);
    final at = cell.scannedAt;
    final String text;
    final IconData icon;
    switch (cell.status) {
      case SlotStatus.present:
        text = at != null ? formatScanTime(at) : 'Present';
        icon = Icons.check_circle;
      case SlotStatus.late:
        text = at != null ? '${formatScanTime(at)} · Late' : 'Late';
        icon = Icons.watch_later;
      case SlotStatus.absent:
        text = 'Absent';
        icon = Icons.cancel;
      case SlotStatus.pending:
        text = 'Pending';
        icon = Icons.hourglass_empty;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: c.bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: c.fg),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              '${shortSlotLabel(cell.type)} · $text',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: c.fg,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                height: 1.2,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
