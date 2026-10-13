import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Developer-facing diagnostic used only when schema data cannot be rendered.
///
/// It is deliberately app-owned because it must still render when the schema is
/// incomplete. It never requests infinite width, so it is safe in Row, Stack,
/// Positioned, prefix/suffix icon slots and scroll views.
class AuthSchemaIssue extends StatelessWidget {
  const AuthSchemaIssue({
    super.key,
    required this.title,
    required this.details,
  });

  final String title;
  final List<String> details;

  String get _message {
    final b = StringBuffer(title);
    for (final detail in details) {
      b.write('\n• $detail');
    }
    return b.toString();
  }

  @override
  Widget build(BuildContext context) {
    // Error chrome uses Theme colorScheme only — no invented brand hex colors.
    final scheme = Theme.of(context).colorScheme;
    final background = scheme.errorContainer;
    final border = scheme.error;
    final text = scheme.onErrorContainer;

    return MediaQuery.withClampedTextScaling(
      minScaleFactor: 1,
      maxScaleFactor: 1,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final hasWidth =
              constraints.hasBoundedWidth && constraints.maxWidth.isFinite;
          final hasHeight =
              constraints.hasBoundedHeight && constraints.maxHeight.isFinite;

          final width = hasWidth
              ? constraints.maxWidth
              : math.min(72.0, math.max(1.0, MediaQuery.sizeOf(context).width));

          final height = hasHeight ? constraints.maxHeight : null;
          final compact =
              !hasWidth || width < 180 || (height != null && height < 72);

          if (compact) {
            return Tooltip(
              message: _message,
              child: SizedBox(
                width: width,
                height: height,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: background,
                    border: Border.all(color: border),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
                    child: Center(
                      child: Text(
                        'Schema error',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: text,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          height: 1,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          }

          Widget child = DecoratedBox(
            decoration: BoxDecoration(
              color: background,
              border: Border.all(color: border),
              borderRadius: BorderRadius.circular(8),
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: text,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (details.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    for (final d in details)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 3),
                        child: Text(
                          '• $d',
                          style: TextStyle(
                            color: text,
                            fontSize: 13,
                            height: 1.25,
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          );

          child = SizedBox(width: width, child: child);
          if (height != null && height > 0) {
            child = SizedBox(width: width, height: height, child: child);
          }
          return child;
        },
      ),
    );
  }
}
