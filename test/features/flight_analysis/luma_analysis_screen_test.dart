import 'dart:io';

import 'package:dart_control_panel/features/flight_analysis/luma_analysis_screen.dart';
import 'package:flutter/material.dart';
import 'package:dart_control_panel/core/board/session/board_config_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('offline mode defaults to ellipse and switches independently', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: LumaAnalysisScreen(video: File('/tmp/sample.h264'))),
    );
    expect(find.text('luma_ellipse'), findsOneWidget);
    expect(find.text('nv21_green'), findsOneWidget);
    expect(find.text('luma_threshold'), findsOneWidget);
    expect(find.text('ellipse_green_min_fraction'), findsOneWidget);
    expect(find.text('green_y_min'), findsNothing);
    await tester.tap(find.text('nv21_green'));
    await tester.pump();
    expect(find.text('luma_threshold'), findsNothing);
    expect(find.text('green_y_min'), findsOneWidget);
    await tester.tap(find.text('luma_ellipse'));
    await tester.pump();
    expect(find.text('luma_threshold'), findsOneWidget);
    expect(find.text('green_y_min'), findsNothing);
  });

  testWidgets('compact layout hides details until requested', (tester) async {
    tester.view.physicalSize = const Size(800, 363);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: LumaAnalysisScreen(video: File('/tmp/sample.h264'))),
    );
    expect(find.textContaining('/tmp/sample.h264'), findsNothing);
    expect(find.text('luma_ellipse'), findsOneWidget);
    expect(find.text('nv21_green'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('分析说明'));
    await tester.pumpAndSettle();
    expect(find.textContaining('/tmp/sample.h264'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('analysis initializes from connection snapshot', (tester) async {
    final snapshot = BoardConfigSnapshot(
      config: {
        'detector': {'mode': 'nv21_green', 'green_y_min': 123, 'roi': 'auto'},
      },
      capturedAt: DateTime.utc(2026),
      host: 'board',
      port: 9000,
      resolvedRoi: [10, 10, 100, 80],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: LumaAnalysisScreen(
          video: File('/tmp/sample.h264'),
          snapshot: snapshot,
        ),
      ),
    );
    final chip = tester.widget<ChoiceChip>(
      find
          .ancestor(
            of: find.text('nv21_green'),
            matching: find.byType(ChoiceChip),
          )
          .first,
    );
    expect(chip.selected, isTrue);
    expect(find.text('123'), findsOneWidget);
    expect(find.textContaining('连接时配置（录像时可能不同）'), findsOneWidget);
  });
}
