import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_control_panel/features/flight_analysis/luma_analysis_screen.dart';
import 'package:dart_control_panel/features/flight_analysis/luma_analysis_service.dart';
import 'package:dart_control_panel/features/flight_analysis/luma_preview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeAnalysis extends LumaAnalysisService {
  int prepares = 0, scans = 0;
  bool failPrepare = false;
  Completer<void>? readGate;
  final reads = <({int frame, int threshold})>[];
  @override
  Future<Map<String, dynamic>> analyze(
    File video,
    Map<String, int> thresholds, {
    String mode = 'nv21_green',
    Map<String, num> luma = const {},
    Map<String, dynamic> detectorConfig = const {},
    void Function(Map<dynamic, dynamic>)? onFrame,
    bool pacePreview = true,
    int? targetFrame,
    bool cacheAll = false,
    void Function(int)? onProgress,
  }) async {
    if (cacheAll) {
      prepares++;
      onProgress?.call(3);
      if (failPrepare) throw StateError('缓存失败');
      return {
        'video': {'frames': 5},
        'runs': [],
      };
    }
    scans++;
    return {
      'video': {'frames': 5},
      'runs': [
        {
          'summary': {'frames': 5, 'found': 1},
        },
      ],
    };
  }

  @override
  Future<Map<dynamic, dynamic>> readCachedFrame(
    int frame,
    Map<String, int> thresholds, {
    String mode = 'nv21_green',
    Map<String, num> luma = const {},
    Map<String, dynamic> detectorConfig = const {},
  }) async {
    reads.add((
      frame: frame,
      threshold: (luma['luma_threshold'] ?? 80).toInt(),
    ));
    await readGate?.future;
    final image = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAFklEQVR4nGNk+M/AwMDAxMDAwMDAAAAMHgEDBINhkwAAAABJRU5ErkJggg==',
    );
    return {
      'frame': frame,
      'width': 2,
      'height': 2,
      'pixels': 1,
      'found': false,
      'rect': [0, 0, 0, 0],
      'rgb': image,
      'y': image,
      'mask': image,
    };
  }

  @override
  void dispose() {}
}

void main() {
  testWidgets('drag previews frames and coalesces slow reads before release', (
    tester,
  ) async {
    final service = FakeAnalysis();
    await tester.pumpWidget(
      MaterialApp(
        home: LumaAnalysisScreen(
          video: File('/tmp/f.h264'),
          service: service,
          previewSupported: true,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    final gate = service.readGate = Completer<void>();
    final slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChanged!(2);
    slider.onChanged!(3);
    slider.onChanged!(4);
    await tester.pump();
    expect(service.reads.map((read) => read.frame), [1, 2]);
    gate.complete();
    await tester.pump();
    await tester.pump();
    expect(service.reads.map((read) => read.frame), [1, 2, 4]);
    expect(
      tester
          .widget<LumaPreviewPanels>(find.byType(LumaPreviewPanels))
          .frame
          ?.number,
      4,
    );
    slider.onChangeEnd!(4);
    await tester.pump();
    expect(service.reads.map((read) => read.frame), [1, 2, 4]);
  });

  testWidgets('landscape keeps a full-height preview left of the settings', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 363);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: LumaAnalysisScreen(
          video: File('/tmp/f.h264'),
          service: FakeAnalysis(),
          previewSupported: true,
        ),
      ),
    );
    await tester.pump();
    final main = tester.getRect(
      find.byKey(const ValueKey('analysis-channel-0')),
    );
    final settings = tester.getRect(
      find.byKey(const ValueKey('analysis-settings')),
    );
    expect(main.right, lessThanOrEqualTo(settings.left));
    expect(main.height, greaterThan(170));
    expect(tester.takeException(), isNull);
  });

  testWidgets('automatically caches on entry and allows retry after failure', (
    tester,
  ) async {
    final service = FakeAnalysis()..failPrepare = true;
    await tester.pumpWidget(
      MaterialApp(
        home: LumaAnalysisScreen(
          video: File('/tmp/f.h264'),
          service: service,
          previewSupported: true,
        ),
      ),
    );
    await tester.pump();
    expect(service.prepares, 1);
    expect(find.textContaining('缓存失败'), findsOneWidget);
    service.failPrepare = false;
    await tester.tap(find.text('准备视频').first);
    await tester.pump();
    expect(service.prepares, 2);
    expect(service.reads.single.frame, 1);
  });

  testWidgets(
    'prepares once and reevaluates only selected frame on edit and seek',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final service = FakeAnalysis();
      await tester.pumpWidget(
        MaterialApp(
          home: LumaAnalysisScreen(
            video: File('/tmp/f.h264'),
            service: service,
            previewSupported: true,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(service.prepares, 1);
      expect(service.reads.last, (frame: 1, threshold: 80));
      await tester.tap(find.byTooltip('下一帧'));
      await tester.pump();
      expect(service.reads.last, (frame: 2, threshold: 80));
      final input = find.byKey(const ValueKey('luma-luma_threshold'));
      await tester.ensureVisible(input);
      await tester.enterText(input, '100');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();
      expect(service.reads.last, (frame: 2, threshold: 100));
      expect(service.prepares, 1);
      expect(service.scans, 0);
      await tester.ensureVisible(find.text('nv21_green'));
      await tester.tap(find.text('nv21_green'));
      await tester.pump();
      final green = find.byKey(const ValueKey('green-green_y_min'));
      await tester.ensureVisible(green);
      await tester.enterText(green, '');
      await tester.pump();
      expect(find.textContaining('参数无效'), findsOneWidget);
      await tester.enterText(green, '21');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();
      expect(find.textContaining('参数无效'), findsNothing);
      expect(service.prepares, 1);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('全片统计').last);
      await tester.tap(find.text('全片统计').last);
      await tester.pump();
      expect(service.scans, 1);
      expect(service.prepares, 1);
    },
  );
}
