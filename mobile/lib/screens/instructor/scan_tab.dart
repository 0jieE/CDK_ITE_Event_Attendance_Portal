import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/event.dart';
import '../../services/api_service.dart';
import '../../services/auth_provider.dart';
import '../../theme/app_theme.dart';
import '../../utils/event_status.dart';
import '../../widgets/async_list_view.dart';
import '../../widgets/status_chip.dart';
import 'scanner_screen.dart';

/// "Scan" tab: today's scannable events + the entry to the QR scanner.
class ScanTab extends StatelessWidget {
  const ScanTab({super.key});

  @override
  Widget build(BuildContext context) {
    final api = context.read<ApiService>();
    final name = context.watch<AuthProvider>().user?.fullName ?? '';
    // Own Scaffold so the scan button floats over this tab only.
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const ScannerScreen())),
        icon: const Icon(Icons.qr_code_scanner),
        label: const Text('Scan QR'),
      ),
      body: AsyncListView<Event>(
        loader: api.instructorEvents,
        emptyIcon: Icons.event_busy,
        emptyMessage: 'No active events to scan right now.',
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        header: Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Hello, $name',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 2),
              Text(
                'Active events you can scan for',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
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
    final brand = context.brand;
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        leading: CircleAvatar(
          backgroundColor: brand.tint,
          child: Icon(Icons.event, color: brand.accent),
        ),
        title: Text(
          event.name,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text('${eventRangeLabel(event)}\n${event.semesterLabel}'),
        isThreeLine: true,
        trailing: const StatusChip('PRESENT', label: 'Active'),
      ),
    );
  }
}
