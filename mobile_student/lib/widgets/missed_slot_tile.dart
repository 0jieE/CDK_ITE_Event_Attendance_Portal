import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/missed_slot.dart';
import '../theme/app_theme.dart';
import 'status_chip.dart';

/// One missed slot: which slot, which day, when its scan window was, and its
/// fine with Paid/Unpaid. Used by the History and Fines dropdowns.
class MissedSlotTile extends StatelessWidget {
  final MissedSlot slot;
  const MissedSlotTile({super.key, required this.slot});

  @override
  Widget build(BuildContext context) {
    final brand = context.brand;
    final label = slot.attendanceTypeDisplay.isNotEmpty
        ? slot.attendanceTypeDisplay
        : slot.attendanceType;
    final day = DateFormat('EEE, MMM d, y').format(slot.date);
    final start = slot.windowStart, end = slot.windowEnd;
    final window = start != null && end != null
        ? 'Scan window ${clockLabel(start)} – ${clockLabel(end)}'
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

/// "07:00:00" -> "7:00 AM".
String clockLabel(String raw) {
  final p = raw.split(':').map(int.tryParse).toList();
  if (p.length < 2 || p[0] == null || p[1] == null) return raw;
  return DateFormat('h:mm a').format(DateTime(2000, 1, 1, p[0]!, p[1]!));
}
