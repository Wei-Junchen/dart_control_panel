import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:dart_control_panel/core/video/media_kit_backend.dart';
import 'package:dart_control_panel/core/video/video_backend.dart';

/// P5 video controller — fully decoupled from the control plane.
///
/// Talks only to a [VideoBackend] (decoder). Handles:
/// - explicit state machine (idle → connecting → buffering → playing, error);
/// - no pileup: while an offload/open is in flight, a second [open] is
///   ignored;
/// - manual [reconnect] that rebuilds the player only — the board-side
///   worker is NEVER restarted from here;
/// - separate lifecycle from [BoardSession]: a stream drop must not touch
///   control-plane state and vice versa.
class VideoController extends ChangeNotifier {
  VideoController({VideoBackend? backend, this.liveStream = false}) {
    _backend = backend;
    if (backend != null) {
      _subscribe(backend);
    }
  }

  final bool liveStream;

  VideoBackend? _backend;
  StreamSubscription<VideoBackendEvent>? _eventsSub;

  VideoStatus _status = VideoStatus.idle;
  String? _url;
  String? _lastError;
  int _reconnectCount = 0;
  bool _openInFlight = false;

  VideoStatus get status => _status;
  String? get url => _url;
  String? get lastError => _lastError;
  int get reconnectCount => _reconnectCount;

  bool get isActive => _status.isActive;

  void _subscribe(VideoBackend backend) {
    _eventsSub?.cancel();
    _eventsSub = backend.events.listen(_onBackendEvent);
  }

  /// Lazily created real backend; tests inject a fake one instead.
  VideoBackend get _playerBackend {
    var backend = _backend;
    if (backend == null) {
      backend = MediaKitBackend(liveStream: liveStream);
      _backend = backend;
      _ownsBackend = true;
      _subscribe(backend);
    }
    return backend;
  }

  bool _ownsBackend = false;

  Future<void> open(String url) async {
    if (_openInFlight) return; // no pileup
    _openInFlight = true;
    _url = url;
    _lastError = null;
    _status = VideoStatus.connecting;
    notifyListeners();
    try {
      await _playerBackend.open(url);
      // Decoder events (buffering/playing) take over the status from here.
    } on Object catch (e) {
      _status = VideoStatus.error;
      _lastError = '$e';
      notifyListeners();
    } finally {
      _openInFlight = false;
    }
  }

  /// Drops the current decoder/demuxer queue and opens the same URL again.
  /// This is the live-preview "jump to live edge" operation; it never
  /// restarts the board worker.
  Future<void> reconnect() async {
    final url = _url;
    if (url == null || _openInFlight) return;
    _reconnectCount++;
    await _playerBackend.close();
    await open(url);
  }

  Future<void> pause() async {
    await _playerBackend.pause();
  }

  Future<void> resume() async {
    await _playerBackend.resume();
  }

  Future<void> stop() async {
    _openInFlight = false;
    await _playerBackend.close();
    _status = VideoStatus.idle;
    notifyListeners();
  }

  Widget build(BuildContext context) => _playerBackend.build(context);

  void _onBackendEvent(VideoBackendEvent event) {
    switch (event.kind) {
      case VideoBackendEventKind.buffering:
        // only surface buffering while we actually expect playback
        if (_status != VideoStatus.idle) {
          _status = VideoStatus.buffering;
        }
      case VideoBackendEventKind.playing:
        _status = VideoStatus.playing;
        _lastError = null;
      case VideoBackendEventKind.paused:
        if (_status.isActive) _status = VideoStatus.paused;
      case VideoBackendEventKind.stopped:
        _status = VideoStatus.idle;
      case VideoBackendEventKind.error:
        // stream drop: keep the URL so reconnect() still works
        _status = VideoStatus.error;
        _lastError = event.message;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _eventsSub?.cancel();
    if (_ownsBackend) {
      _backend!.dispose();
    }
    super.dispose();
  }

  bool _disposed = false;
}
