import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

typedef JsonConfigLoader = Future<Map<String, dynamic>> Function();
typedef JsonConfigUploader =
    Future<Map<String, dynamic>> Function(Map<String, dynamic> config);

class JsonConfigParseResult {
  const JsonConfigParseResult({this.config, this.error = ''});

  final Map<String, dynamic>? config;
  final String error;

  bool get valid => config != null;
}

/// Strict client-side validation for the complete board configuration.
/// Structural validation remains authoritative in the daemon's `set_config`.
JsonConfigParseResult parseBoardConfigJson(String source) {
  if (source.trim().isEmpty) {
    return const JsonConfigParseResult(error: 'JSON is empty');
  }
  try {
    final decoded = jsonDecode(source);
    if (decoded is! Map) {
      return const JsonConfigParseResult(
        error: 'Top-level JSON value must be an object',
      );
    }
    final config = Map<String, dynamic>.from(decoded);
    final layoutError = _validateUartRxLayout(config);
    if (layoutError.isNotEmpty) {
      return JsonConfigParseResult(error: layoutError);
    }
    return JsonConfigParseResult(config: config);
  } on FormatException catch (error) {
    var location = '';
    final offset = error.offset;
    if (offset != null) {
      final safeOffset = offset.clamp(0, source.length);
      final prefix = source.substring(0, safeOffset);
      final line = '\n'.allMatches(prefix).length + 1;
      final lastBreak = prefix.lastIndexOf('\n');
      final column = safeOffset - lastBreak;
      location = ' at $line:$column';
    }
    return JsonConfigParseResult(error: '${error.message}$location');
  } catch (error) {
    return JsonConfigParseResult(error: '$error');
  }
}

String _validateUartRxLayout(Map<String, dynamic> config) {
  final uart = config['uart'];
  if (uart is! Map || !uart.containsKey('rx_layout')) return '';
  final layoutValue = uart['rx_layout'];
  if (layoutValue is! Map) return 'uart.rx_layout must be an object';
  final layout = Map<String, dynamic>.from(layoutValue);
  const requiredKeys = {
    'packet_size',
    'header',
    'checksum',
    'checksum_offset',
    'byte_order',
    'fields',
  };
  if (layout.keys.toSet().difference(requiredKeys).isNotEmpty ||
      requiredKeys.difference(layout.keys.toSet()).isNotEmpty) {
    return 'uart.rx_layout has missing or unknown fields';
  }
  final packetSize = layout['packet_size'];
  final header = layout['header'];
  final checksum = layout['checksum'];
  final checksumOffset = layout['checksum_offset'];
  final byteOrder = layout['byte_order'];
  final fields = layout['fields'];
  if (packetSize is! int || packetSize < 2 || packetSize > 2048) {
    return 'uart.rx_layout.packet_size must be 2..2048';
  }
  if (header is! int || header < 0 || header > 255) {
    return 'uart.rx_layout.header must be 0..255';
  }
  if (checksum != 'sum8' && checksum != 'none') {
    return 'uart.rx_layout.checksum must be sum8 or none';
  }
  if (checksumOffset is! int ||
      checksumOffset < 0 ||
      checksumOffset >= packetSize) {
    return 'uart.rx_layout.checksum_offset is outside the packet';
  }
  if (byteOrder != 'little' && byteOrder != 'big') {
    return 'uart.rx_layout.byte_order must be little or big';
  }
  if (fields is! List || fields.isEmpty || fields.length > 64) {
    return 'uart.rx_layout.fields must contain 1..64 fields';
  }
  const widths = {
    'uint8': 1,
    'int8': 1,
    'uint16': 2,
    'int16': 2,
    'uint32': 4,
    'int32': 4,
    'float32': 4,
    'float64': 8,
  };
  final occupied = <int>{0, if (checksum == 'sum8') checksumOffset};
  final names = <String>{};
  final namePattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,31}$');
  for (var index = 0; index < fields.length; index++) {
    final value = fields[index];
    if (value is! Map) return 'uart.rx_layout.fields[$index] must be an object';
    final field = Map<String, dynamic>.from(value);
    const fieldKeys = {'name', 'type', 'offset'};
    if (field.keys.toSet().difference(fieldKeys).isNotEmpty ||
        fieldKeys.difference(field.keys.toSet()).isNotEmpty) {
      return 'uart.rx_layout.fields[$index] has missing or unknown fields';
    }
    final name = field['name'];
    final type = field['type'];
    final offset = field['offset'];
    if (name is! String || !namePattern.hasMatch(name)) {
      return 'uart.rx_layout.fields[$index].name is invalid';
    }
    if (!names.add(name)) {
      return 'uart.rx_layout field "$name" is duplicated';
    }
    final width = widths[type];
    if (width == null) {
      return 'uart.rx_layout.fields[$index].type is unsupported';
    }
    if (offset is! int || offset < 0 || offset + width > packetSize) {
      return 'uart.rx_layout field "$name" is outside the packet';
    }
    for (var byte = offset; byte < offset + width; byte++) {
      if (!occupied.add(byte)) {
        return 'uart.rx_layout field "$name" overlaps another field or reserved byte';
      }
    }
  }
  return '';
}

