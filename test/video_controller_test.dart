import 'package:flutter_test/flutter_test.dart';

import 'package:dart_control_panel/controllers/video_controller.dart';
import 'package:dart_control_panel/video/media_kit_backend.dart';
import 'package:dart_control_panel/video/video_backend.dart';

import 'helpers/fake_video_backend.dart';

void main() {
  late FakeVideoBackend backend;
  late VideoController controller;

  setUp(() {
    backend = FakeVideoBackend();
    controller = VideoController(backend: backend);
  });

  tearDown(() {
    controller.dispose();
  });

  /// Flush microtasks so broadcast-stream events reach the controller.
  Future<void> flush() => pumpEventQueue();

  test(
    'open goes idle -> connecting, then decoder events drive status',
    () async {
      expect(controller.status, VideoStatus.idle);
      final openFuture = controller.open('rtsp://10.149.242.1:8554/live');
      expect(controller.status, VideoStatus.connecting);
      await openFuture;
      expect(backend.lastUrl, 'rtsp://10.149.242.1:8554/live');

      backend.emitBuffering();
      await flush();
      expect(controller.status, VideoStatus.buffering);
      backend.emitPlaying();
      await flush();
      expect(controller.status, VideoStatus.playing);
      expect(controller.isActive, isTrue);
      backend.emitPaused();
      await flush();
      expect(controller.status, VideoStatus.paused);
      expect(controller.isActive, isFalse);
    },
  );

  test('reconnect after stream error rebuilds only the player', () async {
    await controller.open('rtsp://host:8554/live');
    backend.emitError('connection lost');
    await flush();
    expect(controller.status, VideoStatus.error);
    expect(controller.lastError, 'connection lost');
    expect(controller.url, 'rtsp://host:8554/live');

    await controller.reconnect();
    expect(backend.openCalls, 2);
    expect(backend.closeCalls, 1);
    expect(controller.reconnectCount, 1);
    backend.emitPlaying();
    await flush();
    expect(controller.status, VideoStatus.playing);
    expect(controller.lastError, isNull);
  });

  test('open error surfaces and keeps the url for retry', () async {
    backend.openError = StateError('no route to host');
    await controller.open('rtsp://host:8554/live');
    expect(controller.status, VideoStatus.error);
    expect(controller.lastError, contains('no route to host'));
    // retry with a healthy backend
    backend.openError = null;
    await controller.reconnect();
    backend.emitPlaying();
    await flush();
    expect(controller.status, VideoStatus.playing);
  });

  test('second open while in flight is ignored (no pileup)', () async {
    var firstDone = false;
    final slow = _SlowBackend(
      onOpen: () async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        firstDone = true;
      },
    );
    final c = VideoController(backend: slow);
    final f1 = c.open('rtsp://host:8554/live');
    final f2 = c.open('rtsp://another:8554/live'); // must be ignored
    await f1;
    await f2;
    expect(slow.openCalls, 1);
    expect(firstDone, isTrue);
    c.dispose();
  });

  test('pause/resume/stop delegate to the backend', () async {
    await controller.open('rtsp://host:8554/live');
    backend.emitPlaying();
    await flush();
    await controller.pause();
    await controller.resume();
    await controller.stop();
    expect(backend.pauseCalls, 1);
    expect(backend.resumeCalls, 1);
    expect(backend.closeCalls, 1);
    expect(controller.status, VideoStatus.idle);
  });

  test('stopped event maps back to idle', () async {
    await controller.open('rtsp://host:8554/live');
    backend.emitPlaying();
    await flush();
    backend.emitStopped();
    await flush();
    expect(controller.status, VideoStatus.idle);
  });

  test('dispose cancels backend subscriptions', () async {
    controller.dispose();
    expect(backend.disposeCalls, 0); // backend itself is disposed by owner
    // emitting after dispose must not throw
    backend.emitPlaying();
    await flush();
  });

  test('live backend defaults cannot accumulate a playback cache', () {
    expect(MediaKitBackend.defaultRtspTransport, 'tcp');
    expect(MediaKitBackend.defaultBufferSize, lessThanOrEqualTo(1024 * 1024));
    expect(MediaKitBackend.defaultOpenOptions['cache'], 'no');
    expect(MediaKitBackend.defaultOpenOptions['cache-on-disk'], 'no');
    expect(MediaKitBackend.defaultOpenOptions['cache-pause'], 'no');
    expect(MediaKitBackend.defaultOpenOptions['demuxer-readahead-secs'], '0');
    expect(
      MediaKitBackend.defaultOpenOptions['demuxer-lavf-o'],
      contains('nobuffer'),
    );
    expect(
      MediaKitBackend.defaultOpenOptions['vd-lavc-o'],
      contains('low_delay'),
    );
    expect(MediaKitBackend.defaultOpenOptions['framedrop'], 'yes');
  });

  test('live mode is opt-in so recording playback keeps normal timing', () {
    final recording = VideoController(backend: FakeVideoBackend());
    final live = VideoController(backend: FakeVideoBackend(), liveStream: true);
    expect(recording.liveStream, isFalse);
    expect(live.liveStream, isTrue);
    recording.dispose();
    live.dispose();
  });
}

class _SlowBackend extends FakeVideoBackend {
  _SlowBackend({required this.onOpen});
  final Future<void> Function() onOpen;

  @override
  Future<void> open(String url) async {
    openCalls++;
    await onOpen();
  }
}
