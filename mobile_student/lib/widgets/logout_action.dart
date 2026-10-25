import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/auth_provider.dart';

/// Asks for confirmation, then clears the session via [AuthProvider].
/// Offline sign-in stays on the phone unless "Forget this phone" is ticked.
Future<void> confirmLogout(BuildContext context) async {
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
            const Text('You will need to sign in again.'),
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
