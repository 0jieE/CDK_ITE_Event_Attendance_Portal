import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/auth_provider.dart';
import '../services/offline_scan_service.dart';

/// Asks for confirmation, then clears the session via [AuthProvider].
/// Offline sign-in stays on the phone unless "Forget this phone" is ticked;
/// queued offline scans are kept either way.
Future<void> confirmLogout(BuildContext context) async {
  final pending = context.read<OfflineScanService?>()?.pendingCount ?? 0;
  final canForget = context.read<AuthProvider>().offlineLogin != null;
  var forget = false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Log out?'),
      content: StatefulBuilder(
        builder: (ctx, setState) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(pending == 0
                ? 'You will need to sign in again.'
                : 'You will need to sign in again.\n\n'
                    '$pending scan${pending == 1 ? ' is' : 's are'} not synced '
                    'yet. They stay on this phone and sync the next time you '
                    'sign in here.'),
            if (canForget)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: forget,
                onChanged: (v) => setState(() => forget = v ?? false),
                title: const Text('Forget this phone'),
                subtitle:
                    const Text('Turn off offline sign-in for this account here.'),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Log out')),
      ],
    ),
  );
  if (ok == true && context.mounted) {
    await context.read<AuthProvider>().logout(forgetDevice: forget);
  }
}

/// AppBar logout button with a confirm dialog.
class LogoutAction extends StatelessWidget {
  const LogoutAction({super.key});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Log out',
      icon: const Icon(Icons.logout),
      onPressed: () => confirmLogout(context),
    );
  }
}
