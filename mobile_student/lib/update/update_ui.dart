import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:provider/provider.dart';

import '../theme/app_theme.dart';
import 'apk_downloader.dart';
import 'github_releases.dart';
import 'update_service.dart';

/// "27.4 MB"
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// Checks for updates once the app is up and whenever it returns to the
/// foreground (throttled by [UpdateService]). Never shows anything itself:
/// [UpdatePrompter] offers the update where it can't get in the way.
class UpdateChecker extends StatefulWidget {
  final Widget child;
  const UpdateChecker({super.key, required this.child});

  @override
  State<UpdateChecker> createState() => _UpdateCheckerState();
}

class _UpdateCheckerState extends State<UpdateChecker>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // After the first frame: start-up is never held up by GitHub.
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  void _check() {
    if (!mounted) return;
    unawaited(context.read<UpdateService?>()?.check());
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Offers an available update with [showUpdateDialog] - placed on the
/// signed-in home screen, so it never interrupts signing in, and only while
/// that screen is on top (not over another page or form).
class UpdatePrompter extends StatefulWidget {
  final Widget child;
  const UpdatePrompter({super.key, required this.child});

  @override
  State<UpdatePrompter> createState() => _UpdatePrompterState();
}

class _UpdatePrompterState extends State<UpdatePrompter> {
  UpdateService? _service;
  bool _showing = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final s = context.read<UpdateService?>();
    if (s != _service) {
      _service?.removeListener(_maybePrompt);
      _service = s?..addListener(_maybePrompt);
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybePrompt());
    }
  }

  @override
  void dispose() {
    _service?.removeListener(_maybePrompt);
    super.dispose();
  }

  Future<void> _maybePrompt() async {
    final s = _service;
    final release = s?.available;
    if (s == null || release == null || !s.shouldPrompt || _showing) return;
    if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? true)) return;
    _showing = true;
    await showUpdateDialog(context, s, release);
    _showing = false;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Set while the update flow (offer, download, install) is on screen, so
/// [UpdatePrompter] and a manual check finding the same update can't stack
/// two dialogs.
bool _updateFlowOpen = false;

/// The "Update available" dialog; "Update now" downloads and installs.
/// Does nothing while the flow is already open.
Future<void> showUpdateDialog(
    BuildContext context, UpdateService service, AppRelease release) async {
  if (_updateFlowOpen) return;
  _updateFlowOpen = true;
  try {
    final update = await showDialog<bool>(
      context: context,
      builder: (ctx) => _UpdateDialog(service: service, release: release),
    );
    if (update != true) {
      service.dismiss(release); // "Later" (or tapped outside)
      return;
    }
    if (!context.mounted) return;
    final apk = await showDialog<File>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _DownloadDialog(release: release, service: service),
    );
    if (apk == null || !context.mounted) return;
    await _install(context, service, apk);
  } finally {
    _updateFlowOpen = false;
  }
}

class _UpdateDialog extends StatelessWidget {
  final UpdateService service;
  final AppRelease release;
  const _UpdateDialog({required this.service, required this.release});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final installed = service.installed?.versionName ?? '?';
    final muted = TextStyle(color: scheme.onSurfaceVariant);
    return AlertDialog(
      icon: Icon(Icons.system_update, color: context.brand.accent, size: 32),
      title: const Text('Update available'),
      content: ConstrainedBox(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.5),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Row('Installed', installed, muted),
            _Row('Latest', release.version.toString(), muted, bold: true),
            if (release.apk.size > 0)
              _Row('Download size', formatBytes(release.apk.size), muted),
            if (release.notes.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text("What's new",
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Flexible(
                child: SingleChildScrollView(child: Text(release.notes)),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Later')),
        FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Update now')),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  final String label;
  final String value;
  final TextStyle muted;
  final bool bold;
  const _Row(this.label, this.value, this.muted, {this.bold = false});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Expanded(child: Text(label, style: muted)),
            Text(value,
                style: TextStyle(
                    fontWeight: bold ? FontWeight.w800 : FontWeight.w600)),
          ],
        ),
      );
}

/// Downloads with live progress; pops with the verified APK, or null.
class _DownloadDialog extends StatefulWidget {
  final AppRelease release;
  final UpdateService service;
  const _DownloadDialog({required this.release, required this.service});

