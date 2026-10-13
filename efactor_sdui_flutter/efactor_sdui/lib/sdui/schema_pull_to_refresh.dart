import 'package:flutter/material.dart';

/// Drag from the top to reload the live schema, matching Home.
///
/// [fillViewport] is for schema trees that are not themselves a vertical
/// [ScrollView] (Auth canvas, Device flex layout). It keeps a bounded height
/// so nested ListViews still receive a finite viewport.
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

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      notificationPredicate: (ScrollNotification notification) {
        return notification.metrics.axis == Axis.vertical;
      },
      onRefresh: onRefresh,
      child: fillViewport ? _fillViewport(context, child) : child,
    );
  }

  Widget _fillViewport(BuildContext context, Widget child) {
    final media = MediaQuery.sizeOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : media.height;
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : media.width;
        return ListView(
          physics: const AlwaysScrollableScrollPhysics(
            parent: ClampingScrollPhysics(),
          ),
          padding: EdgeInsets.zero,
          children: <Widget>[
            SizedBox(width: width, height: height, child: child),
          ],
        );
      },
    );
  }
}
