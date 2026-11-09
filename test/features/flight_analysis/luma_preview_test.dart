import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dart_control_panel/features/flight_analysis/luma_preview.dart';

void main() {
  final image = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAFklEQVR4nGNk+M/AwMDAxMDAwMDAAAAMHgEDBINhkwAAAABJRU5ErkJggg==',
  );
  Map<String, Object> message() => {
    'frame': 3,
    'width': 640,
    'height': 360,
    'found': true,
    'rect': [20, 30, 40, 50],
    'pixels': 200,
    'rgb': image,
    'y': image,
    'mask': image,
  };
  test('preview frame validates the native message', () {
    final frame = LumaPreviewFrame.fromMessage(message());
    expect(frame?.number, 3);
    expect(frame?.rect, [20, 30, 40, 50]);
    expect(
      LumaPreviewFrame.fromMessage({
        ...message(),
        'rect': [1],
      }),
      isNull,
    );
    expect(
      LumaPreviewFrame.fromMessage({...message(), 'mask': 'not bytes'}),
      isNull,
    );
  });
  testWidgets('three synchronized panels fit on a handset', (tester) async {
    tester.view.physicalSize = const Size(800, 363);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LumaPreviewPanels(
            frame: LumaPreviewFrame.fromMessage(message()),
          ),
        ),
      ),
    );
    for (
      var i = 0;
      i < 20 && find.textContaining('第 3 帧').evaluate().isEmpty;
      i++
    ) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      });
      await tester.pump();
    }
    expect(find.text('原画面 / 检测框'), findsOneWidget);
    expect(find.text('解码 Y 平面'), findsOneWidget);
    expect(find.text('阈值掩码'), findsOneWidget);
    expect(find.textContaining('第 3 帧'), findsOneWidget);
    expect(find.byType(RawImage), findsNWidgets(3));
    final main = find.byKey(const ValueKey('analysis-channel-0'));
    final mainImage = find.descendant(
      of: main,
      matching: find.byType(RawImage),
    );
    expect(
      tester.getRect(find.text('原画面 / 检测框')).right,
      lessThanOrEqualTo(tester.getRect(mainImage).left),
    );
    for (var i = 0; i < 3; i++) {
      expect(find.byKey(ValueKey('analysis-detection-box-$i')), findsOneWidget);
    }
    await tester.tap(find.byKey(const ValueKey('analysis-show-detection-box')));
    await tester.pump();
    for (var i = 0; i < 3; i++) {
      expect(find.byKey(ValueKey('analysis-detection-box-$i')), findsNothing);
    }
    await tester.tap(find.byKey(const ValueKey('analysis-show-detection-box')));
    await tester.pump();
    for (var i = 0; i < 3; i++) {
      expect(find.byKey(ValueKey('analysis-detection-box-$i')), findsOneWidget);
    }
    for (final selected in [1, 2, 0]) {
      final oldSelected = (selected + 2) % 3;
      final oldWidth = tester
          .getSize(find.byKey(ValueKey('analysis-channel-$oldSelected')))
          .width;
      final previousWidth = tester
          .getSize(find.byKey(ValueKey('analysis-channel-$selected')))
          .width;
      await tester.tap(find.byKey(ValueKey('analysis-channel-$selected')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 180));
      expect(
        tester
            .getSize(find.byKey(ValueKey('analysis-channel-$selected')))
            .width,
        greaterThan(previousWidth),
      );
      expect(
        tester
            .getSize(find.byKey(ValueKey('analysis-channel-$oldSelected')))
            .width,
        lessThan(oldWidth),
      );
      await tester.pumpAndSettle();
      final mainSize = tester.getSize(
        find.byKey(ValueKey('analysis-channel-$selected')),
      );
      for (var index = 0; index < 3; index++) {
        if (index == selected) continue;
        final thumbnailSize = tester.getSize(
          find.byKey(ValueKey('analysis-channel-$index')),
        );
        expect(mainSize.width, greaterThan(thumbnailSize.width));
        expect(mainSize.height, greaterThan(thumbnailSize.height));
      }
      expect(find.textContaining('第 3 帧'), findsOneWidget);
      expect(find.byType(RawImage), findsNWidgets(3));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'invalid next image never updates frame label or part of panels',
    (tester) async {
      Future<void> settleImages() async {
        for (var i = 0; i < 20; i++) {
          await tester.runAsync(
            () async => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
        }
      }

      Widget page(LumaPreviewFrame frame) => MaterialApp(
        home: Scaffold(body: LumaPreviewPanels(frame: frame)),
      );
      final first = LumaPreviewFrame.fromMessage(message())!;
      await tester.pumpWidget(page(first));
      await settleImages();
      expect(find.textContaining('第 3 帧'), findsOneWidget);
      final invalid = LumaPreviewFrame.fromMessage({
        ...message(),
        'frame': 4,
        'y': Uint8List.fromList([1, 2, 3]),
      })!;
      await tester.pumpWidget(page(invalid));
      await settleImages();
      expect(find.textContaining('第 3 帧'), findsOneWidget);
      expect(find.textContaining('第 4 帧'), findsNothing);
      expect(find.byType(RawImage), findsNWidgets(3));
      final valid = LumaPreviewFrame.fromMessage({...message(), 'frame': 5})!;
      await tester.pumpWidget(page(valid));
      await settleImages();
      expect(find.textContaining('第 5 帧'), findsOneWidget);
    },
  );
  testWidgets('backward seek keeps old triplet until replacement is decoded', (
    tester,
  ) async {
    Future<void> settleImages() async {
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(
          () async => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
    }

    Widget page(LumaPreviewFrame frame, int generation) => MaterialApp(
      home: Scaffold(
        body: LumaPreviewPanels(frame: frame, generation: generation),
      ),
    );
    final first = LumaPreviewFrame.fromMessage({...message(), 'frame': 8})!;
    await tester.pumpWidget(page(first, 0));
    await settleImages();
    expect(find.textContaining('第 8 帧'), findsOneWidget);
    final invalid = LumaPreviewFrame.fromMessage({
      ...message(),
      'frame': 2,
      'mask': Uint8List.fromList([1, 2, 3]),
    })!;
    await tester.pumpWidget(page(invalid, 1));
    await settleImages();
    expect(find.textContaining('第 8 帧'), findsOneWidget);
    expect(find.byType(RawImage), findsNWidgets(3));
    final earlier = LumaPreviewFrame.fromMessage({...message(), 'frame': 2})!;
    await tester.pumpWidget(page(earlier, 2));
    // A new request must not clear any of the previous panels while decoding.
    expect(find.byType(RawImage), findsNWidgets(3));
    await settleImages();
    expect(find.textContaining('第 2 帧'), findsOneWidget);
    expect(find.byType(RawImage), findsNWidgets(3));
  });
}
