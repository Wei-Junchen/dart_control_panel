import 'dart:convert';
import 'package:flutter/foundation.dart';

Map<String, dynamic> _copy(Map<String, dynamic> value) =>
    Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);

bool _same(dynamic a, dynamic b) {
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every((k) => b.containsKey(k) && _same(a[k], b[k]));
  }
  if (a is List && b is List) {
    return a.length == b.length &&
        List.generate(a.length, (i) => i).every((i) => _same(a[i], b[i]));
  }
  return a == b;
}

/// One document shared by the JSON editor and generated Controls. Only an
/// explicit load/revert/successful apply may replace the baseline, never polls.
class ConfigDocumentDraft extends ChangeNotifier {
  Map<String, dynamic>? _baseline, _document, schema;
  String text = '', syntaxError = '';
  final Map<String, String> fieldErrors = {};
  int revision = 0;
  bool busy = false;
  Map<String, dynamic>? get document => _document;
  bool get loaded => _baseline != null;
  bool get dirty =>
      syntaxError.isNotEmpty ||
      fieldErrors.isNotEmpty ||
      !_same(_document, _baseline);

  void clear() {
    _baseline = _document = null;
    schema = null;
    text = syntaxError = '';
    fieldErrors.clear();
    revision++;
    notifyListeners();
  }

  static bool _schemaTreeValid(Map rule, [int depth = 0]) {
    if (depth > 16) return false;
    final props = rule['properties'];
    if (rule['type'] == 'object' && props is! Map) return false;
    if (props != null &&
        (props is! Map ||
            props.values.any(
              (v) => v is! Map || !_schemaTreeValid(v, depth + 1),
            ))) {
      return false;
    }
    for (final key in ['enum', 'required', 'oneOf', 'x-order']) {
      if (rule.containsKey(key) && rule[key] is! List) return false;
    }
    if (rule['oneOf'] is List &&
        (rule['oneOf'] as List).any(
          (v) => v is! Map || !_schemaTreeValid(v, depth + 1),
        )) {
      return false;
    }
    if (rule.containsKey('items') &&
        (rule['items'] is! Map ||
            !_schemaTreeValid(rule['items'] as Map, depth + 1))) {
      return false;
    }
    return true;
  }

  void setSchema(Map<String, dynamic>? value) {
    schema =
        value?['x-contract-version'] == 1 &&
            value?['type'] == 'object' &&
            value?['properties'] is Map &&
            _schemaTreeValid(value!)
        ? value
        : null;
    notifyListeners();
  }

  void load(Map<String, dynamic> value, {bool preserveEdits = false}) {
    final keep = preserveEdits && dirty;
    _baseline = _copy(value);
    if (keep) {
      notifyListeners();
    } else {
      _setDocument(value);
    }
  }

  void _setDocument(Map<String, dynamic> value) {
    _document = _copy(value);
    text = const JsonEncoder.withIndent('  ').convert(_document);
    syntaxError = '';
    fieldErrors.clear();
    revision++;
    notifyListeners();
  }

  void revert() {
    if (_baseline != null) _setDocument(_baseline!);
  }

  void editJson(String source) {
    text = source;
    fieldErrors.clear();
    syntaxError = '';
    try {
      final parsed = jsonDecode(source);
      if (parsed is! Map<String, dynamic>) {
        throw const FormatException('配置根节点必须是 JSON 对象');
      }
      _document = parsed;
    } on FormatException catch (e) {
      _document = null;
      syntaxError = e.message;
    }
    revision++;
    notifyListeners();
  }

  dynamic at(String path) {
    dynamic value = _document;
    for (final key in path.split('.')) {
      if (value is! Map || !value.containsKey(key)) return null;
      value = value[key];
    }
    return value;
  }

  void edit(String path, dynamic value) {
    if (_document == null) return;
    final next = _copy(_document!);
    dynamic target = next;
    final keys = path.split('.');
    for (final key in keys.take(keys.length - 1)) {
      target[key] ??= <String, dynamic>{};
      if (target[key] is! Map) return;
      target = target[key];
    }
    target[keys.last] = value;
    fieldErrors.remove(path);
    _document = next;
    text = const JsonEncoder.withIndent('  ').convert(next);
    revision++;
    notifyListeners();
  }

  void invalid(String path, String message) {
    fieldErrors[path] = message;
    notifyListeners();
  }

