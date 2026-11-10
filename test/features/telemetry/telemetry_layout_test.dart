import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_controller.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_sample.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_screen.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_chart.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_source.dart';

class Push implements TelemetrySource {
  void Function(TelemetrySample)? receive;
  @override
  String get label => 'preview';
  @override
  void start(void Function(TelemetrySample) f) {
    receive = f;
  }

  @override
  Future<void> stop() async {}
}

void main() {
  for (final size in [const Size(1440, 900), const Size(1280, 720)]) {
    testWidgets(
      'desktop ${size.width} has chart-first layout and searchable right sidebar',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        if (Platform.environment['DART_UI_PREVIEW'] == '1') {
          await tester.runAsync(() async {
            final loader = FontLoader('PreviewFont')
              ..addFont(
                File(
                  '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
                ).readAsBytes().then((b) => ByteData.sublistView(b)),
              );
            await loader.load();
            final icons = FontLoader('MaterialIcons')
              ..addFont(
                File(
                  'build/linux/x64/release/bundle/data/flutter_assets/fonts/MaterialIcons-Regular.otf',
                ).readAsBytes().then((b) => ByteData.sublistView(b)),
              );
            await icons.load();
          });
        }
        final source = Push();
        final c = TelemetryController(source: source);
        const key = ValueKey('preview-root');
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              useMaterial3: true,
              colorSchemeSeed: Colors.teal,
              fontFamily: Platform.environment['DART_UI_PREVIEW'] == '1'
                  ? 'PreviewFont'
                  : null,
            ),
            home: RepaintBoundary(
              key: key,
              child: TelemetryScreen(controller: c),
            ),
          ),
        );
        final now = DateTime.now();
        for (var i = 0; i < 2000; i++) {
          final t = i / 100.0;
          source.receive!(
            TelemetrySample(
              time: now.subtract(Duration(milliseconds: 20000 - i * 10)),
              values: {
                'pitch': sin(t) * 35,
                'roll': cos(t * .8) * 40,
                'yaw': sin(t * .4) * 25 - 30,
                'capture_fps': 73.5,
                'uart_rx_gyro_x': sin(t) * 3,
                'uart_rx_roll_out_ref': 4,
                'uart_rx_servo0': 25,
                'uart_rx_vision_pitch': 5,
                'uart_rx_ins_height': 123,
                'uart_rx_air_speed': 18,
                for (var f = 0; f < 50; f++) 'uart_rx_extra_$f': f.toDouble(),
              },
            ),
          );
        }
        await tester.pumpAndSettle();
        final sidebar = find.byKey(const ValueKey('telemetry-channel-sidebar'));
        final chart = find.byType(TelemetryChart);
        expect(
          tester.getRect(sidebar).left,
          greaterThan(tester.getRect(chart).right),
        );
        expect(tester.getSize(chart).height, greaterThan(300));
        expect(tester.takeException(), isNull);
        if (Platform.environment['DART_UI_PREVIEW'] == '1') {
          await tester.runAsync(() async {
            final image = await tester
                .renderObject<RenderRepaintBoundary>(find.byKey(key))
                .toImage();
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            image.dispose();
            final output = File(
              'build/diagnostics/curve-ui/preview-${size.width.toInt()}.png',
            );
            await output.parent.create(recursive: true);
            await output.writeAsBytes(data!.buffer.asUint8List());
          });
        }
        await tester.enterText(
          find.byKey(const ValueKey('telemetry-channel-search')),
          'uart_rx_gyro_x',
        );
        await tester.pumpAndSettle();
        expect(
          find.text('uart_rx_gyro_x', findRichText: false).last,
          findsOneWidget,
        );
        await tester.tap(find.text('uart_rx_gyro_x', findRichText: false).last);
        await tester.pump();
        expect(c.selected, contains('uart_rx_gyro_x'));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        c.dispose();
      },
    );
  }
}
