import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../models/event.dart';
import '../../services/api_service.dart';
import '../../services/auth_provider.dart';
import '../../services/connectivity_service.dart';
import '../../services/offline_scan_service.dart';
import '../../theme/app_theme.dart';
import '../../utils/event_status.dart';
import '../../utils/manila_time.dart';
import '../../widgets/async_list_view.dart';
import '../../widgets/status_chip.dart';
import 'scanner_screen.dart';

/// "Scan" tab: today's scannable events + the entry to the QR scanner.
///
/// Loading the events also downloads the offline pack, so the instructor can
/// keep scanning if the connection drops; offline it shows the downloaded
/// events and the scans waiting to sync.
class ScanTab extends StatelessWidget {
  const ScanTab({super.key});

  @override
  Widget build(BuildContext context) {
    final api = context.read<ApiService>();
    final offline = context.read<OfflineScanService?>();
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
        loader: offline?.loadEvents ?? api.instructorEvents,
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
              if (offline != null) const OfflineSyncCard(),
            ],
          ),
        ),
        itemBuilder: (context, e) => _EventCard(event: e),
      ),
    );
  }
}

/// Offline status: scans waiting on the phone, sync progress and the last
/// sync's outcome (with any scans the server refused). Hidden when there is
/// nothing to say.
class OfflineSyncCard extends StatelessWidget {
  const OfflineSyncCard({super.key});

  @override
  Widget build(BuildContext context) {
    final offline = context.watch<OfflineScanService>();
    final online = context.watch<ConnectivityService?>()?.isOnline ?? true;
    final pending = offline.pendingCount;
    final report = offline.lastSync;
    final pack = offline.pack;
    if (online && pending == 0 && report == null && offline.syncError == null) {
      return const SizedBox.shrink();
    }
    final brand = context.brand;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final time = DateFormat('MMM d, h:mm a');

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Card(
        color: brand.tint,
        elevation: 0,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(online ? Icons.cloud_done : Icons.cloud_off,
                      size: 20, color: brand.accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      pending > 0
                          ? '$pending scan${pending == 1 ? '' : 's'} saved on this phone'
                          : online
                              ? 'All scans are synced'
                              : 'Offline: scans are saved on this phone',
                      style: TextStyle(
                          fontWeight: FontWeight.w700, color: brand.accent),
                    ),
                  ),
                  if (offline.syncing)
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else if (pending > 0)
                    TextButton.icon(
                      onPressed: offline.sync,
                      icon: const Icon(Icons.sync, size: 18),
                      label: const Text('Sync now'),
                    ),
                ],
              ),
              if (!online)
                Text(
                  pack == null
                      ? "Scans are kept and sent automatically when you're back "
                          'online. Student names show only for QR codes '
                          'downloaded while online.'
                      : "Scans are kept and sent automatically when you're back "
                          'online. Student list downloaded '
                          '${time.format(toManila(pack.receivedAt))}.',
                  style: TextStyle(color: muted, fontSize: 13),
                ),
              if (offline.syncError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(offline.syncError!,
                      style: TextStyle(color: brand.absentFg, fontSize: 13)),
                ),
              if (report != null) ...[
                const SizedBox(height: 4),
                Text(
                  'Last sync: ${report.recorded} recorded, '
                  '${report.alreadyRecorded} already recorded, '
                  '${report.rejected.length} rejected.',
                  style: TextStyle(color: muted, fontSize: 13),
                ),
                for (final r in report.rejected)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '• ${r.label}, ${time.format(toManila(r.scannedAt))}: ${r.reason}',
                      style: TextStyle(color: brand.absentFg, fontSize: 13),
                    ),
                  ),
              ],
            ],
          ),
        ),
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
