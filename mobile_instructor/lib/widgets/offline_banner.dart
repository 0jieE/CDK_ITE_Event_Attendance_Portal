import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../services/api_service.dart';
import '../services/connectivity_service.dart';
import '../theme/app_theme.dart';
import '../utils/manila_time.dart';

/// A slim strip under the app bar while the phone has no connection, saying
/// how old the saved data on screen is. Renders nothing when online (or when
/// no [ConnectivityService] is provided).
class OfflineBanner extends StatelessWidget {
  final String message;
  const OfflineBanner({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final online = context.watch<ConnectivityService?>()?.isOnline ?? true;
    if (online) return const SizedBox.shrink();
    final savedAt = context.read<ApiService?>()?.offlineDataTime;
    final brand = context.brand;
    return Material(
      color: brand.warningBg,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.cloud_off, size: 18, color: brand.warningFg),
            const SizedBox(width: 10),
            Expanded(
              child: ValueListenableBuilder<DateTime?>(
                valueListenable: savedAt ?? ValueNotifier<DateTime?>(null),
                builder: (context, at, _) => Text(
                  at == null
                      ? message
                      : '$message Showing data saved '
                          '${DateFormat('MMM d, h:mm a').format(toManila(at))}.',
                  style: TextStyle(color: brand.warningFg, fontSize: 13),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
