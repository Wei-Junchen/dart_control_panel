import 'package:dart_control_panel/core/platform/app_paths.dart';
import 'dart:convert';
import 'dart:io';

/// A remembered board endpoint. Only address metadata is stored — never
/// credentials (the protocol has none).
class BoardAddress {
  const BoardAddress({
    required this.host,
    required this.port,
    required this.lastUsed,
  });

  final String host;
  final int port;
  final DateTime lastUsed;

  String get label => '$host:$port';

  factory BoardAddress.fromJson(Map<String, dynamic> json) => BoardAddress(
    host: json['host'] is String ? json['host'] as String : '',
    port: json['port'] is num ? (json['port'] as num).toInt() : 9000,
    lastUsed: json['last_used'] is String
        ? DateTime.tryParse(json['last_used'] as String) ?? DateTime.now()
        : DateTime.now(),
  );

  Map<String, dynamic> toJson() => {
    'host': host,
    'port': port,
    'last_used': lastUsed.toIso8601String(),
  };
}

/// Persists the list of board addresses and the last-used endpoint.
///
/// Storage: `$XDG_CONFIG_HOME/dart_control_panel/addresses.json` (or
/// `~/.config/...`). Pure `dart:io`, so it works on all desktop targets and
/// is easy to unit test with a temp file.
class BoardAddressStore {
  BoardAddressStore({File? file}) : _file = file ?? _defaultFile();

  final File _file;

  static final BoardAddressStore instance = BoardAddressStore();

  static File _defaultFile() {
    return File(
      '${AppPaths.configRoot.path}/dart_control_panel/addresses.json',
    );
  }

  static const maxEntries = 8;

  List<BoardAddress> load() {
    if (!_file.existsSync()) return const [];
    try {
      final decoded = jsonDecode(_file.readAsStringSync());
      if (decoded is! List) return const [];
      return [
        for (final entry in decoded)
          if (entry is Map<String, dynamic>) BoardAddress.fromJson(entry),
      ];
    } catch (_) {
      return const [];
    }
  }

  BoardAddress? get lastUsed {
    final addresses = load();
    if (addresses.isEmpty) return null;
    addresses.sort((a, b) => b.lastUsed.compareTo(a.lastUsed));
    return addresses.first;
  }

  /// Upserts host:port, bumps `last_used`, keeps at most [maxEntries].
  Future<void> remember(String host, int port) async {
    final addresses = load()
        .where((a) => !(a.host == host && a.port == port))
        .toList();
    addresses.insert(
      0,
      BoardAddress(host: host, port: port, lastUsed: DateTime.now()),
    );
    if (addresses.length > maxEntries) {
      addresses.removeRange(maxEntries, addresses.length);
    }
    try {
      _file.parent.createSync(recursive: true);
      await _file.writeAsString(
        jsonEncode([for (final a in addresses) a.toJson()]),
      );
    } catch (_) {
      // persistence is best-effort; never crash the UI over a settings file
    }
  }

  Future<void> remove(String host, int port) async {
    final addresses = load()
        .where((a) => !(a.host == host && a.port == port))
        .toList();
    try {
      await _file.writeAsString(
        jsonEncode([for (final a in addresses) a.toJson()]),
      );
    } catch (_) {}
  }
}
