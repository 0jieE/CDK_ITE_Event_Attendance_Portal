import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../models/fine.dart';
import '../../services/api_service.dart';
import '../../utils/manila_time.dart';
import '../../widgets/async_view.dart';
import '../../widgets/balance_card.dart';
import '../../widgets/state_message.dart';
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
            BalanceCard(balance: data.balance, label: 'Outstanding'),
            const SizedBox(height: 16),
            if (data.fines.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: StateMessage(
                  icon: Icons.celebration_outlined,
                  title: 'No fines on record',
                  subtitle: 'Keep attending events on time!',
                ),
              )
            else
              for (final f in data.fines) ...[
                _FineCard(fine: f),
                const SizedBox(height: 10),
              ],
          ],
        );
      },
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
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        title: Text(fine.eventName,
            style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(
          '${fine.missedSlots} missed slot${fine.missedSlots == 1 ? '' : 's'}'
          '${fine.paidAt != null ? ' · Paid ${DateFormat('MMM d, y').format(toManila(fine.paidAt!))}' : ''}',
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text('₱${fine.amount}',
                style:
                    const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            const SizedBox(height: 4),
            StatusChip(fine.status),
          ],
        ),
      ),
    );
  }
}
