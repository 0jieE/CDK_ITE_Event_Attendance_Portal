import 'package:flutter/material.dart';

import '../utils/errors.dart';
import 'state_message.dart';

/// Loads a single [Future] and renders loading / error / data, exposing a
/// [refresh] callback to the data builder (wrap your content in a scrollable
/// for pull-to-refresh).
class AsyncView<T> extends StatefulWidget {
  final Future<T> Function() loader;
  final Widget Function(BuildContext context, T data, Future<void> Function() refresh)
      builder;

  const AsyncView({super.key, required this.loader, required this.builder});

  @override
  State<AsyncView<T>> createState() => _AsyncViewState<T>();
}

class _AsyncViewState<T> extends State<AsyncView<T>> {
  late Future<T> _future;

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
    return FutureBuilder<T>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return RefreshIndicator(
            onRefresh: _refresh,
            child: RefreshableCenter(
              child: StateMessage(
                icon: Icons.cloud_off,
                isError: true,
                title: 'Could not load data',
                subtitle: friendlyError(snap.error!),
                actionLabel: 'Retry',
                onAction: _refresh,
              ),
            ),
          );
        }
        return RefreshIndicator(
          onRefresh: _refresh,
          child: widget.builder(context, snap.data as T, _refresh),
        );
      },
    );
  }
}
