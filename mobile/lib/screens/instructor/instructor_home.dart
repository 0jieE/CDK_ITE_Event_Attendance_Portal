import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../models/event.dart';
import '../../services/api_service.dart';
import '../../services/auth_provider.dart';
import '../../theme/app_theme.dart';
import '../../widgets/async_list_view.dart';
import '../../widgets/logout_action.dart';
import 'scanner_screen.dart';

/// Instructor interface: active scannable events + entry to the QR scanner.
class InstructorHome extends StatelessWidget {
  const InstructorHome({super.key});

  @override
  Widget build(BuildContext context) {
    final api = context.read<ApiService>();
    final name = context.watch<AuthProvider>().user?.fullName ?? '';
    return Scaffold(
      appBar: AppBar(
        title: const Text('Instructor'),
        actions: const [LogoutAction()],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const ScannerScreen()),
        ),
        backgroundColor: AppTheme.violet,
        icon: const Icon(Icons.qr_code_scanner),
        label: const Text('Scan QR'),
      ),
      body: AsyncListView<Event>(
        loader: api.instructorEvents,
        emptyIcon: Icons.event_busy,
        emptyMessage: 'No active events to scan right now.',
        header: Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            'Hello, $name',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        itemBuilder: (context, e) => _EventCard(event: e),
      ),
    );
  }
}

class _EventCard extends StatelessWidget {
  final Event event;
  const _EventCard({required this.event});

  @override
  Widget build(BuildContext context) {
    final df = DateFormat('MMM d');
    final dfy = DateFormat('MMM d, y');
    final range = event.startDate == event.endDate
        ? dfy.format(event.startDate)
        : '${df.format(event.startDate)} – ${dfy.format(event.endDate)}';
    return Card(
      child: ListTile(
        leading: const CircleAvatar(
          backgroundColor: Color(0xFFEDE7F4),
          child: Icon(Icons.event, color: AppTheme.violet),
        ),
        title: Text(event.name,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text('$range\n${event.semesterLabel}'),
        isThreeLine: true,
        trailing: const Chip(
          label: Text('Active'),
          backgroundColor: Color(0xFFE6F4EA),
          labelStyle: TextStyle(color: Color(0xFF198754), fontSize: 12),
          visualDensity: VisualDensity.compact,
        ),
      ),
    );
  }
}
