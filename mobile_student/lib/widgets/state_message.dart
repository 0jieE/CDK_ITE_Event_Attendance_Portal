import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Friendly centred message for empty / error states: an icon in a soft badge,
/// a title, optional detail and an optional action button.
class StateMessage extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool isError;

  const StateMessage({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.actionLabel,
    this.onAction,
    this.isError = false,
  });

  @override
  Widget build(BuildContext context) {
    final brand = context.brand;
    final scheme = Theme.of(context).colorScheme;
    final badgeBg = isError ? brand.absentBg : brand.tint;
    final badgeFg = isError ? brand.absentFg : brand.accent;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(color: badgeBg, shape: BoxShape.circle),
              child: Icon(icon, size: 36, color: badgeFg),
            ),
            const SizedBox(height: 16),
            Text(title,
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(subtitle!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant)),
            ],
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 20),
              OutlinedButton.icon(
                onPressed: onAction,
                icon: const Icon(Icons.refresh),
                label: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A pull-to-refreshable scroll view that centres [child] (so empty/error
/// states can still be dragged down to reload).
class RefreshableCenter extends StatelessWidget {
  final Widget child;
  const RefreshableCenter({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: c.maxHeight),
          child: Center(child: child),
        ),
      ),
    );
  }
}

/// Inline error / info banner (e.g. above a form or a button).
class InlineBanner extends StatelessWidget {
  final String message;
  final bool isError;
  final IconData? icon;
  final Widget? action;

  const InlineBanner({
    super.key,
    required this.message,
    this.isError = true,
    this.icon,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final brand = context.brand;
    final bg = isError ? brand.absentBg : brand.tint;
    final fg = isError ? brand.absentFg : brand.accent;
    final text = Theme.of(context).colorScheme.onSurface;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon ?? (isError ? Icons.error_outline : Icons.info_outline),
              size: 20, color: fg),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message, style: TextStyle(color: isError ? fg : text)),
          ),
          if (action != null) ...[const SizedBox(width: 8), action!],
        ],
      ),
    );
  }
}
