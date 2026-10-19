import 'package:flutter/material.dart';

import 'package:dart_control_panel/features/ground_test/runtime_draft.dart';

/// P3 typed tuning form bound to a [RuntimeDraft].
///
/// - integer / float / boolean / enum controls are separate widgets;
/// - dirty fields get a dot marker and validation errors are shown inline;
/// - the form owns its text controllers, so typing never fights a poll —
///   [TuningFormState.syncFromDraft] repopulates them only on load / revert /
///   apply-success, exactly when the caller asks.
class TuningForm extends StatefulWidget {
  const TuningForm({
    super.key,
    required this.draft,
    required this.onApply,
    required this.onRevert,
    required this.onReload,
    this.busy = false,
    this.locked = false,
  });

  final RuntimeDraft draft;
  final VoidCallback onApply;
  final VoidCallback onRevert;
  final VoidCallback onReload;
  final bool busy;
  final bool locked;

  @override
  State<TuningForm> createState() => TuningFormState();
}

class TuningFormState extends State<TuningForm> {
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, String> _parseErrors = <String, String>{};
  bool get _disabled => widget.busy || widget.locked;

  String _fmt(dynamic v) {
    if (v == null) return '';
    if (v is double) {
      return v == v.roundToDouble() ? v.toInt().toString() : v.toString();
    }
    return v.toString();
  }

  TextEditingController _controller(String field) => _controllers.putIfAbsent(
    field,
    () => TextEditingController(text: _fmt(widget.draft.valueOf(field))),
  );

  /// Repopulate every field from the draft (initial load / reload / revert /
  /// apply-success). Never called by the poll.
  void syncFromDraft() {
    for (final entry in _controllers.entries) {
      entry.value.text = _fmt(widget.draft.valueOf(entry.key));
    }
    _parseErrors.clear();
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    widget.draft.addListener(_onDraftChanged);
  }

