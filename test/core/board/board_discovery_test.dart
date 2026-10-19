import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:dart_control_panel/core/board/session/board_discovery.dart';
import '../../helpers/fixture_daemon.dart';

void main() {
  test(
    'derive .1 from all local 10.* IPv4, prefer Wi-Fi, deduplicate and skip self',
    () {
      final boards = BoardDiscovery.candidates(const [
        LocalBoardNetwork('eth0', '192.168.20.56'),
        LocalBoardNetwork('wlan0', '10.198.137.22'),
        LocalBoardNetwork('wlan0', '10.198.137.23'),
        LocalBoardNetwork('usb0', '10.149.242.5'),
        LocalBoardNetwork('lo', '127.0.0.1'),
        LocalBoardNetwork('docker0', '172.17.0.2'),
        LocalBoardNetwork('tun0', '10.1.2.5'),
        LocalBoardNetwork('rmnet_data0', '10.2.3.5'),
        LocalBoardNetwork('vEthernet (WSL)', '172.22.0.4'),
        LocalBoardNetwork('eth2', '169.254.12.4'),
        LocalBoardNetwork('eth3', '8.8.8.8'),
        LocalBoardNetwork('wlan1', '192.168.2.1'),
        LocalBoardNetwork('wlan2', '192.168.3.255'),
        LocalBoardNetwork('wlan3', '192.168.3.0'),
        LocalBoardNetwork('wlan4', 'fe80::1'),
        LocalBoardNetwork('wlan5', 'not-ip'),
      ]);
      expect(boards.map((b) => b.host).toSet(), {
        '10.198.137.1',
        '10.149.242.1',
        '10.1.2.1',
        '10.2.3.1',
      });
      expect(boards.first.host, '10.198.137.1');
      expect(boards.first.localAddress, '10.198.137.22');
    },
  );

  test(
    'only 10.* auto-discovery; other private subnets require manual mode',
    () {
      expect(
        BoardDiscovery.candidates(const [
          LocalBoardNetwork('eth0', '10.2.3.4'),
          LocalBoardNetwork('eth1', '172.16.8.100'),
          LocalBoardNetwork('eth2', '172.31.9.2'),
          LocalBoardNetwork('eth3', '172.32.9.2'),
          LocalBoardNetwork('eth4', '172.15.9.2'),
        ]).map((b) => b.host),
        ['10.2.3.1'],
      );
    },
  );

  test('only probe .1 candidates and tolerate one failed interface', () async {
    final probed = <String>[];
    final discovery = BoardDiscovery(
      networks: () async => const [
        LocalBoardNetwork('wlan0', '10.5.6.88'),
        LocalBoardNetwork('eth0', '10.9.7.44'),
      ],
      probe: (host) async {
        probed.add(host);
        if (host == '10.5.6.1') throw const SocketException('offline');
        return true;
      },
    );
    expect((await discovery.findBoard())?.host, '10.9.7.1');
    expect(probed, ['10.5.6.1', '10.9.7.1']);
  });

  test(
    'all 10.* candidates are tried, including beyond the old eight-address limit',
    () async {
      final probed = <String>[];
      final discovery = BoardDiscovery(
        networks: () async => [
          for (var i = 0; i < 12; ++i)
            LocalBoardNetwork('adapter$i', '10.42.$i.23'),
        ],
        probe: (host) async {
          probed.add(host);
          return false;
        },
      );
      expect(await discovery.findBoard(), isNull);
      expect(probed.toSet(), {for (var i = 0; i < 12; ++i) '10.42.$i.1'});
    },
  );

  test('no eligible interfaces produces no target', () async {
    final discovery = BoardDiscovery(networks: () async => []);
    expect(await discovery.findBoard(), isNull);
  });

  test(
    'discovery validates actual two-line daemon protocol, not merely open TCP',
    () async {
      final fixture = File(
        'test/fixtures/exchanges/get_state_ok.ndjson',
      ).readAsStringSync();
      final daemon = await FixtureDaemon.start((_) async => fixture);
      try {
        expect(
          await BoardDiscovery.probeBoard('127.0.0.1', port: daemon.port),
          isTrue,
        );
        expect(daemon.ops, ['get_state']);
      } finally {
        await daemon.stop();
      }
      final router = await FixtureDaemon.start(
        (_) async =>
            '{"v":1,"type":"accepted","id":42}\n'
            '{"v":1,"type":"result","id":42,"ok":true,"payload":{"router":true}}\n',
      );
      try {
        expect(
          await BoardDiscovery.probeBoard('127.0.0.1', port: router.port),
          isFalse,
        );
      } finally {
        await router.stop();
      }
    },
  );
}
