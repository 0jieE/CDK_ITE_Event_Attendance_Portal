import 'package:flutter/material.dart';

import '../models/fine.dart';
import '../theme/app_theme.dart';

/// Outstanding-balance hero card. Cleared balance = brand green with dark ink
/// text (white on #41B422 is too faint); an unpaid balance = dark ink card.
///
/// [BalanceCard.new] shows everything owed (fines + contributions) with the
/// split; [BalanceCard.fines] / [BalanceCard.contributions] show one part.
class BalanceCard extends StatelessWidget {
  final String label;
  final String outstanding;
  final String clearedText;
  final String left;
  final String right;

  BalanceCard({
    super.key,
    required Balance balance,
    this.label = 'Total outstanding',
  })  : outstanding = balance.totalOutstanding,
        clearedText = 'You have nothing left to pay.',
        left = 'Fines ₱${balance.outstanding}',
        right = 'Contributions ₱${balance.contributionsOutstanding}';

  BalanceCard.fines({
    super.key,
    required Balance balance,
    this.label = 'Fines outstanding',
  })  : outstanding = balance.outstanding,
        clearedText = 'You have no unpaid fines.',
        left = 'Total ₱${balance.totalFines}',
        right = 'Paid ₱${balance.totalPaid}';

  BalanceCard.contributions({
    super.key,
    required Balance balance,
    this.label = 'Contributions outstanding',
  })  : outstanding = balance.contributionsOutstanding,
        clearedText = 'Your contributions are all paid.',
        left = 'Total ₱${balance.contributionsTotal}',
        right = 'Paid ₱${balance.contributionsPaid}';

  @override
  Widget build(BuildContext context) {
    final cleared = (double.tryParse(outstanding) ?? 0) <= 0;
    final bg = cleared ? AppTheme.green : const Color(0xFF17231A);
    final fg = cleared ? AppTheme.onGreen : Colors.white;
    final soft = fg.withValues(alpha: 0.8);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppTheme.radiusCard + 4),
        boxShadow: const [
          BoxShadow(
              color: Color(0x2617231A), blurRadius: 16, offset: Offset(0, 6)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.account_balance_wallet_outlined, color: soft, size: 20),
              const SizedBox(width: 8),
              Text(label, style: TextStyle(color: soft, fontSize: 14)),
            ],
          ),
          const SizedBox(height: 8),
          Text('₱$outstanding',
              style: TextStyle(
                  color: fg,
                  fontSize: 36,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5)),
          const SizedBox(height: 6),
          if (cleared)
            Text(clearedText, style: TextStyle(color: soft))
          else
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(child: Text(left, style: TextStyle(color: soft))),
                const SizedBox(width: 12),
                Flexible(
                    child: Text(right,
                        textAlign: TextAlign.end,
                        style: TextStyle(color: soft))),
              ],
            ),
        ],
      ),
    );
  }
}
