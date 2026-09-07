import 'package:flutter/widgets.dart';

import 'package:dart_control_panel/models/daemon_state.dart';

/// Video transport-level state, independent of the control plane.
enum VideoStatus {
  idle,
  connecting,
  buffering,
  playing,
  paused,
  error,
}

extension VideoStatusX on VideoStatus {
  bool get isActive => this == VideoStatus.playing || this == VideoStatus.buffering;
}

/// Event emitted by a [VideoBackend] (decoder/library state).
enum VideoBackendEventKind {
  buffering,
  playing,
  paused,
  stopped,
  error,
}

class VideoBackendEvent {
  const VideoBackendEvent(this.kind, {this.message});

  final VideoBackendEventKind kind;
  final String? message;
}

/// Player-backend seam. The app logic ([VideoController]) only speaks to this
/// interface; concrete implementations bring their own decoder library.
abstract class VideoBackend {
  /// Starts/resumes playback of [url]. Reopening after a stream drop rebuilds
  /// the decoder — this is the only "reconnect" a video needs; the board-side
  /// worker is never restarted.
  Future<void> open(String url);

  Future<void> pause();
  Future<void> resume();
  Future<void> close();

  /// Player surface to embed in the UI.
  Widget build(BuildContext context);

  /// Decoder state changes (buffering/playing/paused/stopped/error).
  Stream<VideoBackendEvent> get events;

  Future<void> dispose();
}

/// `rtsp://<host>:<port>/live` — the only URL shape the board serves.
String rtspUrl(String host, {int port = 8554}) => 'rtsp://$host:$port/live';

/// Whether preview is possible at all, per the daemon state: both the
/// feature flag and the worker's stream section must agree (never assume the
/// port alone).
bool rtspAvailableFor(DaemonState state) =>
    state.features.rtsp && (state.worker?.stream.rtspEnabled ?? false);