import 'dart:convert';
import 'dart:io';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_chart.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_controller.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_archive.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_sample.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_source.dart';

class Silent implements TelemetrySource {
  @override
  String get label => 'test';
  @override
  void start(void Function(TelemetrySample) onSample) {}
  @override
  Future<void> stop() async {}
}

class ProbeSource extends Silent {
  void Function(TelemetrySample)? callback;
  @override
  void start(void Function(TelemetrySample) onSample) {
    callback = onSample;
  }
}

void main() {
  testWidgets(
    'phone long press shows movable readings only while finger is held',
    (tester) async {
      tester.view.physicalSize = const Size(844, 390);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final source = ProbeSource();
      final c = TelemetryController(source: source)..start();
      source.callback!(
        TelemetrySample(
          time: DateTime.now(),
          values: {'pitch': 12.5, 'roll': -4, 'yaw': 2},
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
          home: Scaffold(body: TelemetryChart(controller: c)),
        ),
      );
      final plot = find.byKey(const ValueKey('telemetry-chart-plot'));
      await tester.tapAt(tester.getCenter(plot));
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byKey(const ValueKey('chart-probe')), findsNothing);
      final oldWindow = c.chartWindow;
      final finger = await tester.startGesture(tester.getCenter(plot));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byKey(const ValueKey('chart-probe')), findsOneWidget);
      expect(find.textContaining('Pitch: 12.5'), findsOneWidget);
      await finger.moveBy(const Offset(80, 20));
      await tester.pump();
      final dynamic painter = tester.widget<CustomPaint>(plot).painter;
      expect(painter.hover, isNotNull);
      expect(painter.hover.dx, greaterThan(tester.getSize(plot).width / 2));
      await finger.up();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('chart-probe')), findsNothing);
      expect(find.byKey(const ValueKey('chart-touch-probe')), findsNothing);
      expect(c.replaying, isFalse);
      expect(c.chartWindow, oldWindow);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );

  testWidgets('LogParser-style chart zoom, full view, drag and crosshair', (
    tester,
  ) async {
    late Directory root;
    final c = TelemetryController(source: Silent());
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('chart-navigation-');
      await File('${root.path}/metadata.json').writeAsString(
        jsonEncode({
          'format': 'dart_telemetry_csv_v1',
          'columns': ['pitch'],
          'complete': true,
        }),
      );
      final csv = StringBuffer('client_elapsed_us,client_received_at,pitch\n');
      for (var i = 0; i <= 100; i++) {
        csv.writeln('${i * 1000000},2026-10-18T00:00:00Z,$i');
      }
      await File('${root.path}/samples.csv').writeAsString('$csv');
      await c.openArchive(await TelemetryArchive.open(root));
      expect(c.chartWindow, 100);
      expect(c.chartFocusUs, 50000000);
      expect(c.cursorUs, 0);
      expect(c.chartRightUs, 100000000);
      expect(c.seriesFor('pitch').map((p) => p.value), containsAll([0, 100]));
      await c.seek(50000000);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TelemetryChart(controller: c)),
      ),
    );
    Future<void> settleAction(Future<void> Function() action) async {
      await tester.runAsync(() async {
        await action();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
    }

    await settleAction(
      () => tester.tap(find.byKey(const ValueKey('chart-X+'))),
    );
    expect(c.chartWindow, 80);
    expect(c.cursorUs, 50000000);
    await settleAction(
      () => tester.tap(find.byKey(const ValueKey('chart-全览'))),
    );
    expect(c.chartWindow, 100);
    expect(c.chartFocusUs, 50000000);
    final paint = find
        .descendant(
          of: find.byType(TelemetryChart),
          matching: find.byKey(const ValueKey('telemetry-chart-plot')),
        )
        .first;
    dynamic painter() => tester.widget<CustomPaint>(paint).painter;
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(paint));
    await tester.pump();
    expect(find.byKey(const ValueKey('chart-probe')), findsOneWidget);
    expect(painter().hover, isNotNull);
    final crosshair = tester.getCenter(paint);
    final probe = tester.getRect(find.byKey(const ValueKey('chart-probe')));
    expect(probe.left, greaterThan(crosshair.dx));
    expect(probe.bottom, lessThan(crosshair.dy));
    final plotted = painter().series;
    await mouse.moveTo(tester.getCenter(paint) + const Offset(20, 0));
    await tester.pump();
    final movedProbe = tester.getRect(
      find.byKey(const ValueKey('chart-probe')),
    );
    expect(movedProbe.left - probe.left, closeTo(20, .01));
    expect(
      identical(painter().series, plotted),
      true,
    ); // Hover does not rescan data.
    final plotRect = tester.getRect(paint);
    await mouse.moveTo(Offset(plotRect.right - 12, plotRect.top + 25));
    await tester.pump();
    final edgeProbe = tester.getRect(find.byKey(const ValueKey('chart-probe')));
    expect(edgeProbe.right, lessThanOrEqualTo(plotRect.right - 8));
    expect(edgeProbe.left, greaterThanOrEqualTo(plotRect.left + 48));
    expect(edgeProbe.top, greaterThanOrEqualTo(plotRect.top + 22));
    expect(edgeProbe.bottom, lessThanOrEqualTo(plotRect.bottom - 24));
    final beforeY = (painter().yMax - painter().yMin) as double;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await settleAction(
      () => tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(paint),
          scrollDelta: const Offset(0, -100),
        ),
      ),
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(c.chartWindow, lessThan(100));
    expect((painter().yMax - painter().yMin) as double, beforeY);
    final beforeX = c.chartWindow;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await settleAction(
      () => tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(paint),
          scrollDelta: const Offset(0, -100),
        ),
      ),
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(c.chartWindow, beforeX);
    expect((painter().yMax - painter().yMin) as double, lessThan(beforeY));
    await settleAction(
      () => c.inspectChart(centerUs: 50000000, windowSeconds: .5),
    );
    var xSpan = c.chartWindow;
    var ySpan = (painter().yMax - painter().yMin) as double;
    await settleAction(
      () => tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(paint),
          scrollDelta: const Offset(0, -100),
        ),
      ),
    );
    expect(c.chartWindow, lessThan(.5));
    expect(
      ((painter().yMax - painter().yMin) as double) / ySpan,
      closeTo(c.chartWindow / xSpan, 1e-8),
    );
    xSpan = c.chartWindow;
    ySpan = (painter().yMax - painter().yMin) as double;
    await settleAction(() async {
      final middle = await tester.startGesture(
        tester.getCenter(paint),
        kind: PointerDeviceKind.mouse,
        buttons: kMiddleMouseButton,
      );
      await middle.moveBy(const Offset(30, 20));
      await middle.up();
    });
    expect(c.chartWindow, greaterThan(xSpan));
    expect(
      ((painter().yMax - painter().yMin) as double) / ySpan,
      closeTo(c.chartWindow / xSpan, 1e-8),
    );
    xSpan = c.chartWindow;
    ySpan = (painter().yMax - painter().yMin) as double;
    await settleAction(() async {
      final center = tester.getCenter(paint);
      final first = await tester.startGesture(center - const Offset(50, 30));
      final second = await tester.startGesture(center + const Offset(50, 30));
      await first.moveTo(center - const Offset(75, 45));
      await second.moveTo(center + const Offset(75, 45));
      await first.up();
      await second.up();
    });
    expect(c.chartWindow, lessThan(xSpan));
    expect(
      ((painter().yMax - painter().yMin) as double) / ySpan,
      closeTo(c.chartWindow / xSpan, 1e-8),
    );
    final focus = c.chartFocusUs!;
    await settleAction(() => tester.drag(paint, const Offset(90, 0)));
    expect(c.chartFocusUs!, lessThan(focus));
    expect(
      c.cursorUs,
      c.chartFocusUs,
    ); // Dragged view and playback cursor agree.
    expect(tester.takeException(), isNull);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    await tester.runAsync(() => root.delete(recursive: true));
  });
}