  @override
  State<_DownloadDialog> createState() => _DownloadDialogState();
}

class _DownloadDialogState extends State<_DownloadDialog> {
  CancelToken _cancel = CancelToken();
  DownloadProgress _progress = const DownloadProgress(0, null);
  String? _error;
  bool _verifying = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _cancel.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    _cancel = CancelToken();
    setState(() {
      _error = null;
      _verifying = false;
      _progress = const DownloadProgress(0, null);
    });
    try {
      final dir = Directory(await widget.service.installer.updateDir());
      final apk = await widget.service.downloader.download(
        widget.release.apk,
        dir: dir,
        cancel: _cancel,
        onProgress: (p) {
          if (!mounted) return;
          setState(() {
            _progress = p;
            _verifying = p.total != null && p.received >= p.total!;
          });
        },
      );
      if (mounted) Navigator.pop(context, apk);
    } on DownloadCancelled {
      // The user cancelled (and the dialog is already closing).
    } on UpdateDownloadException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = "The update couldn't be downloaded. Try again.");
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _progress;
    final percent = p.fraction == null ? null : (p.fraction! * 100).floor();
    final muted = TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant);
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(_error != null
            ? 'Download failed'
            : 'Downloading ${widget.release.version}'),
        content: _error != null
            ? Text(_error!)
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  LinearProgressIndicator(value: p.fraction, minHeight: 8,
                      borderRadius: BorderRadius.circular(4)),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Text(
                        _verifying
                            ? 'Verifying…'
                            : percent == null
                                ? 'Starting…'
                                : '$percent%',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const Spacer(),
                      Text(
                        p.total == null
                            ? formatBytes(p.received)
                            : '${formatBytes(p.received)} of ${formatBytes(p.total!)}',
                        style: muted,
                      ),
                    ],
                  ),
                ],
              ),
        actions: [
          if (_error != null) ...[
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close')),
            FilledButton(onPressed: _start, child: const Text('Try again')),
          ] else
            TextButton(
              onPressed: () {
                _cancel.cancel();
                Navigator.pop(context);
              },
              child: const Text('Cancel'),
            ),
        ],
      ),
    );
  }
}

/// Hands the verified APK to Android's installer, first asking for the
/// "Install unknown apps" permission if this app doesn't have it yet.
Future<void> _install(
    BuildContext context, UpdateService service, File apk) async {
  final installer = service.installer;
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    if (!await installer.canInstallPackages()) {
      if (!context.mounted) return;
      final open = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.security, size: 32),
          title: const Text('Allow installing the update'),
          content: const Text(
              'Android needs your permission for this app to install its '
              'updates.\n\nTap "Open settings", turn on "Allow from this '
              'source", then come back here.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Not now')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Open settings')),
          ],
        ),
      );
      if (open != true) return;
      final back = _nextResume();
      await installer.openInstallSettings();
      await back;
      if (!await installer.canInstallPackages()) {
        messenger?.showSnackBar(const SnackBar(
            content: Text('Installing updates is still not allowed. You can '
                'try again from Profile → Check for updates.')));
        return;
      }
    }
    // Android shows its own confirmation; the app's data is kept.
    await installer.installApk(apk.path);
  } on PlatformException catch (e) {
    messenger?.showSnackBar(SnackBar(
        content: Text("The installer couldn't be opened"
            "${e.message == null ? '' : ': ${e.message}'}")));
  }
}

/// Completes when the app is next back in the foreground.
Future<void> _nextResume() {
  final done = Completer<void>();
  late final AppLifecycleListener listener;
  listener = AppLifecycleListener(onResume: () {
    listener.dispose();
    if (!done.isCompleted) done.complete();
  });
  return done.future;
}

