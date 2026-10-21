import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/connectivity_service.dart';
import '../theme/app_theme.dart';

/// A slim strip under the app bar while the phone has no connection.
/// Renders nothing when online (or when no [ConnectivityService] is provided).
class OfflineBanner extends StatelessWidget {
  final String message;
  const OfflineBanner({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final online = context.watch<ConnectivityService?>()?.isOnline ?? true;
    if (online) return const SizedBox.shrink();
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
              child: Text(message,
                  style: TextStyle(color: brand.warningFg, fontSize: 13)),
            ),
          ],
        ),
      ),
    );
  }
}
