import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:dart_control_panel/controllers/board_session.dart';
import 'package:dart_control_panel/models/board_address_store.dart';
import 'package:dart_control_panel/models/diagnostics_summary.dart';
import 'package:dart_control_panel/widgets/connection_bar.dart';
import 'package:dart_control_panel/widgets/metric_card.dart';

/// P6 diagnostics screen: schema viewer, worker log viewer, JSON state
/// export, copy-paste diagnostics summary, and management of remembered
/// board addresses (no credentials are ever stored).
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key, required this.session, this.onConnectTo});

  final BoardSession session;

  /// Connect to a saved board (tells the shell to switch endpoint).
  final void Function(String host, int port)? onConnectTo;

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  BoardSession get _session => widget.session;
  List<BoardAddress> _saved = const [];
  Map<String, dynamic>? _schema;
  List<String> _logs = const [];
  String _logError = '';
  int _logLines = 200;
  bool _schemaBusy = false;
  bool _logsBusy = false;

  @override
  void initState() {
    super.initState();
    _session.addListener(_onSessionChanged);
    _reloadSaved();
  }

  @override
  void dispose() {
    _session.removeListener(_onSessionChanged);
    super.dispose();
  }

  void _reloadSaved() {
    setState(() => _saved = BoardAddressStore.instance.load());
  }

  void _onSessionChanged() => setState(() {});

  Future<void> _connectTo(BoardAddress address) {
    widget.onConnectTo?.call(address.host, address.port);
    return Future.value();
  }

  Future<void> _loadSchema() async {
    final repo = _session.repository;
    if (repo == null) return;
    setState(() => _schemaBusy = true);
    try {
      final schema = await repo.getSchema();
      if (mounted) setState(() => _schema = schema);
    } catch (e) {
      _session.setStatus('get_schema failed: $e', error: true);
    } finally {
      if (mounted) setState(() => _schemaBusy = false);
    }
  }

  Future<void> _fetchLogs() async {
    final repo = _session.repository;
    if (repo == null) return;
    setState(() => _logsBusy = true);
    try {
      final logs = await repo.getLogs(lines: _logLines);
      if (mounted) {
        setState(() {
          _logs = logs;
          _logError = '';
        });
      }
    } catch (e) {
      if (mounted) setState(() => _logError = '$e');
    } finally {
      if (mounted) setState(() => _logsBusy = false);
    }
  }

  Future<void> _exportStateJson() async {
    final state = _session.state;
    if (state == null) {
      _session.setStatus('Connect first to export state', error: true);
      return;
    }
    final now = DateTime.now();
    final name =
        'dart_state_${now.year}${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}_'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}.json';
    final location = await getSaveLocation(
      suggestedName: name,
      acceptedTypeGroups: const [
        XTypeGroup(label: 'JSON', extensions: ['json']),
      ],
    );
    if (location == null) return; // user cancelled
    try {
      await File(location.path)
          .writeAsString(JsonEncoder.withIndent('  ').convert(state.envelope));
      _session.setStatus('State exported to ${location.path}');
    } catch (e) {
      _session.setStatus('export failed: $e', error: true);
    }
  }

  Future<void> _copySummary() async {
    final state = _session.state;
    if (state == null) {
      _session.setStatus('Connect first to copy diagnostics', error: true);
      return;
    }
    final summary = buildDiagnosticsSummary(
      state,
      board: '${_session.host}:${_session.port}',
    );
    await Clipboard.setData(ClipboardData(text: summary));
    if (mounted) {
      _session.setStatus('Diagnostics summary copied to clipboard');
      // show the summary in the UI for confirmation
      setState(() => _logs = summary.split('\n'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Diagnostics'),
        actions: [
          if (session.connection != null)
            ConnectionStatusChip(connection: session.connection!),
          const SizedBox(width: 12),
        ],
      ),
      body: Column(
        children: [
          if (session.busy) const LinearProgressIndicator(minHeight: 2),
          if (session.statusMessage != null) _statusBanner(context, session),
          Expanded(child: _body(context, session)),
        ],
      ),
    );
  }

  Widget _statusBanner(BuildContext context, BoardSession session) {
    return MaterialBanner(
      content: Text(
        session.statusMessage!,
        style: TextStyle(
          color: session.statusError
              ? Theme.of(context).colorScheme.error
              : Theme.of(context).colorScheme.onSurface,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => session.setStatus(''),
          child: const Text('Dismiss'),
        ),
      ],
    );
  }

  Widget _body(BuildContext context, BoardSession session) {
    final connected = session.state != null;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _savedBoardsCard(context, connected),
        const SizedBox(height: 12),
        if (!connected)
          _hintCard(context)
        else ...[
          MetricCard(
            title: 'Export / Diagnostics',
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: _exportStateJson,
                    icon: const Icon(Icons.save_alt),
                    label: const Text('Export state JSON'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _copySummary,
                    icon: const Icon(Icons.content_copy),
                    label: const Text('Copy diagnostics summary'),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          MetricCard(
            title: 'Daemon schema (capability discovery)',
            trailing: FilledButton.tonal(
              onPressed: _schemaBusy ? null : _loadSchema,
              child: const Text('Load schema'),
            ),
            children: [
              if (_schemaBusy)
                const LinearProgressIndicator()
              else if (_schema == null)
                const Text('Not loaded yet.')
              else
                _mono(jsonEncode(_schema!),
                    maxHeight: 220, collapsed: true),
            ],
          ),
          const SizedBox(height: 12),
          MetricCard(
            title: 'Worker log',
            trailing: Wrap(
              spacing: 4,
              children: [
                DropdownButton<int>(
                  value: _logLines,
                  items: const [
                    DropdownMenuItem(value: 50, child: Text('50')),
                    DropdownMenuItem(value: 100, child: Text('100')),
                    DropdownMenuItem(value: 200, child: Text('200')),
                    DropdownMenuItem(value: 500, child: Text('500')),
                  ],
                  onChanged: (v) => setState(() => _logLines = v ?? 200),
                ),
                FilledButton.tonal(
                  onPressed: _logsBusy ? null : _fetchLogs,
                  child: const Text('Fetch'),
                ),
              ],
            ),
            children: [
              if (_logsBusy)
                const LinearProgressIndicator()
              else if (_logError.isNotEmpty)
                Text(_logError,
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.error))
              else
                _mono(
                  _logs.isEmpty ? '(no log content)' : _logs.join('\n'),
                  maxHeight: 320,
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _savedBoardsCard(BuildContext context, bool connected) {
    return MetricCard(
      title: 'Saved boards',
      trailing: IconButton(
        tooltip: 'Refresh',
        icon: const Icon(Icons.refresh, size: 18),
        onPressed: _reloadSaved,
      ),
      children: [
        if (_saved.isEmpty)
          const Text('None yet — successful connects are remembered here.')
        else
          for (final address in _saved)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.router, size: 20),
              title: Text(
                address.label,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              subtitle: Text(
                'last used ${_friendlyDate(address.lastUsed)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              trailing: IconButton(
                tooltip: 'Connect',
                icon: const Icon(Icons.link),
                onPressed: connected ? null : () => _connectTo(address),
              ),
              onLongPress: () => _deleteAddress(address),
            ),
      ],
    );
  }

  Future<void> _deleteAddress(BoardAddress address) async {
    await BoardAddressStore.instance.remove(address.host, address.port);
    _reloadSaved();
  }

  String _friendlyDate(DateTime t) {
    final now = DateTime.now();
    if (t.year == now.year && t.month == now.month && t.day == now.day) {
      return '${t.hour.toString().padLeft(2, '0')}:'
          '${t.minute.toString().padLeft(2, '0')} today';
    }
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-'
        '${t.day.toString().padLeft(2, '0')}';
  }

  Widget _hintCard(BuildContext context) {
    return MetricCard(
      title: 'Diagnostics',
      children: [
        const Text(
          'Connect to export state JSON, load the daemon schema, browse the '
          'worker log, or copy a one-page diagnostics summary to clipboard.',
        ),
      ],
    );
  }

  Widget _mono(String text, {double? maxHeight, bool collapsed = false}) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      constraints: maxHeight == null ? null : BoxConstraints(maxHeight: maxHeight),
      child: SingleChildScrollView(
        scrollDirection: Axis.vertical,
        child: SingleChildScrollView(
          scrollDirection: collapsed ? Axis.horizontal : Axis.vertical,
          child: Text(
            text,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ),
      ),
    );
  }
}