  @override
  void dispose() {
    widget.draft.removeListener(_onDraftChanged);
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _onDraftChanged() {
    if (mounted) setState(() {});
  }

  void _onInt(String field, String text) {
    final v = int.tryParse(text.trim());
    if (v == null) {
      setState(() => _parseErrors[field] = 'must be an integer');
      return;
    }
    setState(() => _parseErrors.remove(field));
    widget.draft.edit(field, v);
  }

  void _onDouble(String field, String text) {
    final v = double.tryParse(text.trim());
    if (v == null) {
      setState(() => _parseErrors[field] = 'must be a number');
      return;
    }
    setState(() => _parseErrors.remove(field));
    widget.draft.edit(field, v);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final errors = widget.draft.validate();
    final errorText = errors.entries.map((e) => e.value).join('\n');

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _actionBar(theme, errorText),
          const SizedBox(height: 12),
          if (errorText.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'Cannot apply: $errorText',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          _section(theme, 'Detector', [
            const Padding(
              padding: EdgeInsets.only(bottom: 10),
              child: Text('NV21 green score（唯一识别器）'),
            ),
            _greenScoreEditor(),
            _roiEditor(),
            _grid([
              _intField(RuntimeDraft.searchRadius, 'search radius'),
              _intField(RuntimeDraft.areaThreshold, 'area thr'),
              _intField(RuntimeDraft.pixelsThreshold, 'pixels thr'),
            ]),
            _grid([
              _intField(RuntimeDraft.xStride, 'x stride'),
              _intField(RuntimeDraft.yStride, 'y stride'),
              _intField(RuntimeDraft.detectEveryN, 'every n'),
            ]),
          ]),
          _section(theme, 'ISP', [
            _grid([
              _intField(RuntimeDraft.exposureUs, 'exposure us (0=auto)'),
              _intField(RuntimeDraft.again, 'again (1024=1x)'),
            ]),
            _grid([
              _intField(RuntimeDraft.dgain, 'dgain (1024=1x)'),
              _intField(RuntimeDraft.ispDgain, 'isp dgain (1024=1x)'),
            ]),
            _boolSwitch(RuntimeDraft.awbAuto, 'awb auto'),
            _boolSwitch(RuntimeDraft.ispAdaptiveTone, 'adaptive tone'),
          ]),
          _section(theme, 'Control', [
            _enumChips('mode', RuntimeDraft.controlMode, const [
              'pixel',
              'angle_rad',
            ]),
            _grid([
              _floatField(RuntimeDraft.fx, 'fx'),
              _floatField(RuntimeDraft.fy, 'fy'),
            ]),
            _grid([
              _enumChips('roll unit', RuntimeDraft.rollUnit, const [
                'deg',
                'rad',
              ]),
              _floatField(RuntimeDraft.rollSign, 'roll sign'),
            ]),
            _grid([_floatField(RuntimeDraft.distance, 'distance')]),
          ]),
          _section(theme, 'Display', [
            _boolSwitch(RuntimeDraft.overlay, 'overlay'),
            _boolSwitch(RuntimeDraft.overlayRoi, 'overlay roi'),
            _grid([
              _intField(
                RuntimeDraft.overlaySyncTimeoutMs,
                'frame sync timeout ms',
              ),
            ]),
            _boolSwitch(RuntimeDraft.resetTracker, 'reset tracker (one-shot)'),
          ]),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _actionBar(ThemeData theme, String errorText) {
    final canApply =
        widget.draft.hasChanges &&
        !_disabled &&
        widget.draft.validate().isEmpty;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              onPressed: canApply ? widget.onApply : null,
              icon: const Icon(Icons.send),
              label: const Text('Apply'),
            ),
            OutlinedButton(
              onPressed: widget.draft.hasChanges && !widget.busy
                  ? widget.onRevert
                  : null,
              child: const Text('Revert local edits'),
            ),
            TextButton(
              onPressed: widget.busy ? null : widget.onReload,
              child: const Text('Reload from board'),
            ),
            if (widget.busy)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            if (widget.locked)
              const Chip(
                avatar: Icon(Icons.lock, size: 16),
                label: Text('Flight mode locked'),
              ),
            if (widget.draft.hasChanges)
              Text(
                '${widget.draft.changedFields.length} changed',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _section(ThemeData theme, String title, List<Widget> children) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _dirtyDot(String field) {
    final dirty = widget.draft.isDirty(field);
    return Container(
      width: 8,
      height: 8,
      margin: const EdgeInsets.only(right: 6),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: dirty ? Colors.teal : Colors.transparent,
      ),
    );
  }

  Widget _field(
    String field,
    String label,
    TextEditingController controller,
    String error,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          _dirtyDot(field),
          SizedBox(
            width: 130,
            child: Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
          Expanded(
            child: TextField(
              key: ValueKey('field.$field'),
              controller: controller,
              enabled: !_disabled,
              decoration: InputDecoration(
                isDense: true,
                errorText: error.isEmpty ? null : error,
                errorMaxLines: 2,
                border: const OutlineInputBorder(),
              ),
              onChanged: (text) => _onInt(field, text),
            ),
          ),
        ],
      ),
    );
  }

  Widget _intField(String field, String label) {
    final error = _parseErrors[field] ?? widget.draft.validate()[field] ?? '';
    return _field(field, label, _controller(field), error);
  }

  Widget _floatField(String field, String label) {
    final error = _parseErrors[field] ?? widget.draft.validate()[field] ?? '';
    final controller = _controller(field);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          _dirtyDot(field),
          SizedBox(
            width: 130,
            child: Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
          Expanded(
            child: TextField(
              key: ValueKey('field.$field'),
              controller: controller,
              enabled: !_disabled,
              decoration: InputDecoration(
                isDense: true,
                errorText: error.isEmpty ? null : error,
                errorMaxLines: 2,
                border: const OutlineInputBorder(),
              ),
              onChanged: (text) => _onDouble(field, text),
            ),
          ),
        ],
      ),
    );
  }

  Widget _grid(List<Widget> children) => Wrap(
    spacing: 12,
    runSpacing: 4,
    children: [for (final c in children) SizedBox(width: 260, child: c)],
  );

  Widget _enumChips(String label, String field, List<String> options) {
    final current = widget.draft.valueOf(field)?.toString();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          _dirtyDot(field),
          SizedBox(
            width: 130,
            child: Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
          Expanded(
            child: Wrap(
              spacing: 6,
              runSpacing: 2,
              children: [
                for (final option in options)
                  ChoiceChip(
                    label: Text(option),
                    selected: current == option,
                    onSelected: _disabled
                        ? null
                        : (_) => widget.draft.edit(field, option),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _boolSwitch(String field, String label) {
    final value = widget.draft.valueOf(field) is bool
        ? widget.draft.valueOf(field) as bool
        : false;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          _dirtyDot(field),
          SizedBox(
            width: 130,
            child: Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
          Switch(
            value: value,
            onChanged: _disabled ? null : (v) => widget.draft.edit(field, v),
          ),
        ],
      ),
    );
  }

  // --- composite editors ----------------------------------------------------

  Widget _greenScoreEditor() {
    const labels = [
      ('y_min', RuntimeDraft.greenYMin),
      ('g_min', RuntimeDraft.greenGMin),
      ('score_min', RuntimeDraft.greenScoreMin),
      ('rg_min', RuntimeDraft.greenRgMin),
      ('gb_min', RuntimeDraft.greenGbMin),
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('green score', style: TextStyle(fontSize: 12)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final (label, field) in labels)
                SizedBox(width: 96, child: _compactInt(field, label)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _compactInt(String field, String label) {
    final error = _parseErrors[field] ?? widget.draft.validate()[field] ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            _dirtyDot(field),
            Flexible(
              child: Text(
                label,
                style: Theme.of(context).textTheme.bodySmall,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        TextField(
          key: ValueKey('field.$field'),
          controller: _controller(field),
          enabled: !_disabled,
          decoration: InputDecoration(
            isDense: true,
            errorText: error.isEmpty ? null : error,
            errorMaxLines: 2,
            border: const OutlineInputBorder(),
          ),
          onChanged: (text) => _onInt(field, text),
        ),
      ],
    );
  }

  Widget _roiEditor() {
    final roi = widget.draft.roiList;
    final mode = widget.draft.roiMode;
    final region = mode == 'region';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _dirtyDot(RuntimeDraft.detectRoi),
              const Text('detect roi', style: TextStyle(fontSize: 12)),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            children: [
              for (final m in ['region', 'full'])
                ChoiceChip(
                  label: Text(m),
                  selected: mode == m,
                  onSelected: _disabled
                      ? null
                      : (_) {
                          if (m == 'region') {
                            final c = List<int>.of(widget.draft.roiList);
                            if (c.every((e) => e != 0)) {
                              widget.draft.setRoiRect(c[0], c[1], c[2], c[3]);
                            } else {
                              // fall back to the board baseline rect
                              final parts =
                                  (widget.draft.baseline[RuntimeDraft.detectRoi]
                                          as String?)
                                      ?.split(',');
                              if (parts != null && parts.length == 4) {
                                widget.draft.setRoiRect(
                                  int.tryParse(parts[0]) ?? 0,
                                  int.tryParse(parts[1]) ?? 0,
                                  int.tryParse(parts[2]) ?? 0,
                                  int.tryParse(parts[3]) ?? 0,
                                );
                              }
                            }
                          } else {
                            widget.draft.setRoiMode(m);
                          }
                        },
                ),
            ],
          ),
          if (region) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                _roiField('roi[0]', 'x', roi[0], 0),
                _roiField('roi[1]', 'y', roi[1], 1),
                _roiField('roi[2]', 'w', roi[2], 2),
                _roiField('roi[3]', 'h', roi[3], 3),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _roiField(String key, String label, int value, int index) {
    final error = widget.draft.validate()[RuntimeDraft.detectRoi] ?? '';
    return SizedBox(
      width: 72,
      child: TextField(
        key: ValueKey('field.$key'),
        controller: _controllers.putIfAbsent(
          key,
          () => TextEditingController(text: '$value'),
        ),
        enabled: !_disabled && widget.draft.roiMode == 'region',
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          errorText: index == 0 && error.isNotEmpty ? error : null,
          errorMaxLines: 3,
          border: const OutlineInputBorder(),
        ),
        onChanged: (text) {
          final v = int.tryParse(text.trim());
          if (v == null) {
            setState(
              () => _parseErrors[RuntimeDraft.detectRoi] = 'invalid roi int',
            );
            return;
          }
          setState(() => _parseErrors.remove(RuntimeDraft.detectRoi));
          final current = List<int>.of(widget.draft.roiList);
          current[index] = v;
          widget.draft.setRoiRect(
            current[0],
            current[1],
            current[2],
            current[3],
          );
        },
      ),
    );
  }
}
