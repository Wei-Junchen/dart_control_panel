import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_archive.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_controller.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_wire.dart';
import 'package:dart_control_panel/features/telemetry/udp_telemetry_source.dart';

void main() {
  test(
    'DVT1 loopback receiver records every accepted packet and rejects bad/duplicate packets',
    () async {
      final root = await Directory.systemTemp.createTemp('udp-archive-');
      final probe = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final port = probe.port;
      probe.close();
      final sender = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final fixture = jsonDecode(
        await File('test/features/telemetry/fixtures/dvt1.json').readAsString(),
      );
      final hex = fixture['hex'] as String;
      final template = Uint8List.fromList([
        for (var i = 0; i < hex.length; i += 2)
          int.parse(hex.substring(i, i + 2), radix: 16),
      ]);
      final source = UdpTelemetrySource(port: port);
      final recorder = TelemetryRecorder(directory: root);
      final controller = TelemetryController(
        source: source,
        recorder: recorder,
      );
      try {
        source.configureSchemaLoader(
          () async => Map<String, dynamic>.from(fixture['schema']),
          peer: '127.0.0.1',
        );
        controller.start();
        await Future<void>.delayed(const Duration(milliseconds: 80));
        Uint8List packet(int seq) {
          final bytes = Uint8List.fromList(template);
          final data = ByteData.sublistView(bytes);
          data.setUint32(8, seq, Endian.little);
          data.setUint32(
            bytes.length - 4,
            TelemetryWire.crc32(bytes, bytes.length - 4),
            Endian.little,
          );
          return bytes;
        }

        for (var seq = 0; seq < 120; seq++) {
          sender.send(packet(seq), InternetAddress.loopbackIPv4, port);
          if (seq % 20 == 19) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        }
        sender.send(
          packet(119),
          InternetAddress.loopbackIPv4,
          port,
        ); // duplicate
        final invalid = packet(120)..[20] ^= 1; // bad CRC
        sender.send(invalid, InternetAddress.loopbackIPv4, port);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await recorder.flush();
        expect(source.packets, 120);
        expect(source.parseErrors, 1);
        expect(recorder.written, source.packets);
        expect(recorder.dropped, 0);
        final snapshot = await TelemetryArchive.open(recorder.current!);
        await controller.openArchive(snapshot);
        final frozen = controller.latest!.values['seq'];
        sender.send(packet(120), InternetAddress.loopbackIPv4, port);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(source.packets, 121);
        expect(controller.latest!.values['seq'], frozen);
        await source.stop();
        await recorder.close();
        final archive = await TelemetryArchive.open(recorder.current!);
        final rows = await archive.range(0, archive.durationUs).toList();
        expect(rows.length, 121);
        expect(
          rows.map((r) => r.sample.values['seq']),
          List.generate(121, (i) => i.toDouble()),
        );
        expect(rows.last.sample.values['uart_rx_i32'], -2147483648);
        expect(rows.last.sample.values['uart_rx_f32'], 1.25);
        expect(
          archive.metadata['schema']['schema_id'],
          fixture['schema']['schema_id'],
        );
        expect(archive.metadata['receiver_end']['parse_errors'], 1);
        expect(archive.metadata['source'], '127.0.0.1');
      } finally {
        sender.close();
        await source.stop();
        await recorder.close();
        controller.dispose();
        await Future<void>.delayed(Duration.zero);
        await root.delete(recursive: true);
      }
    },
  );
}
