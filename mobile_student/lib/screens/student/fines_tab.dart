import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../models/fine.dart';
import '../../models/missed_slot.dart';
import '../../services/api_service.dart';
import '../../utils/manila_time.dart';
import '../../widgets/async_view.dart';
import '../../widgets/balance_card.dart';
import '../../widgets/missed_slot_tile.dart';
import '../../widgets/state_message.dart';
import '../../widgets/status_chip.dart';

/// [missed] (per event id) is null when the missed slots couldn't be loaded.
typedef _FinesData = ({
  Balance balance,
  List<Fine> fines,
  Map<int, List<MissedSlot>>? missed,
});

/// The student's fines, with an outstanding-balance summary header. Tapping a
/// fine drops down the missed slots behind it (day, slot, scan window, rate).
class FinesTab extends StatelessWidget {
  const FinesTab({super.key});

  @override
  Widget build(BuildContext context) {
    final api = context.read<ApiService>();

    Future<_FinesData> load() async {
      // Missed slots are optional: a failure there must not hide the fines.
      final missedF = api.studentMissedSlots().then<List<MissedSlot>?>(
        (v) => v,
        onError: (Object e) {
          if (e is SessionExpired) throw e;
          return null;
        },
      );
      final results = await Future.wait<Object?>(
          [api.studentBalance(), api.studentFines(), missedF]);
      final missed = results[2] as List<MissedSlot>?;
      Map<int, List<MissedSlot>>? byEvent;
      if (missed != null) {
        byEvent = {};
        for (final m in missed) {
          byEvent.putIfAbsent(m.event, () => []).add(m);
        }
      }
      return (
        balance: results[0] as Balance,
        fines: (results[1] as List).cast<Fine>(),
        missed: byEvent,
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
                _FineCard(
                  key: ValueKey(f.id),
                  fine: f,
                  missed: data.missed == null
                      ? null
                      : (data.missed![f.event] ?? const []),
                ),
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
  final List<MissedSlot>? missed;
  const _FineCard({super.key, required this.fine, required this.missed});

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Card(
      child: ExpansionTile(
        shape: const Border(),
        collapsedShape: const Border(),
        tilePadding: const EdgeInsets.fromLTRB(16, 6, 12, 6),
        childrenPadding: const EdgeInsets.only(bottom: 8),
        title: Text(fine.eventName,
            style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(
          '${fine.missedSlots} missed slot${fine.missedSlots == 1 ? '' : 's'}'
          '${fine.paidAt != null ? ' · Paid ${DateFormat('MMM d, y').format(toManila(fine.paidAt!))}' : ''}',
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('₱${fine.amount}',
                    style: const TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 16)),
                const SizedBox(height: 4),
                StatusChip(fine.status),
              ],
            ),
            const SizedBox(width: 4),
            Icon(Icons.expand_more, color: muted),
          ],
        ),
        children: [
          const Divider(indent: 16, endIndent: 16),
          if (missed == null)
            _note(context, "Missed slots couldn't be loaded. Pull down to refresh.")
          else if (missed!.isEmpty)
            _note(context, 'No missed slots listed for this event.')
          else
            for (final m in missed!) MissedSlotTile(slot: m),
        ],
      ),
    );
  }

  Widget _note(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Text(text,
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );
}
