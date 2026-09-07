import 'package:flutter/material.dart';

import 'package:dart_control_panel/controllers/video_controller.dart';
import 'package:dart_control_panel/video/video_backend.dart';

/// P5 video panel: the player surface plus video-transport status and
/// controls. Kept presentational so widget tests can drive it with a fake
/// [VideoController].
///
/// - video status (connecting/buffering/playing/paused/error) is shown apart
///   from the control-plane status of the parent screen;
/// - reconnect rebuilds only the player (never the board worker);
/// - when the board reports RTSP unavailable ([rtspAvailable] == false) the
///   preview button is replaced by an explanation.
class VideoPanel extends StatelessWidget {
  const VideoPanel({
    super.key,
    required this.controller,
    required this.rtspAvailable,
    required this.url,
  });

  final VideoController controller;
  final bool rtspAvailable;
  final String url;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final status = controller.status;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _statusStrip(context, status),
            Expanded(child: _surface(context, status)),
          ],
        );
      },
    );
  }

  Widget _surface(BuildContext context, VideoStatus status) {
    if (status == VideoStatus.idle) {
      return Container(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.videocam_off_outlined,
                  size: 56, color: Theme.of(context).colorScheme.outline),
              const SizedBox(height: 12),
              const Text('Preview stopped'),
            ],
          ),
        ),
      );
    }
    return ColoredBox(color: Colors.black, child: controller.build(context));
  }

  Widget _statusStrip(BuildContext context, VideoStatus status) {
    final theme = Theme.of(context);
    final (color, label) = switch (status) {
      VideoStatus.idle => (theme.colorScheme.outline, 'stopped'),
      VideoStatus.connecting => (Colors.amber, 'connecting'),
      VideoStatus.buffering => (Colors.amber, 'buffering'),
      VideoStatus.playing => (Colors.green, 'playing'),
      VideoStatus.paused => (Colors.blueGrey, 'paused'),
      VideoStatus.error => (theme.colorScheme.error, 'stream error'),
    };

    return Material(
      color: color.withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Icon(
              status == VideoStatus.error
                  ? Icons.error_outline
                  : status.isActive
                      ? Icons.videocam
                      : Icons.videocam_outlined,
              size: 18,
              color: color,
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: theme.textTheme.labelLarge
                  ?.copyWith(color: color, fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                controller.lastError ?? url,
                style: theme.textTheme.bodySmall,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            _action(context, status),
          ],
        ),
      ),
    );
  }

  Widget _action(BuildContext context, VideoStatus status) {
    final busy = status == VideoStatus.connecting ||
        status == VideoStatus.buffering;
    return switch (status) {
      VideoStatus.idle => FilledButton.icon(
          onPressed: rtspAvailable && !busy
              ? () => controller.open(url)
              : null,
          icon: const Icon(Icons.play_arrow, size: 18),
          label: const Text('Start preview'),
        ),
      VideoStatus.error => FilledButton.icon(
          onPressed: () => controller.reconnect(),
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('Reconnect player'),
        ),
      _ => Wrap(
          spacing: 4,
          children: [
            IconButton(
              tooltip: status == VideoStatus.paused ? 'Resume' : 'Pause',
              onPressed: busy
                  ? null
                  : () => status == VideoStatus.paused
                      ? controller.resume()
                      : controller.pause(),
              icon: Icon(status == VideoStatus.paused
                  ? Icons.play_arrow
                  : Icons.pause),
            ),
            IconButton(
              tooltip: 'Stop preview',
              onPressed: () => controller.stop(),
              icon: const Icon(Icons.stop),
            ),
          ],
        ),
    };
  }
}

/// Info strip shown instead of the player when RTSP is not enabled on the
/// board (features.rtsp / worker.stream.rtsp_enabled both false).
class RtspUnavailable extends StatelessWidget {
  const RtspUnavailable({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.tv_off, size: 56, color: theme.colorScheme.outline),
              const SizedBox(height: 12),
              const Text('RTSP is not enabled on this board'),
              const SizedBox(height: 4),
              Text(
                'Enable the rtsp feature (Features screen) to preview video.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}