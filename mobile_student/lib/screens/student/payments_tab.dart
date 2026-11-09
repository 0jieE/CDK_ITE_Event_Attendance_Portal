import 'package:flutter/material.dart';

import 'contributions_tab.dart';
import 'fines_tab.dart';

/// Everything the student owes, split into Fines (missed attendance) and
/// department Contributions.
class PaymentsTab extends StatelessWidget {
  const PaymentsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          Material(
            color: scheme.surface,
            child: TabBar(
              labelColor: scheme.onSurface,
              unselectedLabelColor: scheme.onSurfaceVariant,
              indicatorColor: scheme.primary,
              labelStyle: const TextStyle(fontWeight: FontWeight.w700),
              tabs: const [
                Tab(text: 'Fines'),
                Tab(text: 'Contributions'),
              ],
            ),
          ),
          const Expanded(
            child: TabBarView(
              children: [FinesTab(), ContributionsTab()],
            ),
          ),
        ],
      ),
    );
  }
}
