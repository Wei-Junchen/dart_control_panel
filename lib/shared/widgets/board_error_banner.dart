import 'package:flutter/material.dart';
import 'package:dart_control_panel/core/board/models/daemon_state.dart';

/// Common to all pages, including telemetry when the worker has disappeared.
class BoardErrorBanner extends StatelessWidget {
  const BoardErrorBanner({super.key, required this.state});
  final DaemonState? state;

  @override
  Widget build(BuildContext context) {
    final state = this.state;
    if (state == null) return const SizedBox.shrink();
    final error = state.workerError;
    final current = state.lastError.isNotEmpty;
    if (error == null && !current) return const SizedBox.shrink();
    if (error?.severity == 'info' && !current) {
      return const SizedBox.shrink();
    }
    final active = (error?.active ?? false) || current;
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: active ? colors.errorContainer : colors.surfaceContainerHighest,
      child: ExpansionTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        leading: Icon(active ? Icons.error_outline : Icons.history),
        title: Text(
          error == null || (!error.active && current)
              ? state.lastError
              : active
              ? '板端异常：${error.title}'
              : '历史异常（已恢复）· 非当前故障',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Align(
              alignment: Alignment.centerLeft,
              child: SelectableText(
                [
                  if (error != null) error.suggestion,
                  if (error != null) error.details,
                  if (current) state.lastError,
                ].join('\n'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
