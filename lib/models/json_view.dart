import 'dart:convert';

/// Tolerant JSON viewer: every accessor returns a default instead of
/// throwing, and unknown keys are simply never read. This is the basis for
/// forward compatibility — the daemon may append fields that this client
/// does not know about yet.
class JsonView {
  const JsonView(this._data);

  final Map<String, dynamic>? _data;

  Map<String, dynamic>? get data => _data;

  /// Direct raw access (e.g. `v['payload']`); returns null when absent.
  dynamic operator [](String key) => _data?[key];

  bool get isEmpty => _data?.isEmpty ?? true;

  num? num_(String key) {    final value = _data?[key];
    return value is num ? value : null;
  }
  int int_(String key, [int def = 0]) => num_(key)?.toInt() ?? def;

  double dbl(String key, [double def = 0]) =>
      num_(key)?.toDouble() ?? def;

  bool flag(String key, [bool def = false]) =>
      _data?[key] is bool ? _data![key] as bool : def;

  String str(String key, [String def = '']) =>
      _data?[key] is String ? _data![key] as String : def;

  String? strOrNull(String key) =>
      _data?[key] is String ? _data![key] as String : null;

  bool contains(String key) => _data?.containsKey(key) ?? false;

  List<int> intList(String key) {
    final value = _data?[key];
    if (value is! List) return const [];
    return value.map((e) => e is num ? e.toInt() : 0).toList();
  }

  List<double> dblList(String key) {
    final value = _data?[key];
    if (value is! List) return const [];
    return value.map((e) => e is num ? e.toDouble() : 0.0).toList();
  }

  JsonView? nested(String key) {
    final value = _data?[key];
    if (value is Map) {
      return JsonView(Map<String, dynamic>.from(value));
    }
    return null;
  }

  Map<String, dynamic> raw(String key) {
    final value = _data?[key];
    if (value is Map) return Map<String, dynamic>.from(value);
    return const {};
  }

  String toDebugString() => jsonEncode(_data ?? const {});
}
