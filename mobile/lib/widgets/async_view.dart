import 'package:flutter/material.dart';

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
            child: LayoutBuilder(
              builder: (context, c) => SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: c.maxHeight),
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.cloud_off,
                              size: 56, color: Colors.black26),
                          const SizedBox(height: 12),
                          Text('${snap.error}',
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.black54)),
                          const SizedBox(height: 16),
                          OutlinedButton.icon(
                            onPressed: _refresh,
                            icon: const Icon(Icons.refresh),
                            label: const Text('Retry'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
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
