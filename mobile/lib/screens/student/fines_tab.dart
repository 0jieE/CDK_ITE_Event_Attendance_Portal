import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../models/fine.dart';
import '../../services/api_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/async_view.dart';
import '../../widgets/status_chip.dart';

typedef _FinesData = ({Balance balance, List<Fine> fines});

/// The student's fines, with an outstanding-balance summary header.
class FinesTab extends StatelessWidget {
  const FinesTab({super.key});

  @override
  Widget build(BuildContext context) {
    final api = context.read<ApiService>();

    Future<_FinesData> load() async {
      final results = await Future.wait([api.studentBalance(), api.studentFines()]);
      return (
        balance: results[0] as Balance,
        fines: (results[1] as List).cast<Fine>(),
      );
    }

    return AsyncView<_FinesData>(
      loader: load,
      builder: (context, data, _) {
        return ListView(
          padding: const EdgeInsets.all(16),
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            _BalanceSummary(balance: data.balance),
            const SizedBox(height: 16),
            if (data.fines.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(
                  child: Column(
                    children: [
                      Icon(Icons.celebration_outlined,
                          size: 56, color: Colors.black26),
                      SizedBox(height: 12),
                      Text('No fines on record.',
                          style: TextStyle(color: Colors.black54)),
                    ],
                  ),
                ),
              )
            else
              ...data.fines.map((f) => _FineCard(fine: f)),
          ],
        );
      },
    );
  }
}

class _BalanceSummary extends StatelessWidget {
  final Balance balance;
  const _BalanceSummary({required this.balance});

  @override
  Widget build(BuildContext context) {
    final outstanding = double.tryParse(balance.outstanding) ?? 0;
    return Card(
      color: outstanding <= 0 ? const Color(0xFF198754) : AppTheme.violet,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Outstanding',
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.85), fontSize: 14)),
            const SizedBox(height: 6),
            Text('₱${balance.outstanding}',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 32,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Total: ₱${balance.totalFines}',
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.85))),
                Text('Paid: ₱${balance.totalPaid}',
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.85))),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _FineCard extends StatelessWidget {
  final Fine fine;
  const _FineCard({required this.fine});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        title: Text(fine.eventName,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(
          '${fine.missedSlots} missed slot${fine.missedSlots == 1 ? '' : 's'}'
          '${fine.paidAt != null ? ' · Paid ${DateFormat('MMM d, y').format(fine.paidAt!)}' : ''}',
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text('₱${fine.amount}',
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 4),
            StatusChip(fine.status),
          ],
        ),
      ),
    );
  }
}
