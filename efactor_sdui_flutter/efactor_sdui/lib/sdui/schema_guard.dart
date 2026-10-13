import 'package:flutter/material.dart';

/// Compact schema/runtime error widget.
///
/// This widget is intentionally safe inside:
/// - bounded or unbounded Rows,
/// - horizontal/vertical scroll views,
/// - ParameterCard trailing/content areas,
/// - Wrap, Stack and ListView children.
///
/// It never returns Expanded and never forces an infinite width.
class SchemaIssueWidget extends StatelessWidget {
  const SchemaIssueWidget({
    super.key,
    required this.title,
    required this.details,
    this.componentType,
    this.binding,
    this.controlId,
  });

  final String title;
  final List<String> details;
  final String? componentType;
  final String? binding;
  final String? controlId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final errorColor = theme.colorScheme.error;
    final surfaceColor = theme.colorScheme.errorContainer;
    final foregroundColor = theme.colorScheme.onErrorContainer;

    final metadata = <String>[
      if (controlId != null && controlId!.trim().isNotEmpty)
        'Control: ${controlId!.trim()}',
      if (componentType != null && componentType!.trim().isNotEmpty)
        'Component: ${componentType!.trim()}',
      if (binding != null && binding!.trim().isNotEmpty)
        'Binding: ${binding!.trim()}',
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final hasFiniteWidth =
            constraints.hasBoundedWidth && constraints.maxWidth.isFinite;

        final issueBody = Container(
          constraints: BoxConstraints(
            minWidth: 0,
            maxWidth: hasFiniteWidth ? constraints.maxWidth : 320,
          ),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: surfaceColor,
            border: Border.all(color: errorColor.withValues(alpha: 0.55)),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error_outline, size: 18, color: errorColor),
                  const SizedBox(width: 8),
                  Flexible(
                    fit: FlexFit.loose,
                    child: Text(
                      title,
                      softWrap: true,
                      overflow: TextOverflow.visible,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: foregroundColor,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              if (metadata.isNotEmpty) ...[
                const SizedBox(height: 6),
                for (final item in metadata)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(
                      item,
                      softWrap: true,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: foregroundColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
              if (details.isNotEmpty) ...[
                const SizedBox(height: 6),
                for (final detail in details)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text(
                      '• $detail',
                      softWrap: true,
                      overflow: TextOverflow.visible,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: foregroundColor,
                      ),
                    ),
                  ),
              ],
            ],
          ),
        );

        // In an unbounded horizontal parent, return a finite-width widget.
        // In a normal bounded card/list, use the available width.
        if (!hasFiniteWidth) {
          return SizedBox(width: 320, child: issueBody);
        }

        return ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: 0,
            maxWidth: constraints.maxWidth,
          ),
          child: issueBody,
        );
      },
    );
  }
}
