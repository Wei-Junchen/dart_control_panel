import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:dart_control_panel/features/flight_analysis/luma_analysis_service.dart';

class _SlowFile extends Fake implements File {
  final result = Completer<bool>();
  @override
  String get path => '/tmp/test.h264';
  @override
  Future<bool> exists() => result.future;
}

void main() {
  test('cancelling while checking the video does not start analysis', () async {
    final file = _SlowFile();
    final service = LumaAnalysisService();
    final result = service.analyze(file, {});
    final cancelled = expectLater(result, throwsStateError);
    service.cancel();
    file.result.complete(true);
    await cancelled;
  });

  test('snapshot detector options are validated and copied', () {
    final options = LumaAnalysisService.normalizedDetectorParameters({
      'roi': [3, 4, 50, 60],
      'search_radius': 40,
      'area_threshold': 42,
      'pixels_threshold': 13,
      'x_stride': 2,
      'y_stride': 3,
    });
    expect(options['roi'], [3, 4, 50, 60]);
    expect(options['search_radius'], 40);
    expect(options['area_threshold'], 42);
    expect(options['x_stride'], 2);
    expect(
      LumaAnalysisService.normalizedDetectorParameters({
        'roi': 'auto',
        'x_stride': 100,
      })['roi'],
      [0, 0, 0, 0],
    );
    expect(
      LumaAnalysisService.normalizedDetectorParameters({
        'x_stride': 100,
      })['x_stride'],
      1,
    );
  });

  test('real reference tool decodes local H264 and uses nv21_green', () async {
    final script = File(
      '/home/litwei/projects/DartVision2027/scripts/luma_tuner.py',
    );
    if (!Platform.isLinux || !await script.exists()) return;
    final temp = await Directory.systemTemp.createTemp('luma-service-test-');
    try {
      final file = File('${temp.path}/test.h264');
      final ffmpeg = await Process.run('ffmpeg', [
        '-v',
        'error',
        '-f',
        'lavfi',
        '-i',
        'color=c=green:s=64x48:r=5:d=1',
        '-pix_fmt',
        'yuv420p',
        '-c:v',
        'libx264',
        '-f',
        'h264',
        file.path,
      ]);
      expect(ffmpeg.exitCode, 0, reason: '${ffmpeg.stderr}');
      final before = await file.readAsBytes();
      final data = await LumaAnalysisService(script: script).analyze(file, {
        'green_y_min': 20,
        'green_g_min': 50,
        'green_score_min': 60,
        'green_rg_min': 20,
        'green_gb_min': 20,
      });
      final run = (data['runs'] as List).single as Map;
      expect((run['settings'] as Map)['mode'], 'nv21_green');
      expect((run['summary'] as Map)['frames'], 5);
      expect((run['summary'] as Map)['found'], 5);
      expect(await file.readAsBytes(), before);
      final strict = await LumaAnalysisService(script: script).analyze(file, {
        'green_y_min': 255,
        'green_g_min': 50,
        'green_score_min': 60,
        'green_rg_min': 20,
        'green_gb_min': 20,
      });
      final strictRun = (strict['runs'] as List).single as Map;
      expect((strictRun['summary'] as Map)['found'], 0);
      expect(
        ((strictRun['settings'] as Map)['green_thresholds'] as List).first,
        255,
      );
      final configured = await LumaAnalysisService(script: script).analyze(
        file,
        {
          'green_y_min': 20,
          'green_g_min': 50,
          'green_score_min': 60,
          'green_rg_min': 20,
          'green_gb_min': 20,
        },
        detectorConfig: {
          'roi': [4, 6, 30, 20],
          'search_radius': 15,
          'x_stride': 2,
        },
      );
      final settings =
          ((configured['runs'] as List).single as Map)['settings'] as Map;
      expect(settings['roi'], [4, 6, 30, 20]);
      expect(settings['radius'], 15);
      expect(settings['sample_step_x'], 2);
    } finally {
      await temp.delete(recursive: true);
    }
  });

  test(
    'luma ellipse uses reference algorithm and parameters on local H264',
    () async {
      final script = File(
        '/home/litwei/projects/DartVision2027/scripts/luma_tuner.py',
      );
      if (!Platform.isLinux || !await script.exists()) return;
      final temp = await Directory.systemTemp.createTemp(
        'ellipse-service-test-',
      );
      try {
        final ppm = File('${temp.path}/frame.ppm');
        final bytes = <int>[];
        for (var y = 0; y < 180; y++) {
          for (var x = 0; x < 320; x++) {
            final d = (x - 160) * (x - 160) + (y - 90) * (y - 90);
            bytes.addAll(
              d <= 15 * 15
                  ? [255, 255, 255]
                  : d <= 30 * 30
                  ? [0, 130, 0]
                  : [0, 0, 0],
            );
          }
        }
        await ppm.writeAsBytes([...('P6\n320 180\n255\n'.codeUnits), ...bytes]);
        final video = File('${temp.path}/test.h264');
        final result = await Process.run('ffmpeg', [
          '-y',
          '-v',
          'error',
          '-loop',
          '1',
          '-i',
          ppm.path,
          '-frames:v',
          '5',
          '-c:v',
          'libx264',
          '-pix_fmt',
          'yuv420p',
          '-bf',
          '0',
          '-f',
          'h264',
          video.path,
        ]);
        expect(result.exitCode, 0, reason: '${result.stderr}');
        const green = {
          'green_y_min': 20,
          'green_g_min': 50,
          'green_score_min': 60,
          'green_rg_min': 20,
          'green_gb_min': 20,
        };
        final before = await video.readAsBytes();
        final service = LumaAnalysisService(script: script);
        final data = await service.analyze(
          video,
          green,
          mode: 'luma_ellipse',
          luma: {'luma_threshold': 80, 'ellipse_green_min_fraction': 0.25},
        );
        final run = (data['runs'] as List).single as Map;
        expect((run['settings'] as Map)['mode'], 'luma_ellipse');
        expect((run['settings'] as Map)['threshold'], 80);
        expect((run['summary'] as Map)['frames'], 5);
        expect((run['summary'] as Map)['found'], 5);
        final strict = await service.analyze(
          video,
          green,
          mode: 'luma_ellipse',
          luma: {'luma_threshold': 255},
        );
        final strictRun = (strict['runs'] as List).single as Map;
        expect((strictRun['settings'] as Map)['threshold'], 255);
        expect((strictRun['summary'] as Map)['found'], 0);
        expect(await video.readAsBytes(), before);
      } finally {
        await temp.delete(recursive: true);
      }
    },
  );
}
