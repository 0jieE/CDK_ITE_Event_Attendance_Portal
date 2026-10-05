import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../models/event.dart';
import '../../models/fine.dart';
import '../../models/student_profile.dart';
import '../../services/api_service.dart';
import '../../services/auth_provider.dart';
import '../../theme/app_theme.dart';
import '../../utils/event_dates.dart';
import '../../utils/manila_time.dart';
import '../../widgets/async_view.dart';
import '../../widgets/balance_card.dart';
import '../../widgets/profile_avatar.dart';
import '../../widgets/state_message.dart';
import '../../widgets/status_chip.dart';

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
            BalanceCard(balance: data.balance),
            const SizedBox(height: 24),
            Text('Active & upcoming events',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            if (data.events.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: StateMessage(
                  icon: Icons.event_busy,
                  title: 'No active events right now',
                  subtitle: 'New events will appear here once they open.',
                ),
              )
            else
              for (final e in data.events) ...[
                _EventTile(event: e),
                const SizedBox(height: 10),
              ],
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
    // Name and photo come from the cached user so an edit on the Profile tab
    // shows here immediately.
    final user = context.watch<AuthProvider>().user;
    final name = user?.fullName ?? profile.fullName;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            ProfileAvatar(
              imageUrl: user?.profileImage,
              name: name,
              radius: 30,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name,
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 2),
                  Text(profile.studentNumber, style: TextStyle(color: muted)),
                  if (profile.yearSection.isNotEmpty)
                    Text(profile.yearSection, style: TextStyle(color: muted)),
                ],
              ),
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
    final today = isRunningOn(event, manilaToday());
    final brand = context.brand;
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        leading: CircleAvatar(
          backgroundColor: brand.tint,
          child: Icon(Icons.event, color: brand.accent),
        ),
        title: Text(event.name,
            style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(range),
        trailing: today
            ? const StatusChip('PRESENT', label: 'Today')
            : const StatusChip('', label: 'Upcoming'),
      ),
    );
  }
}