  bool visible(Map<String, dynamic> field) {
    final condition = field['x-visible-if'];
    if (condition is! Map) return true;
    final path = condition['path'];
    if (path is! String) return false;
    var value = at(path);
    if (value == null) {
      dynamic rule = schema;
      for (final key in path.split('.')) {
        rule = rule is Map && rule['properties'] is Map
            ? (rule['properties'] as Map)[key]
            : null;
      }
      if (rule is Map) value = rule['default'];
    }
    return _same(value, condition['equals']);
  }

  Map<String, dynamic>? get runtimeArgs {
    if (schema?['x-apply'] is! Map ||
        schema!['x-apply']['runtime_op'] != 'apply_runtime' ||
        _document == null ||
        _baseline == null) {
      return null;
    }
    final result = <String, dynamic>{};
    bool diff(dynamic old, dynamic value, dynamic rule) {
      if (_same(old, value)) return true;
      if (old is Map &&
          value is Map &&
          rule is Map &&
          rule['properties'] is Map) {
        for (final key in {...old.keys, ...value.keys}) {
          if (!old.containsKey(key) || !value.containsKey(key)) {
            if (!value.containsKey(key)) return false;
          }
          if (!diff(old[key], value[key], rule['properties'][key])) {
            return false;
          }
        }
        return true;
      }
      if (rule is! Map ||
          rule['x-runtime-key'] is! String ||
          value == null ||
          value is List ||
          value is Map ||
          (value is String && RegExp(r'\s').hasMatch(value))) {
        return false;
      }
      result[rule['x-runtime-key'] as String] = value;
      return true;
    }

    return diff(_baseline, _document, schema) ? result : null;
  }

  Map<String, String> validate() {
    final errors = <String, String>{...fieldErrors};
    if (syntaxError.isNotEmpty) errors['JSON'] = syntaxError;
    if (_document != null && schema != null) {
      _validate(_document, schema!, '', errors);
    }
    return errors;
  }

  static void _validate(
    dynamic value,
    Map rule,
    String path,
    Map<String, String> errors,
  ) {
    void bad(String text) {
      errors[path] = text;
    }

    final type = rule['type'];
    final validType = switch (type) {
      'integer' => value is int,
      'number' => value is num && value.isFinite,
      'boolean' => value is bool,
      'string' => value is String,
      'array' => value is List,
      'object' => value is Map,
      _ => true,
    };
    if (!validType) {
      bad('类型应为 $type');
      return;
    }
    if (rule.containsKey('const') && !_same(value, rule['const'])) {
      bad('值必须为 ${rule['const']}');
    }
    if (rule['enum'] is List &&
        !(rule['enum'] as List).any((v) => _same(v, value))) {
      bad('值不在允许的枚举内');
    }
    if (rule['oneOf'] is List) {
      final matches = (rule['oneOf'] as List).where((r) {
        final branch = <String, String>{};
        _validate(value, r as Map, path, branch);
        return branch.isEmpty;
      }).length;
      if (matches != 1) bad('值不符合板端允许的格式或范围');
    }
    if (value is num) {
      if (!value.isFinite) bad('必须是有限数值');
      if (rule['minimum'] is num && value < rule['minimum']) {
        bad('不能小于 ${rule['minimum']}');
      }
      if (rule['maximum'] is num && value > rule['maximum']) {
        bad('不能大于 ${rule['maximum']}');
      }
      if (rule['exclusiveMinimum'] is num &&
          value <= rule['exclusiveMinimum']) {
        bad('必须大于 ${rule['exclusiveMinimum']}');
      }
    }
    if (value is List) {
      if (rule['minItems'] is num && value.length < rule['minItems']) {
        bad('元素数量不能少于 ${rule['minItems']}');
      }
      if (rule['maxItems'] is num && value.length > rule['maxItems']) {
        bad('元素数量不能多于 ${rule['maxItems']}');
      }
      if (rule['items'] is Map) {
        for (var i = 0; i < value.length; i++) {
          _validate(value[i], rule['items'] as Map, '$path[$i]', errors);
        }
      }
    }
    if (value is Map && rule['properties'] is Map) {
      final properties = rule['properties'] as Map;
      for (final key in (rule['required'] as List? ?? [])) {
        if (!value.containsKey(key)) errors['$path.$key'] = '缺少必需字段';
      }
      for (final key in value.keys) {
        if (!properties.containsKey(key)) {
          if (rule['additionalProperties'] == false) {
            errors['$path.$key'] = '板端未支持的字段';
          }
        } else {
          _validate(
            value[key],
            properties[key] as Map,
            path.isEmpty ? '$key' : '$path.$key',
            errors,
          );
        }
      }
    }
  }
}
