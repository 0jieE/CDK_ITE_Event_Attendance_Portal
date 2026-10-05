import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../models/attendance_log.dart';
import '../../services/api_service.dart';
import '../../widgets/async_list_view.dart';
import '../../widgets/status_chip.dart';

/// The student's attendance history.
class HistoryTab extends StatelessWidget {
  const HistoryTab({super.key});

  @override
  Widget build(BuildContext context) {
    final api = context.read<ApiService>();
    return AsyncListView<AttendanceLog>(
      loader: () => api.studentAttendance(),
      emptyIcon: Icons.history,
      emptyMessage: 'No attendance records yet.',
      itemBuilder: (context, log) => Card(
        child: ListTile(
          title: Text(log.attendanceTypeDisplay,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(
            '${log.eventName}\n${DateFormat('EEE, MMM d, y').format(log.date)}'
            '${log.scannedAt != null ? ' · ${DateFormat('h:mm a').format(log.scannedAt!)}' : ''}',
          ),
          isThreeLine: true,
          trailing: StatusChip(log.status),
        ),
      ),
    );
  }
}
