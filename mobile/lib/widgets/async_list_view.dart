import 'package:flutter/material.dart';

/// A list that loads asynchronously and renders loading / error / empty /
/// data states, with pull-to-refresh in every state.
class AsyncListView<T> extends StatefulWidget {
  final Future<List<T>> Function() loader;
  final Widget Function(BuildContext context, T item) itemBuilder;
  final String emptyMessage;
  final IconData emptyIcon;
  final EdgeInsetsGeometry padding;

  /// Optional fixed header rendered above the list (e.g. a summary card).
  final Widget? header;

  const AsyncListView({
    super.key,
    required this.loader,
    required this.itemBuilder,
    this.emptyMessage = 'Nothing here yet.',
    this.emptyIcon = Icons.inbox_outlined,
    this.padding = const EdgeInsets.all(16),
    this.header,
  });

  @override
  State<AsyncListView<T>> createState() => _AsyncListViewState<T>();
}

class _AsyncListViewState<T> extends State<AsyncListView<T>> {
  late Future<List<T>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.loader();
  }

  Future<void> _refresh() async {
    final f = widget.loader();
    setState(() => _future = f);
    try {
      await f;
    } catch (_) {/* surfaced by the FutureBuilder */}
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _refresh,
      child: FutureBuilder<List<T>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return _centered(
              icon: Icons.cloud_off,
              title: 'Could not load data',
              subtitle: '${snap.error}',
              showRetry: true,
            );
          }
          final items = snap.data ?? const [];
          if (items.isEmpty) {
            return _centered(
              icon: widget.emptyIcon,
              title: widget.emptyMessage,
            );
          }
          return ListView.separated(
            padding: widget.padding,
            physics: const AlwaysScrollableScrollPhysics(),
            itemCount: items.length + (widget.header != null ? 1 : 0),
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (context, i) {
              if (widget.header != null) {
                if (i == 0) return widget.header!;
                return widget.itemBuilder(context, items[i - 1]);
              }
              return widget.itemBuilder(context, items[i]);
            },
          );
        },
      ),
    );
  }

  /// A centered message that is still pull-to-refreshable.
  Widget _centered({
    required IconData icon,
    required String title,
    String? subtitle,
    bool showRetry = false,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 56, color: Colors.black26),
                  const SizedBox(height: 12),
                  Text(title,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 16, color: Colors.black54)),
                  if (subtitle != null) ...[
                    const SizedBox(height: 6),
                    Text(subtitle,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.black38)),
                  ],
                  if (showRetry) ...[
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      onPressed: _refresh,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
