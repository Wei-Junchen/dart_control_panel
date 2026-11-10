import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:dart_control_panel/features/ground_test/config_document_draft.dart';

/// Field layout/types/limits come exclusively from get_schema.config_schema.
class ConfigControls extends StatefulWidget {
  const ConfigControls({
    super.key,
    required this.draft,
    required this.onApply,
    required this.onReload,
    this.onLiveApply,
    this.locked = false,
  });
  final ConfigDocumentDraft draft;
  final VoidCallback onApply, onReload;
  final bool locked;
  final VoidCallback? onLiveApply;
  @override
  State<ConfigControls> createState() => _ConfigControlsState();
}

class _ConfigControlsState extends State<ConfigControls> {
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, FocusNode> _focus = {};
  int _seenRevision = -1;
  bool get disabled => widget.locked || widget.draft.busy;
  @override
  void initState() {
    super.initState();
    widget.draft.addListener(_changed);
  }

  @override
  void dispose() {
    widget.draft.removeListener(_changed);
    for (final c in _controllers.values) {
      c.dispose();
    }
    for (final f in _focus.values) {
      f.dispose();
    }
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  String _format(dynamic value, Map rule) =>
      rule['type'] == 'string' && rule['x-control'] != 'json'
      ? value?.toString() ?? ''
      : jsonEncode(value);
  TextEditingController _controller(String path, dynamic value, Map rule) {
    final text = _format(value, rule);
    final c = _controllers.putIfAbsent(
      path,
      () => TextEditingController(text: text),
    );
    if (_seenRevision != widget.draft.revision &&
        !(_focus[path]?.hasFocus ?? false)) {
      c.text = text;
    }
    return c;
  }

  Widget _field(
    String path,
    Map<String, dynamic> rule,
    Map<String, String> errors,
  ) {
    final d = widget.draft;
    final keys = path.split('.');
    dynamic target = d.document;
    bool present = true;
    for (final key in keys) {
      if (target is! Map || !target.containsKey(key)) {
        present = false;
        break;
      }
      target = target[key];
    }
    final value = present ? target : rule['default'];
    final label = rule['title']?.toString() ?? keys.last;
    final unit = rule['x-unit'];
    final fieldDisabled = disabled || rule['readOnly'] == true;
    final error = errors[path];
    final description = rule['description']?.toString();
    final enumValues = rule['enum'];
    if (enumValues is List) {
      final index = enumValues.indexWhere(
        (v) => jsonEncode(v) == jsonEncode(value),
      );
      return DropdownButtonFormField<int>(
        key: ValueKey('config-$path-${jsonEncode(value)}'),
        initialValue: index < 0 ? null : index,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: label,
          helperText: description,
          errorText: error,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        items: [
          for (var i = 0; i < enumValues.length; i++)
            DropdownMenuItem(
              value: i,
              child: Text(
                enumValues[i].toString(),
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: fieldDisabled
            ? null
            : (i) {
                if (i != null) d.edit(path, enumValues[i]);
              },
      );
    }
    if (rule['type'] == 'boolean') {
      return SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(label),
        subtitle: description == null ? null : Text(description),
        value: value == true,
        onChanged: fieldDisabled ? null : (v) => d.edit(path, v),
      );
    }
    final type = rule['type'];
    final jsonField = type == 'array' || rule['x-control'] == 'json';
    final supported =
        jsonField || ['integer', 'number', 'string'].contains(type);
    if (!supported) return Text('$label：暂不支持此控件类型，请使用 JSON 编辑');
    final focus = _focus.putIfAbsent(path, FocusNode.new);
    return TextField(
      key: ValueKey('config-$path'),
      controller: _controller(path, value, rule),
      focusNode: focus,
      enabled: !fieldDisabled,
      decoration: InputDecoration(
        labelText: unit == null ? label : '$label ($unit)',
        helperText: description,
        helperMaxLines: 3,
        errorText: error,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      keyboardType: type == 'integer' || type == 'number'
          ? const TextInputType.numberWithOptions(decimal: true, signed: true)
          : TextInputType.text,
      onChanged: (text) {
        try {
          final dynamic parsed;
          if (jsonField) {
            parsed = jsonDecode(text);
          } else if (type == 'integer') {
            parsed = int.parse(text);
          } else if (type == 'number') {
            parsed = double.parse(text);
            if (!(parsed as double).isFinite) {
              throw const FormatException('必须为有限数值');
            }
          } else {
            parsed = text;
          }
          d.edit(path, parsed);
        } on FormatException {
          d.invalid(path, jsonField ? '请输入有效 JSON 值' : '请输入有效的 $type');
        }
      },
    );
  }

  List<String> _order(Map rule) {
    final properties = (rule['properties'] as Map).keys.cast<String>().toList();
    final preferred = (rule['x-order'] as List? ?? [])
        .whereType<String>()
        .where(properties.contains)
        .toList();
    return [...preferred, ...properties.where((k) => !preferred.contains(k))];
  }

  Widget _object(
    String path,
    Map<String, dynamic> rule,
    Map<String, String> errors,
  ) {
    final properties = rule['properties'] as Map;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final key in _order(rule))
          if (properties[key] is Map &&
              properties[key]['x-hidden'] != true &&
              widget.draft.visible(
                Map<String, dynamic>.from(properties[key] as Map),
              ))
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: properties[key]['type'] == 'object'
                  ? Card(
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              properties[key]['title']?.toString() ?? key,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 14),
                            _object(
                              path.isEmpty ? key : '$path.$key',
                              Map<String, dynamic>.from(properties[key] as Map),
                              errors,
                            ),
                          ],
                        ),
                      ),
                    )
                  : _field(
                      path.isEmpty ? key : '$path.$key',
                      Map<String, dynamic>.from(properties[key] as Map),
                      errors,
                    ),
            ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.draft;
    if (d.schema == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('板端未提供受支持的 config_schema，请使用 JSON 编辑器或更新板端。'),
        ),
      );
    }
    final errors = d.validate();
    final result = SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            children: [
              if (widget.onLiveApply != null)
                FilledButton.tonal(
                  key: const ValueKey('apply-config-runtime'),
                  onPressed:
                      disabled ||
                          errors.isNotEmpty ||
                          !(d.runtimeArgs?.isNotEmpty ?? false)
                      ? null
                      : widget.onLiveApply,
                  child: const Text('实时应用'),
                ),
              FilledButton.icon(
                key: const ValueKey('apply-config-controls'),
                onPressed:
                    disabled || !d.loaded || !d.dirty || errors.isNotEmpty
                    ? null
                    : widget.onApply,
                icon: const Icon(Icons.upload),
                label: const Text('上传配置'),
              ),
              TextButton(
                onPressed: disabled || !d.dirty ? null : d.revert,
                child: const Text('撤销修改'),
              ),
              TextButton(
                onPressed: disabled ? null : widget.onReload,
                child: const Text('重新读取'),
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Text(
              '与 JSON 共用草稿；全部修改均支持热更新时可实时应用，上传完整配置可能重启 worker。硬件约束由板端最终校验。',
            ),
          ),
          if (errors.isNotEmpty)
            Text(
              errors.entries.map((e) => '${e.key}: ${e.value}').join('\n'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (d.document != null)
            _object('', d.schema!, errors)
          else
            const Text('JSON 尚未合法，请先在 JSON 页面修正，草稿不会丢失。'),
        ],
      ),
    );
    _seenRevision = d.revision;
    return result;
  }
}
