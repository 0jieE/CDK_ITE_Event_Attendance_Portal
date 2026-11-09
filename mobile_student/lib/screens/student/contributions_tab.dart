import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../models/contribution.dart';
import '../../models/fine.dart';
import '../../services/api_service.dart';
import '../../theme/app_theme.dart';
import '../../utils/manila_time.dart';
import '../../widgets/async_view.dart';
import '../../widgets/balance_card.dart';
import '../../widgets/state_message.dart';
import '../../widgets/status_chip.dart';

typedef _ContributionsData = ({
  Balance balance,
  List<Contribution> contributions,
});

/// The student's department contributions, grouped by semester (newest
/// first). Tapping one drops down what's owed, paid and left, plus every
/// recorded payment. Read-only: the adviser records the cash payments.
class ContributionsTab extends StatelessWidget {
  const ContributionsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final api = context.read<ApiService>();

    Future<_ContributionsData> load() async {
      final results = await Future.wait<Object>(
          [api.studentBalance(), api.studentContributions()]);
      return (
        balance: results[0] as Balance,
        contributions: (results[1] as List).cast<Contribution>(),
      );
    }

    return AsyncView<_ContributionsData>(
      loader: load,
      builder: (context, data, _) {
        final items = data.contributions;
        return ListView(
          padding: const EdgeInsets.all(16),
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            BalanceCard.contributions(balance: data.balance),
            if (items.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: StateMessage(
                  icon: Icons.volunteer_activism_outlined,
                  title: 'No contributions yet',
                  subtitle: 'Department contributions will show up here.',
                ),
              )
            else
              for (var i = 0; i < items.length; i++) ...[
                if (i == 0 || items[i].semester != items[i - 1].semester)
                  _SemesterHeader(contribution: items[i]),
                _ContributionCard(
                    key: ValueKey(items[i].id), contribution: items[i]),
                const SizedBox(height: 10),
              ],
          ],
        );
      },
    );
  }
}

class _SemesterHeader extends StatelessWidget {
  final Contribution contribution;
  const _SemesterHeader({required this.contribution});

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
      child: Row(
        children: [
          Flexible(
            child: Text(contribution.semesterName,
                style: TextStyle(fontWeight: FontWeight.w700, color: muted)),
          ),
          if (contribution.isActiveSemester) ...[
            const SizedBox(width: 8),
            const StatusChip('PRESENT', label: 'Current'),
          ],
        ],
      ),
    );
  }
}

class _ContributionCard extends StatelessWidget {
  final Contribution contribution;
  const _ContributionCard({super.key, required this.contribution});

  @override
  Widget build(BuildContext context) {
    final c = contribution;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final due = c.dueDate;
    final label = c.statusDisplay.isNotEmpty
        ? c.statusDisplay
        : StatusChip.titleCase(c.status);
    return Card(
      child: ExpansionTile(
        shape: const Border(),
        collapsedShape: const Border(),
        tilePadding: const EdgeInsets.fromLTRB(16, 6, 12, 6),
        childrenPadding: const EdgeInsets.only(bottom: 8),
        title: Text(c.name, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(c.exempt
            ? 'Exempt${c.exemptionReason.isNotEmpty ? ' · ${c.exemptionReason}' : ''}'
            : due != null
                ? 'Due ${DateFormat('MMM d, y').format(due)}'
                : 'No due date'),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('₱${c.exempt ? c.owed : c.balance}',
                    style: const TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 16)),
                const SizedBox(height: 4),
                StatusChip(c.status, label: label),
              ],
            ),
            const SizedBox(width: 4),
            Icon(Icons.expand_more, color: muted),
          ],
        ),
        children: [
          const Divider(indent: 16, endIndent: 16),
          if (c.description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(c.description, style: TextStyle(color: muted)),
            ),
          _AmountRow('Amount', '₱${c.amount}'),
          if (c.exempt)
            _AmountRow('You owe', '₱${c.owed}',
                note: c.exemptionReason.isNotEmpty
                    ? 'Exempt: ${c.exemptionReason}'
                    : 'Exempt'),
          if (!c.exempt) ...[
            _AmountRow('Paid', '₱${c.paid}'),
            _AmountRow('Balance', '₱${c.balance}', bold: true),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
                c.payments.isEmpty
                    ? 'Payments'
                    : 'Payments (${c.payments.length})',
                style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w700, color: muted)),
          ),
          if (c.payments.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text('No payments recorded yet.',
                  style: TextStyle(color: muted)),
            )
          else
            for (final p in c.payments) _PaymentRow(payment: p),
        ],
      ),
    );
  }
}

class _AmountRow extends StatelessWidget {
  final String label;
  final String value;
  final String? note;
  final bool bold;
  const _AmountRow(this.label, this.value, {this.note, this.bold = false});

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(note == null ? label : '$label ($note)',
                style: TextStyle(color: muted)),
          ),
          Text(value,
              style: TextStyle(
                  fontWeight: bold ? FontWeight.w800 : FontWeight.w600)),
        ],
      ),
    );
  }
}

class _PaymentRow extends StatelessWidget {
  final ContributionPayment payment;
  const _PaymentRow({required this.payment});

  @override
  Widget build(BuildContext context) {
    final at = payment.paidAt;
    final when = at == null
        ? 'Date not recorded'
        : DateFormat('MMM d, y · h:mm a').format(toManila(at));
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      leading: Icon(Icons.payments_outlined, color: context.brand.presentFg),
      title: Text('₱${payment.amount}',
          style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text(payment.note.isEmpty ? when : '$when\n${payment.note}'),
      isThreeLine: payment.note.isNotEmpty,
    );
  }
}