/// Dark, code-oriented editor for the daemon's single persistent JSON config.
/// It imports local JSON, validates and formats locally, and only uploads after
/// an explicit replacement confirmation.
class JsonConfigEditor extends StatefulWidget {
  const JsonConfigEditor({
    super.key,
    required this.initialConfig,
    required this.onReload,
    required this.onUpload,
    this.connected = true,
    this.uploadLocked = false,
  });

  final Map<String, dynamic>? initialConfig;
  final JsonConfigLoader onReload;
  final JsonConfigUploader onUpload;
  final bool connected;
  final bool uploadLocked;

  @override
  State<JsonConfigEditor> createState() => JsonConfigEditorState();
}

class JsonConfigEditorState extends State<JsonConfigEditor> {
  static const _jsonTypes = [
    XTypeGroup(label: 'JSON configuration', extensions: ['json']),
  ];
  static const _pretty = JsonEncoder.withIndent('  ');

  late final TextEditingController _controller = TextEditingController();
  bool _busy = false;
  bool _dirty = false;
  String _operationMessage = '';
  bool _operationError = false;

  @override
  void initState() {
    super.initState();
    final config = widget.initialConfig;
    if (config != null) _replaceWith(config);
  }

  @override
  void didUpdateWidget(covariant JsonConfigEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.initialConfig, oldWidget.initialConfig) &&
        widget.initialConfig != null) {
      _replaceWith(widget.initialConfig!);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _replaceWith(Map<String, dynamic> config, {String message = ''}) {
    _controller.text = _pretty.convert(config);
    _dirty = false;
    _operationMessage = message;
    _operationError = false;
  }

  void _onChanged(String _) {
    setState(() {
      _dirty = true;
      _operationMessage = '';
      _operationError = false;
    });
  }

  Future<void> _reload() async {
    if (_busy || !widget.connected) return;
    setState(() => _busy = true);
    try {
      final config = await widget.onReload();
      if (!mounted) return;
      setState(() => _replaceWith(config, message: 'Reloaded from board'));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _operationMessage = 'Reload failed: $error';
        _operationError = true;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openFile() async {
    if (_busy) return;
    final file = await openFile(acceptedTypeGroups: _jsonTypes);
    if (file == null) return;
    try {
      final bytes = await file.length();
      if (bytes > 1024 * 1024) {
        throw const FormatException('JSON file exceeds the 1 MiB limit');
      }
      final source = await file.readAsString();
      if (!mounted) return;
      setState(() {
        _controller.text = source;
        _dirty = true;
        _operationMessage = 'Opened ${file.name}';
        _operationError = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _operationMessage = 'Open failed: $error';
        _operationError = true;
      });
    }
  }

  void _format() {
    final parsed = parseBoardConfigJson(_controller.text);
    if (!parsed.valid) return;
    setState(() {
      _controller.text = _pretty.convert(parsed.config);
      _dirty = true;
      _operationMessage = 'Formatted locally';
      _operationError = false;
    });
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _controller.text));
    if (!mounted) return;
    setState(() {
      _operationMessage = 'Copied JSON';
      _operationError = false;
    });
  }

  Future<void> _upload(Map<String, dynamic> config) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.cloud_upload_outlined),
        title: const Text('Upload complete configuration?'),
        content: const Text(
          'This replaces the board’s complete persistent JSON configuration. '
          'The daemon will validate it before applying and may restart the camera worker.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            key: const ValueKey('confirm-json-upload'),
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.cloud_upload_outlined),
            label: const Text('Upload'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    try {
      final stored = await widget.onUpload(config);
      if (!mounted) return;
      setState(
        () => _replaceWith(
          stored,
          message: 'Daemon accepted and reloaded the configuration',
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _operationMessage = 'Upload rejected: $error';
        _operationError = true;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final parsed = parseBoardConfigJson(_controller.text);
    final source = _controller.text;
    final lines = source.isEmpty ? 0 : '\n'.allMatches(source).length + 1;
    final bytes = utf8.encode(source).length;
    final canUpload =
        parsed.valid &&
        widget.connected &&
        !widget.uploadLocked &&
        !_busy &&
        _dirty;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFF0B1220),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: colors.primary.withValues(alpha: 0.28)),
          boxShadow: const [
            BoxShadow(
              color: Color(0x24000000),
              blurRadius: 24,
              offset: Offset(0, 10),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(17),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _toolbar(context, parsed, canUpload),
              const Divider(height: 1, color: Color(0xFF243044)),
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: TextField(
                        key: const ValueKey('json-config-source'),
                        controller: _controller,
                        enabled: !_busy,
                        expands: true,
                        minLines: null,
                        maxLines: null,
                        keyboardType: TextInputType.multiline,
                        autocorrect: false,
                        enableSuggestions: false,
                        smartDashesType: SmartDashesType.disabled,
                        smartQuotesType: SmartQuotesType.disabled,
                        style: const TextStyle(
                          color: Color(0xFFD7E3F4),
                          fontFamily: 'monospace',
                          fontSize: 13,
                          height: 1.55,
                        ),
                        cursorColor: const Color(0xFF5EEAD4),
                        decoration: const InputDecoration(
                          hintText: 'Reload from board or open a .json file…',
                          hintStyle: TextStyle(color: Color(0xFF64748B)),
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.all(18),
                        ),
                        onChanged: _onChanged,
                      ),
                    ),
                    if (_busy)
                      const Positioned(
                        left: 0,
                        right: 0,
                        top: 0,
                        child: LinearProgressIndicator(minHeight: 2),
                      ),
                  ],
                ),
              ),
              Container(
                color: const Color(0xFF111A2B),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 9,
                ),
                child: Row(
                  children: [
                    Icon(
                      parsed.valid
                          ? Icons.check_circle_outline
                          : Icons.error_outline,
                      size: 16,
                      color: parsed.valid
                          ? const Color(0xFF5EEAD4)
                          : const Color(0xFFFCA5A5),
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        _operationMessage.isNotEmpty
                            ? _operationMessage
                            : parsed.valid
                            ? 'Valid JSON object'
                            : parsed.error,
                        key: const ValueKey('json-config-status'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: _operationMessage.isNotEmpty
                              ? (_operationError
                                    ? const Color(0xFFFCA5A5)
                                    : const Color(0xFF93C5FD))
                              : (parsed.valid
                                    ? const Color(0xFF99F6E4)
                                    : const Color(0xFFFCA5A5)),
                        ),
                      ),
                    ),
                    Text(
                      '$lines lines  ·  $bytes bytes',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: const Color(0xFF94A3B8),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _toolbar(
    BuildContext context,
    JsonConfigParseResult parsed,
    bool canUpload,
  ) {
    final theme = Theme.of(context);
    return Container(
      color: const Color(0xFF111A2B),
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 1200;
          Widget tool({
            required String label,
            required IconData icon,
            required VoidCallback? onPressed,
          }) => compact
              ? IconButton(
                  tooltip: label,
                  onPressed: onPressed,
                  icon: Icon(icon, size: 18),
                  color: const Color(0xFFCBD5E1),
                )
              : TextButton.icon(
                  onPressed: onPressed,
                  icon: Icon(icon, size: 17),
                  label: Text(label),
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFFCBD5E1),
                  ),
                );

          return Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: const Color(0xFF14B8A6).withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.data_object,
                  size: 20,
                  color: Color(0xFF5EEAD4),
                ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'default.json',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: const Color(0xFFF1F5F9),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    _dirty ? 'LOCAL CHANGES' : 'BOARD COPY',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: _dirty
                          ? const Color(0xFFFBBF24)
                          : const Color(0xFF5EEAD4),
                      letterSpacing: 0.8,
                    ),
                  ),
                ],
              ),
              const Spacer(),
              tool(
                label: 'Open JSON',
                icon: Icons.folder_open_outlined,
                onPressed: _busy ? null : _openFile,
              ),
              tool(
                label: 'Reload from board',
                icon: Icons.cloud_download_outlined,
                onPressed: !_busy && widget.connected ? _reload : null,
              ),
              tool(
                label: 'Format JSON',
                icon: Icons.auto_fix_high_outlined,
                onPressed: !_busy && parsed.valid ? _format : null,
              ),
              IconButton(
                tooltip: 'Copy JSON',
                onPressed: _controller.text.isEmpty ? null : _copy,
                icon: const Icon(Icons.content_copy, size: 18),
                color: const Color(0xFFCBD5E1),
              ),
              const SizedBox(width: 6),
              FilledButton.icon(
                key: const ValueKey('upload-json-config'),
                onPressed: canUpload ? () => _upload(parsed.config!) : null,
                icon: const Icon(Icons.cloud_upload_outlined, size: 18),
                label: Text(compact ? 'Upload' : 'Upload to board'),
              ),
            ],
          );
        },
      ),
    );
  }
}
