import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../models/event.dart';
import '../../models/fine.dart';
import '../../models/student_profile.dart';
import '../../services/api_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/async_view.dart';
import '../../widgets/profile_avatar.dart';

typedef _DashboardData = ({
  StudentProfile profile,
  Balance balance,
  List<Event> events,
});

class DashboardTab extends StatelessWidget {
  const DashboardTab({super.key});

  @override
  Widget build(BuildContext context) {
    final api = context.read<ApiService>();

    Future<_DashboardData> load() async {
      final results = await Future.wait([
        api.studentProfile(),
        api.studentBalance(),
        api.studentEvents(),
      ]);
      return (
        profile: results[0] as StudentProfile,
        balance: results[1] as Balance,
        events: (results[2] as List).cast<Event>(),
      );
    }

    return AsyncView<_DashboardData>(
      loader: load,
      builder: (context, data, _) {
        return ListView(
          padding: const EdgeInsets.all(16),
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            _ProfileCard(profile: data.profile),
            const SizedBox(height: 16),
            _BalanceCard(balance: data.balance),
            const SizedBox(height: 24),
            Text('Active & Upcoming Events',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (data.events.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text('No active events right now.',
                      style: TextStyle(color: Colors.black54)),
                ),
              )
            else
              ...data.events.map((e) => _EventTile(event: e)),
          ],
        );
      },
    );
  }
}

class _ProfileCard extends StatelessWidget {
  final StudentProfile profile;
  const _ProfileCard({required this.profile});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            ProfileAvatar(
              imageUrl: profile.profileImage,
              name: profile.fullName,
              radius: 28,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(profile.fullName,
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 2),
                  Text(profile.studentNumber,
                      style: const TextStyle(color: Colors.black54)),
                  if (profile.yearSection.isNotEmpty)
                    Text(profile.yearSection,
                        style: const TextStyle(color: Colors.black54)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BalanceCard extends StatelessWidget {
  final Balance balance;
  const _BalanceCard({required this.balance});

  @override
  Widget build(BuildContext context) {
    final outstanding = double.tryParse(balance.outstanding) ?? 0;
    final cleared = outstanding <= 0;
    return Card(
      color: cleared ? const Color(0xFF198754) : AppTheme.violet,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.account_balance_wallet, color: Colors.white70),
                const SizedBox(width: 8),
                Text('Outstanding Balance',
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.85),
                        fontSize: 14)),
              ],
            ),
            const SizedBox(height: 8),
            Text('₱${balance.outstanding}',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 36,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(
              cleared
                  ? 'You have no unpaid fines. ✓'
                  : 'Total fines ₱${balance.totalFines} · Paid ₱${balance.totalPaid}',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.85)),
            ),
          ],
        ),
      ),
    );
  }
}

class _EventTile extends StatelessWidget {
  final Event event;
  const _EventTile({required this.event});

  @override
  Widget build(BuildContext context) {
    final df = DateFormat('MMM d');
    final dfy = DateFormat('MMM d, y');
    final range = event.startDate == event.endDate
        ? dfy.format(event.startDate)
        : '${df.format(event.startDate)} – ${dfy.format(event.endDate)}';
    return Card(
      child: ListTile(
        leading: const Icon(Icons.event, color: AppTheme.violet),
        title: Text(event.name),
        subtitle: Text(range),
      ),
    );
  }
}
