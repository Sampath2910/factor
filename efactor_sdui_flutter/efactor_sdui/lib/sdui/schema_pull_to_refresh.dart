import 'package:flutter/material.dart';

/// Drag from the top to reload the **live** schema (or live WebView content).
///
/// Contract for every [onRefresh] callback:
/// - Always request network data (`forceRefresh: true` or `forceFull: true`).
/// - Never short-circuit to cache-only for this gesture.
/// - Complete the Future even when the schema is unchanged so the spinner ends.
/// - On offline failure, keep the last cached schema and complete without throw
///   when the page already has content (repositories already retain cache).
///
/// [fillViewport] is for schema trees that are not themselves a vertical
/// [ScrollView] (Auth canvas, Device flex layout, WebView). It keeps a bounded
/// height so nested ListViews still receive a finite viewport.
class SchemaPullToRefresh extends StatelessWidget {
  const SchemaPullToRefresh({
    super.key,
    required this.onRefresh,
    required this.child,
    this.fillViewport = false,
  });

  final Future<void> Function() onRefresh;
  final Widget child;
  final bool fillViewport;

  /// Runs a pull-to-refresh live fetch. Prefer this wrapper so the indicator
  /// always settles even if the inner work returns early.
  static Future<void> runLiveRefresh(
    Future<void> Function() liveFetch,
  ) async {
    await liveFetch();
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      notificationPredicate: (ScrollNotification notification) {
        return notification.depth == 0 &&
            notification.metrics.axis == Axis.vertical;
      },
      onRefresh: () => runLiveRefresh(onRefresh),
      child: fillViewport ? _fillViewport(context, child) : child,
    );
  }

  Widget _fillViewport(BuildContext context, Widget child) {
    final media = MediaQuery.sizeOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        // When a parent Scaffold uses resizeToAvoidBottomInset, maxHeight
        // shrinks by the IME. Re-add viewInsets so the child extent stays
        // stable; otherwise focused TextFields remount / lose the keyboard.
        final viewInsets = MediaQuery.viewInsetsOf(context);
        final height = (constraints.maxHeight.isFinite
                ? constraints.maxHeight + viewInsets.bottom
                : media.height)
            .clamp(0.0, double.infinity);
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : media.width;
        return ListView(
          physics: const AlwaysScrollableScrollPhysics(
            parent: ClampingScrollPhysics(),
          ),
          padding: EdgeInsets.zero,
          // Layout jumps from IME open must not dismiss the keyboard.
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.manual,
          children: <Widget>[
            SizedBox(width: width, height: height, child: child),
          ],
        );
      },
    );
  }
}
