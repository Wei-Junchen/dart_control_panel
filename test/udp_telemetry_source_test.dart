import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:dart_control_panel/telemetry/telemetry_sample.dart';
import 'package:dart_control_panel/telemetry/udp_telemetry_source.dart';

void main() {
  test(
    'receives a complete FireWater UDP datagram and maps UI aliases',
    () async {
      final probe = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final port = probe.port;
      probe.close();

      final source = UdpTelemetrySource(port: port);
      final received = Completer<TelemetrySample>();
      source.start((sample) {
        if (!received.isCompleted) received.complete(sample);
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final sender = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final packet = utf8.encode(
        'seq:8,uart_valid:1,uart_pitch:1.25,uart_roll:-2.5,'
        'uart_yaw:3.75,capture_fps:80.2,target_x:123\n',
      );
      sender.send(packet, InternetAddress.loopbackIPv4, port);

      final sample = await received.future.timeout(const Duration(seconds: 2));
      expect(sample.valueOf('pitch'), 1.25);
      expect(sample.valueOf('roll'), -2.5);
      expect(sample.valueOf('yaw'), 3.75);
      expect(sample.valueOf('fps'), 80.2);
      expect(sample.valueOf('target_x'), 123);
      expect(source.packets, 1);

      sender.close();
      await source.stop();
    },
  );

  test(
    'accepts consecutive FireWater samples without identity filtering',
    () async {
      final probe = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final port = probe.port;
      probe.close();
      final source = UdpTelemetrySource(port: port);
      final received = <TelemetrySample>[];
      source.start(received.add);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final sender = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      sender.send(
        utf8.encode('seq:1,capture_fps:60\n'),
        InternetAddress.loopbackIPv4,
        port,
      );
      sender.send(
        utf8.encode('seq:2,capture_fps:80\n'),
        InternetAddress.loopbackIPv4,
        port,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(received.map((sample) => sample.valueOf('fps')), [60, 80]);
      expect(source.packets, 2);
      sender.close();
      await source.stop();
    },
  );
}
