import 'package:flutter/material.dart';

import '../models/fine.dart';
import '../theme/app_theme.dart';

/// Outstanding-balance hero card. Cleared balance = brand green with dark ink
/// text (white on #41B422 is too faint); an unpaid balance = dark ink card.
class BalanceCard extends StatelessWidget {
  final Balance balance;
  final String label;
  const BalanceCard({
    super.key,
    required this.balance,
    this.label = 'Outstanding balance',
  });

  @override
  Widget build(BuildContext context) {
    final outstanding = double.tryParse(balance.outstanding) ?? 0;
    final cleared = outstanding <= 0;
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
          Text('₱${balance.outstanding}',
              style: TextStyle(
                  color: fg,
                  fontSize: 36,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5)),
          const SizedBox(height: 6),
          if (cleared)
            Text('You have no unpaid fines.', style: TextStyle(color: soft))
          else
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Total ₱${balance.totalFines}',
                    style: TextStyle(color: soft)),
                Text('Paid ₱${balance.totalPaid}',
                    style: TextStyle(color: soft)),
              ],
            ),
        ],
      ),
    );
  }
}
