import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_archive.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_controller.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_source.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_sample.dart';

class Push implements TelemetrySource {
  void Function(TelemetrySample)? receive;
  @override
  String get label => 'test';
  @override
  void start(void Function(TelemetrySample) f) {
    receive = f;
  }

  @override
  Future<void> stop() async {}
}

void main() {
  test('seek during uninterrupted ingress', () async {
    final root = await Directory.systemTemp.createTemp('live-scrub-');
    final r = TelemetryRecorder(directory: root);
    final src = Push();
    final c = TelemetryController(source: src, recorder: r)..start();
    await c.beginConnection('test');
    var seq = 0;
    final timer = Timer.periodic(const Duration(milliseconds: 1), (_) {
      src.receive!(
        TelemetrySample(
          time: DateTime.now(),
          values: {
            'seq': (++seq).toDouble(),
            'pitch': seq.toDouble(),
            for (var i = 0; i < 90; i++) 'field_$i': seq.toDouble(),
          },
        ),
      );
    });
    try {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      c.pauseDisplay();
      final frozen = c.timelineDurationUs;
      final t = frozen ~/ 2;
      final watch = Stopwatch()..start();
      await c.seekTimeline(t).timeout(const Duration(seconds: 3));
      expect(watch.elapsedMilliseconds, lessThan(3000));
      expect(c.cursorUs, t);
      final firstSeq = c.latest!.values['seq']!;
      final written = r.written;
      await c.seekTimeline(t ~/ 2).timeout(const Duration(seconds: 3));
      expect(c.cursorUs, t ~/ 2);
      expect(c.latest!.values['seq'], lessThan(firstSeq));
      expect(
        c.seriesFor('pitch').any((p) => p.value == c.latest!.values['pitch']),
        true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await r.flush().timeout(const Duration(seconds: 3));
      expect(r.written, greaterThan(written));
      expect(c.timelineDurationUs, frozen);
      expect(c.cursorUs, t ~/ 2);
      c.returnToLive();
      expect(c.latest!.values['seq'], greaterThan(firstSeq));
      expect(r.error, isNull);
    } finally {
      timer.cancel();
      await c.endConnection();
      await r.close();
      c.dispose();
      await root.delete(recursive: true);
    }
  });
}
