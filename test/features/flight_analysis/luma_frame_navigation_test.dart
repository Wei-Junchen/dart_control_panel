import 'package:dart_control_panel/features/flight_analysis/luma_frame_navigation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('track taps and drags away from the thumb do not seek', (
    tester,
  ) async {
    final seeks = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LumaFrameNavigation(
            total: 100,
            current: 1,
            enabled: true,
            onSeek: seeks.add,
          ),
        ),
      ),
    );
    final rect = tester.getRect(find.byType(Slider));
    final trackPoint = Offset(rect.right - 60, rect.center.dy);
    await tester.tapAt(trackPoint);
    await tester.pump();
    await tester.dragFrom(trackPoint, const Offset(-100, 0));
    await tester.pump();
    expect(seeks, isEmpty);
    final thumb = Offset(rect.left + 24, rect.center.dy);
    await tester.dragFrom(thumb, const Offset(100, 0));
    await tester.pump();
    expect(seeks, isNotEmpty);
    expect(seeks.last, greaterThan(1));
  });

  testWidgets('steps and previews while scrubbing after a complete scan', (
    tester,
  ) async {
    final seeks = <int>[];
    Widget page({int? total, int current = 1, bool enabled = true}) =>
        MaterialApp(
          home: Scaffold(
            body: LumaFrameNavigation(
              total: total,
              current: current,
              enabled: enabled,
              onSeek: seeks.add,
            ),
          ),
        );
    await tester.pumpWidget(page());
    expect(find.text('帧数未知'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.skip_next))
          .onPressed,
      isNull,
    );
    await tester.pumpWidget(page(total: 10, current: 1));
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.skip_previous),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.widgetWithIcon(IconButton, Icons.skip_next));
    expect(seeks, [2]);
    await tester.pumpWidget(page(total: 10, current: 10));
    expect(
      tester
          .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.skip_next))
          .onPressed,
      isNull,
    );
    await tester.tap(find.widgetWithIcon(IconButton, Icons.skip_previous));
    expect(seeks, [2, 9]);
    final slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChanged!(4);
    await tester.pump();
    expect(find.text('4 / 10'), findsOneWidget);
    expect(seeks, [2, 9, 4]);
    slider.onChangeEnd!(4);
    await tester.pump();
    expect(seeks, [2, 9, 4]);
    await tester.pumpWidget(page(total: 1));
    expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNull);
    await tester.pumpWidget(page(total: 10, enabled: false));
    expect(
      tester
          .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.skip_next))
          .onPressed,
      isNull,
    );
  });
}
