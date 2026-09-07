import 'package:flutter/material.dart';

/// Small labelled value line, used inside metric cards.
class StatRow extends StatelessWidget {
  const StatRow({
    super.key,
    required this.label,
    required this.value,
    this.highlight = false,
    this.valueColor,
  });

  final String label;
  final String value;
  final bool highlight;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = valueColor ??
        (highlight ? theme.colorScheme.error : theme.colorScheme.onSurface);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: theme.textTheme.bodySmall),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              value,
              style: theme.textTheme.bodySmall!.copyWith(
                color: color,
                fontWeight: highlight ? FontWeight.bold : FontWeight.normal,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// A titled box that groups several [StatRow]s.
class MetricCard extends StatelessWidget {
  const MetricCard({
    super.key,
    required this.title,
    required this.children,
    this.trailing,
    this.minWidth = 240,
  });

  final String title;
  final List<Widget> children;
  final Widget? trailing;
  final double minWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: BoxConstraints(minWidth: minWidth),
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  ?trailing,
                ],
              ),
              const SizedBox(height: 8),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}
