import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../models/event.dart';
import '../../services/api_service.dart';
import '../../theme/app_theme.dart';
import 'qr_display_screen.dart';

/// Pick an event -> date (within range) -> generate the **daily** QR.
/// The slot is decided automatically when the instructor scans, based on the
/// event's scan-time windows (shown here for reference).
class GenerateQrTab extends StatefulWidget {
  const GenerateQrTab({super.key});

  @override
  State<GenerateQrTab> createState() => _GenerateQrTabState();
}

class _GenerateQrTabState extends State<GenerateQrTab> {
  late Future<List<Event>> _eventsFuture;
  Event? _event;
  DateTime? _date;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _eventsFuture = context.read<ApiService>().studentEvents();
  }

  void _reload() {
    setState(() {
      _eventsFuture = context.read<ApiService>().studentEvents();
      _event = null;
      _date = null;
      _error = null;
    });
  }

  Future<void> _generate() async {
    if (_event == null || _date == null) {
      setState(() => _error = 'Please select an event and date.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final slot = await context.read<ApiService>().generateQr(
            event: _event!.id,
            date: DateFormat('yyyy-MM-dd').format(_date!),
          );
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => QrDisplayScreen(slot: slot, event: _event!),
        ),
      );
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = 'Could not reach the server. Please try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Event>>(
      future: _eventsFuture,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return _Message(
            icon: Icons.cloud_off,
            text: '${snap.error}',
            actionLabel: 'Retry',
            onAction: _reload,
          );
        }
        final events = snap.data ?? const [];
        if (events.isEmpty) {
          return _Message(
            icon: Icons.event_busy,
            text: 'No active events to generate a QR for.',
            actionLabel: 'Refresh',
            onAction: _reload,
          );
        }
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'Generate your daily attendance QR, then show it to the instructor. '
              'One QR covers the whole day — the instructor scans it within each '
              "slot's time window.",
              style: TextStyle(color: Colors.black54),
            ),
            const SizedBox(height: 20),
            DropdownButtonFormField<Event>(
              initialValue: _event,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Event'),
              items: events
                  .map((e) => DropdownMenuItem(value: e, child: Text(e.name)))
                  .toList(),
              onChanged: (e) => setState(() {
                _event = e;
                _date = null;
                _error = null;
              }),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<DateTime>(
              initialValue: _date,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Date'),
              items: (_event?.dateRange ?? [])
                  .map((d) => DropdownMenuItem(
                        value: d,
                        child: Text(DateFormat('EEE, MMM d, y').format(d)),
                      ))
                  .toList(),
              onChanged:
                  _event == null ? null : (d) => setState(() => _date = d),
            ),
            if (_event != null && _event!.schedule.isNotEmpty) ...[
              const SizedBox(height: 16),
              _ScheduleCard(event: _event!),
            ],
            if (_error != null) ...[
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFFDE7E9),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(_error!,
                    style: const TextStyle(color: Color(0xFFB02A37))),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _busy ? null : _generate,
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.qr_code_2),
              label: Text(_busy ? 'Generating…' : 'Generate QR'),
            ),
          ],
        );
      },
    );
  }
}

/// Shows the event's per-slot scan windows.
class _ScheduleCard extends StatelessWidget {
  final Event event;
  const _ScheduleCard({required this.event});

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFFEDE7F4),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: const [
                Icon(Icons.schedule, size: 18, color: AppTheme.violet),
                SizedBox(width: 6),
                Text('Scan windows',
                    style: TextStyle(
                        fontWeight: FontWeight.w600, color: AppTheme.violet)),
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
                        style: const TextStyle(fontWeight: FontWeight.w500)),
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

class _Message extends StatelessWidget {
  final IconData icon;
  final String text;
  final String actionLabel;
  final VoidCallback onAction;
  const _Message({
    required this.icon,
    required this.text,
    required this.actionLabel,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: Colors.black26),
            const SizedBox(height: 12),
            Text(text,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.black54)),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: onAction, child: Text(actionLabel)),
          ],
        ),
      ),
    );
  }
}