/// A manual check: offers the update if there is one, otherwise says
/// "You have the latest version." or why the check failed. [onChecked] runs
/// as soon as GitHub has answered.
Future<void> checkForUpdatesNow(BuildContext context,
    {VoidCallback? onChecked}) async {
  final service = context.read<UpdateService>();
  final messenger = ScaffoldMessenger.of(context);
  final status = await service.check(manual: true);
  onChecked?.call();
  if (!context.mounted) return;
  final release = service.available;
  if (status == UpdateStatus.available && release != null) {
    await showUpdateDialog(context, service, release);
  } else if (status == UpdateStatus.upToDate) {
    messenger.showSnackBar(
        const SnackBar(content: Text('You have the latest version.')));
  } else if (status == UpdateStatus.failed) {
    messenger.showSnackBar(SnackBar(
        content: Text(service.error ?? "Couldn't check for updates.")));
  }
}

/// "Check for updates" with the installed version, as a card.
class CheckForUpdatesTile extends StatefulWidget {
  const CheckForUpdatesTile({super.key});

  @override
  State<CheckForUpdatesTile> createState() => _CheckForUpdatesTileState();
}

class _CheckForUpdatesTileState extends State<CheckForUpdatesTile> {
  @override
  void initState() {
    super.initState();
    context.read<UpdateService?>()?.loadInstalled();
  }

  @override
  Widget build(BuildContext context) {
    final service = context.watch<UpdateService?>();
    if (service == null || !service.installer.supported) {
      return const SizedBox.shrink();
    }
    final installed = service.installed;
    final checking = service.status == UpdateStatus.checking;
    final release = service.available;
    return Card(
      child: ListTile(
        leading: Icon(Icons.system_update, color: context.brand.accent),
        title: Text(release != null ? 'Update available' : 'Check for updates',
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text([
          if (installed != null)
            'Version ${installed.versionName} (${installed.versionCode})',
          if (release != null) 'New: ${release.version}',
        ].join(' · ')),
        trailing: checking
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.chevron_right),
        onTap: checking ? null : () => checkForUpdatesNow(context),
      ),
    );
  }
}

/// The AppBar's ⋮ menu with "Check for updates" and the installed version
/// (this app has no Profile tab for [CheckForUpdatesTile]). Hidden where
/// updates aren't supported.
class UpdateMenuButton extends StatefulWidget {
  const UpdateMenuButton({super.key});

  @override
  State<UpdateMenuButton> createState() => _UpdateMenuButtonState();
}

class _UpdateMenuButtonState extends State<UpdateMenuButton> {
  @override
  void initState() {
    super.initState();
    context.read<UpdateService?>()?.loadInstalled();
  }

  @override
  Widget build(BuildContext context) {
    final service = context.watch<UpdateService?>();
    if (service == null || !service.installer.supported) {
      return const SizedBox.shrink();
    }
    final installed = service.installed;
    final checking = service.status == UpdateStatus.checking;
    final release = service.available;
    return PopupMenuButton<void>(
      tooltip: 'More',
      itemBuilder: (_) => [
        PopupMenuItem<void>(
          enabled: !checking,
          onTap: () {
            // The menu closes on tap: say that the check is running.
            final checkingBar = ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                    content: Text('Checking for updates…'),
                    duration: Duration(seconds: 30)));
            checkForUpdatesNow(context, onChecked: checkingBar.close);
          },
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: checking
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: Padding(
                      padding: EdgeInsets.all(2),
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ))
                : Icon(Icons.system_update, color: context.brand.accent),
            title: Text(release != null
                ? 'Update available: ${release.version}'
                : 'Check for updates'),
            subtitle: installed == null
                ? null
                : Text('Version ${installed.versionName} '
                    '(${installed.versionCode})'),
          ),
        ),
      ],
    );
  }
}

/// A small "Update available" button for the login screen: the update can be
/// installed before signing in, without a dialog interrupting the form.
class UpdateAvailableButton extends StatelessWidget {
  const UpdateAvailableButton({super.key});

  @override
  Widget build(BuildContext context) {
    final service = context.watch<UpdateService?>();
    final release = service?.available;
    if (service == null || release == null) return const SizedBox.shrink();
    return TextButton.icon(
      onPressed: () => showUpdateDialog(context, service, release),
      icon: const Icon(Icons.system_update, size: 18),
      label: Text('Update available: ${release.version}'),
    );
  }
}
