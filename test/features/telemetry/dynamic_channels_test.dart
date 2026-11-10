import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_controller.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_source.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_sample.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_screen.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_chart.dart';
import 'package:dart_control_panel/features/telemetry/udp_telemetry_source.dart';

class ManualSource implements TelemetrySource {
  void Function(TelemetrySample)? callback;
  @override
  String get label => 'test';
  @override
  void start(void Function(TelemetrySample) onSample) => callback = onSample;
  @override
  Future<void> stop() async {
    callback = null;
  }

  void emit(Map<String, double> values) =>
      callback?.call(TelemetrySample(time: DateTime.now(), values: values));
}

void main() {
  test(
    'TCP registry exposes every field/type before the first UDP sample',
    () async {
      final fixture =
          jsonDecode(
                File(
                  'test/features/telemetry/fixtures/dvt1.json',
                ).readAsStringSync(),
              )
              as Map;
      final json = Map<String, dynamic>.from(fixture['schema'] as Map);
      final source = UdpTelemetrySource();
      final controller = TelemetryController(source: source);
      addTearDown(controller.dispose);
      var notifications = 0;
      controller.addListener(() => notifications++);
      source.configureSchemaLoader(() async => json);
      await Future<void>.delayed(Duration.zero);
      expect(controller.latest, isNull);
      final channels = {for (final c in controller.channels) c.id: c};
      for (final f in json['fields']) {
        expect(channels[f['name']], isNotNull);
        expect(channels[f['name']]!.type, f['type']);
      }
      expect(notifications, greaterThan(0));
      expect(channels['seq']!.type, 'uint32');
      source.configureSchemaLoader(null);
      expect(controller.channels.any((c) => c.id == 'uart_rx_u8'), isFalse);
    },
  );
  test('legacy unknown values join the registry, selection and history', () {
    final source = ManualSource();
    final c = TelemetryController(source: source);
    addTearDown(c.dispose);
    c.start();
    source.emit({'pitch': 1, 'uart_rx_voltage': 12.5, 'custom_counter': 9});
    expect(
      c.channels.map((f) => f.id),
      containsAll(['uart_rx_voltage', 'custom_counter']),
    );
    c.toggleChannel('uart_rx_voltage');
    expect(c.selected, contains('uart_rx_voltage'));
    expect(c.seriesFor('uart_rx_voltage').single.value, 12.5);
    final registry = c.channels;
    source.emit({'pitch': 2, 'uart_rx_voltage': 13, 'custom_counter': 10});
    expect(identical(registry, c.channels), isTrue);
    c.clear();
    expect(c.channels.any((f) => f.id == 'uart_rx_voltage'), isFalse);
  });
  testWidgets(
    'unknown returned field has a selectable sidebar row and plotted series',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final source = ManualSource();
      final c = TelemetryController(source: source);
      addTearDown(c.dispose);
      await tester.pumpWidget(
        MaterialApp(home: TelemetryScreen(controller: c)),
      );
      source.emit({
        'pitch': 1,
        'uart_rx_voltage': 12.5,
        for (var i = 0; i < 63; i++) 'uart_rx_extra_$i': i.toDouble(),
      });
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.byType(TextField));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'uart_rx_voltage');
      await tester.pumpAndSettle();
      expect(find.byType(Checkbox), findsOneWidget);
      final chip = find.byWidgetPredicate(
        (w) => w is Text && w.data == 'uart_rx_voltage',
      );
      expect(chip, findsOneWidget);
      await tester.ensureVisible(chip);
      await tester.tap(chip);
      await tester.pump();
      expect(c.selected, contains('uart_rx_voltage'));
      final chart = tester.widget<TelemetryChart>(find.byType(TelemetryChart));
      expect(
        chart.controller.channels.any((f) => f.id == 'uart_rx_voltage'),
        isTrue,
      );
      final paint = find.descendant(
        of: find.byType(TelemetryChart),
        matching: find.byKey(const ValueKey('telemetry-chart-plot')),
      );
      final dynamic painter = tester.widget<CustomPaint>(paint.first).painter;
      final Map<TelemetryChannel, dynamic> series = painter.series;
      expect(series.keys.any((f) => f.id == 'uart_rx_voltage'), isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}
