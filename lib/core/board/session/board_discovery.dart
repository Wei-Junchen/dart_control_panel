import 'dart:io';

import 'package:dart_control_panel/core/board/api/daemon_client.dart';
import 'package:dart_control_panel/core/platform/app_paths.dart';

class LocalBoardNetwork {
  const LocalBoardNetwork(this.name, this.ipv4);
  final String name;
  final String ipv4;
}

class BoardCandidate {
  const BoardCandidate(this.host, this.localAddress, this.interfaceName);
  final String host;
  final String localAddress;
  final String interfaceName;
}

/// AP convention: a DHCP client a.b.c.x reaches its board at a.b.c.1.
/// Not a generic gateway resolver or subnet scan. Routed setups use manual mode.
class BoardDiscovery {
  BoardDiscovery({
    Future<List<LocalBoardNetwork>> Function()? networks,
    Future<bool> Function(String)? probe,
  }) : _networks = networks ?? localNetworks,
       _probe = probe ?? probeBoard;

  final Future<List<LocalBoardNetwork>> Function() _networks;
  final Future<bool> Function(String) _probe;

  static List<BoardCandidate> candidates(Iterable<LocalBoardNetwork> networks) {
    final result = <BoardCandidate>[];
    final seen = <String>{};
    final ordered = networks.toList()
      ..sort((a, b) {
        final priority = _priority(a.name).compareTo(_priority(b.name));
        if (priority != 0) return priority;
        final name = a.name.compareTo(b.name);
        return name != 0 ? name : a.ipv4.compareTo(b.ipv4);
      });
    for (final network in ordered) {
      final ip = InternetAddress.tryParse(network.ipv4);
      if (ip == null || ip.type != InternetAddressType.IPv4) {
        continue;
      }
      final bytes = ip.rawAddress;
      if (bytes[0] != 10 || bytes[3] == 1) {
        continue;
      }
      final host = '${bytes[0]}.${bytes[1]}.${bytes[2]}.1';
      if (seen.add(host)) {
        result.add(BoardCandidate(host, ip.address, network.name));
      }
    }
    return result;
  }

  static int _priority(String name) =>
      RegExp(r'^(wl|wlan|wifi|wi-fi)', caseSensitive: false).hasMatch(name)
      ? 0
      : 1;

  static Future<List<LocalBoardNetwork>> localNetworks() async {
    if (Platform.isAndroid) {
      // Only actual Wi-Fi LinkProperties, never a cellular/VPN IPv4.
      final addresses = await AppPaths.channel.invokeListMethod<String>(
        'wifiIpv4',
      );
      return [
        for (final address in addresses ?? <String>[])
          LocalBoardNetwork('wifi', address),
      ];
    }
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );
    return [
      for (final interface in interfaces)
        for (final address in interface.addresses)
          LocalBoardNetwork(interface.name, address.address),
    ];
  }

  static Future<bool> probeBoard(String host, {int port = 9000}) async {
    final client = DaemonClient(
      host: host,
      port: port,
      timeout: const Duration(milliseconds: 700),
    );
    try {
      final response = await client.call(id: 1, op: 'get_state');
      final envelope = response.payload;
      final state = envelope?['payload'];
      return envelope?['v'] == 1 &&
          envelope?['type'] == 'state' &&
          state is Map &&
          state['state'] is String &&
          state['features'] is Map;
    } catch (_) {
      return false;
    } finally {
      await client.close();
    }
  }

  Future<BoardCandidate?> findBoard() async {
    await AppPaths.prepareWifi();
    final options = candidates(await _networks());
    // No candidate-count cutoff. Bound concurrency, not coverage: every local
    // 10.* subnet is eligible, regardless of desktop interface name.
    for (var offset = 0; offset < options.length; offset += 4) {
      final batch = options.skip(offset).take(4).toList();
      final valid = await Future.wait(
        batch.map((option) async {
          try {
            return await _probe(option.host);
          } catch (_) {
            return false;
          }
        }),
      );
      for (var i = 0; i < batch.length; ++i) {
        if (valid[i]) return batch[i];
      }
    }
    return null;
  }
}
