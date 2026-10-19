import 'package:flutter/foundation.dart';

import 'package:dart_control_panel/core/board/models/daemon_state.dart';

/// Editable draft for `apply_runtime`.
///
/// Rules implemented here (AGENTS.md §5 / §8):
/// - the draft is never overwritten by the 500 ms state poll — the form only
///   syncs on first load, "reload from board", or a successful apply;
/// - only changed fields are serialized (`toArgs`), empty/unset values are
///   never sent and no malformed numeric values can be produced;
/// - ROI is stored as a no-space CSV string;
/// - all integers are range-checked before apply.
class RuntimeDraft extends ChangeNotifier {
  /// Builds a clean draft from a freshly fetched [DaemonState].
  factory RuntimeDraft.fromState(DaemonState state) {
    final draft = RuntimeDraft();
    draft.loadFrom(state);
    return draft;
  }

  /// Empty draft; populate with [loadFrom] once a board state is available.
  RuntimeDraft();

  /// Protocol-level field names (AGENTS.md §5.1).
  static const greenYMin = 'green_y_min';
  static const greenGMin = 'green_g_min';
  static const greenScoreMin = 'green_score_min';
  static const greenRgMin = 'green_rg_min';
  static const greenGbMin = 'green_gb_min';
  static const detectRoi = 'detect_roi';
  static const searchRadius = 'search_radius';
  static const areaThreshold = 'area_threshold';
  static const pixelsThreshold = 'pixels_threshold';
  static const xStride = 'x_stride';
  static const yStride = 'y_stride';
  static const detectEveryN = 'detect_every_n';
  static const exposureUs = 'exposure_us';
  static const again = 'again';
  static const dgain = 'dgain';
  static const ispDgain = 'isp_dgain';
  static const awbAuto = 'awb_auto';
  static const ispAdaptiveTone = 'isp_adaptive_tone';
  static const overlay = 'overlay';
  static const overlayRoi = 'overlay_roi';
  static const overlaySyncTimeoutMs = 'overlay_sync_timeout_ms';
  static const controlMode = 'control_mode';
  static const fx = 'fx';
  static const fy = 'fy';
  static const rollUnit = 'roll_unit';
  static const rollSign = 'roll_sign';
  static const distance = 'distance';
  static const resetTracker = 'reset_tracker';

  /// Only the user's edits; anything else falls back to [_baseline].
  final Map<String, dynamic> _values = <String, dynamic>{};

  /// Last values loaded from the board.
  Map<String, dynamic> _baseline = <String, dynamic>{};

  /// Context needed by validation (output dims, requested fps).
  List<int> _output = const [];

  /// True after an edit; managed automatically, no public setter needed.
  int _revision = 0;

  int get revision => _revision;

  bool get hasChanges => _values.isNotEmpty;
  Set<String> get changedFields => _values.keys.toSet();
  Map<String, dynamic> get baseline => Map.unmodifiable(_baseline);

  List<int> get output => _output;

  /// Effective value: edit if present, otherwise board baseline.
  dynamic valueOf(String field) => _values[field] ?? _baseline[field];

  bool isDirty(String field) => _values.containsKey(field);

  /// Replaces the whole draft from a board state (initial load, reload,
  /// successful apply). Clears all edits.
  void loadFrom(DaemonState state) {
    _values.clear();
    _baseline = baselineFromState(state);
    final w = state.worker;
    _output = List<int>.from(w?.view.output ?? const []);
    _revision++;
    notifyListeners();
  }

  /// Records a changed protocol-level value. If the new value equals the
  /// board baseline, the field is considered clean again (no-op edit).
  void edit(String field, dynamic value) {
    if (identical(_baseline[field], value) || _baseline[field] == value) {
      _values.remove(field);
    } else {
      _values[field] = value;
    }
    _revision++;
    notifyListeners();
  }

  /// "撤销本地修改": discard every pending edit, back to baseline.
  void revert() {
    if (_values.isEmpty) return;
    _values.clear();
    _revision++;
    notifyListeners();
  }

  /// "应用": only the changed fields, exactly as `apply_runtime` expects.
  Map<String, dynamic> toArgs() => Map<String, dynamic>.of(_values);

  // --- composite helpers ---------------------------------------------------

  static const _roiOffValues = {'full', 'off', 'none'};

  /// 'region' when a rectangle is set, otherwise full-frame mode.
  String get roiMode {
    final raw = valueOf(detectRoi);
    if (raw is String && _roiOffValues.contains(raw.toLowerCase())) {
      return raw.toLowerCase();
    }
    return 'region';
  }

  /// Effective [x, y, w, h] ROI rectangle (zeros when not a rectangle).
  List<int> get roiList {
    final raw = valueOf(detectRoi);
    if (raw is String && roiMode == 'region') {
      final parts = raw.split(',');
      if (parts.length == 4) {
        return [for (final p in parts) int.tryParse(p) ?? 0];
      }
    }
    return List.filled(4, 0);
  }

  /// Selects full-frame acquisition via 'full' (off/none remain aliases).
  void setRoiMode(String mode) {
    if (_roiOffValues.contains(mode.toLowerCase())) {
      edit(detectRoi, mode.toLowerCase());
    }
  }

  void setRoiRect(int x, int y, int w, int h) {
    edit(detectRoi, '$x,$y,$w,$h');
  }

  // --- validation ----------------------------------------------------------

  /// Validates every dirty field plus cross-field rules. Returns
  /// `field -> message` pairs; empty means "ready to apply".
  Map<String, String> validate() {
    final errors = <String, String>{};
    final outW = _output.isNotEmpty ? _output[0] : 0;
    final outH = _output.length > 1 ? _output[1] : 0;
    final maxDim = outW > outH ? outW : outH;

    void checkRange(String field, int min, int max) {
      final value = _values[field];
      if (value is String) {
        // Guard against malformed text reaching an integer field.
        errors[field] = '$field must be an integer, got "$value"';
        return;
      }
      if (value is! num) return;
      final v = value.toInt();
      if (v < min || v > max) {
        errors[field] = '$field must be in [$min, $max], got $v';
      }
    }

    for (final f in [greenYMin, greenGMin]) {
      checkRange(f, 0, 255);
    }
    checkRange(greenScoreMin, -510, 510);
    for (final f in [greenRgMin, greenGbMin]) {
      checkRange(f, -255, 255);
    }
    if (_values.containsKey(detectRoi)) {
      if (roiMode == 'region') {
        final r = roiList;
        final (x, y, w, h) = (r[0], r[1], r[2], r[3]);
        if (w <= 0 || h <= 0) {
          errors[detectRoi] = 'detect_roi width/height must be > 0';
        } else if (outW > 0 && (x + w > outW || y + h > outH)) {
          errors[detectRoi] =
              'detect_roi ($x,$y $w x $h) exceeds output ${outW}x$outH';
        }
      }
    }
    if (_values.containsKey(searchRadius)) {
      final raw = _values[searchRadius];
      if (raw is! num) {
        errors[searchRadius] = 'search_radius must be an integer';
      } else if (raw < 1 || (maxDim > 0 && raw > maxDim)) {
        errors[searchRadius] = 'search_radius must be in [1, $maxDim]';
      }
    }
    final areaMax = outW * outH;
    for (final f in [areaThreshold, pixelsThreshold]) {
      if (_values.containsKey(f)) {
        final raw = _values[f];
        if (raw is! num) {
          errors[f] = '$f must be an integer';
        } else if (raw < 1 || (areaMax > 0 && raw > areaMax)) {
          errors[f] = '$f must be in [1, $areaMax]';
        }
      }
    }
    for (final f in [xStride, yStride]) {
      checkRange(f, 1, 8);
    }
    checkRange(detectEveryN, 1, 120);
    checkRange(overlaySyncTimeoutMs, 1, 50);

    if (_values.containsKey(exposureUs)) {
      final raw = _values[exposureUs];
      if (raw is! num) {
        errors[exposureUs] = 'exposure_us must be an integer';
      } else if (raw < 0) {
        errors[exposureUs] = 'exposure_us must be >= 0 (0 = auto)';
      }
    }

    // manual gains require exposure > 0 (current or in the same packet)
    final gainDirty = [again, dgain, ispDgain].any(_values.containsKey);
    if (gainDirty) {
      final exposure = valueOf(exposureUs);
      final exposurePositive = exposure is num && exposure > 0;
      for (final f in [again, dgain, ispDgain]) {
        if (_values.containsKey(f)) {
          final v = _values[f] as num;
          if (v == 0) continue; // 0 = "no change"
          if (v < 1024 || v > 262144) {
            errors[f] = '$f must be 0 (unchanged) or in [1024, 262144]';
          }
          if (!exposurePositive) {
            errors[f] = '$f requires exposure_us > 0';
          }
        }
      }
    }

    if (_values.containsKey(fx)) {
      final v = _values[fx];
      if (v is String) {
        errors[fx] = 'fx must be a number, got "$v"';
      } else if (v is! num || v <= 0) {
        errors[fx] = 'fx must be > 0';
      }
    }
    if (_values.containsKey(fy)) {
      final v = _values[fy];
      if (v is String) {
        errors[fy] = 'fy must be a number, got "$v"';
      } else if (v is! num || v <= 0) {
        errors[fy] = 'fy must be > 0';
      }
    }
    for (final f in [rollSign, distance]) {
      if (_values.containsKey(f)) {
        final v = _values[f];
        if (v is String) {
          errors[f] = '$f must be a number, got "$v"';
        } else if (v is! num || !v.isFinite) {
          errors[f] = '$f must be a finite number';
        }
      }
    }
    if (_values.containsKey(rollUnit)) {
      final v = _values[rollUnit];
      if (v != 'deg' && v != 'rad') {
        errors[rollUnit] = 'roll_unit must be deg or rad';
      }
    }
    if (_values.containsKey(controlMode)) {
      final v = _values[controlMode];
      if (v != 'pixel' && v != 'angle_rad') {
        errors[controlMode] = 'control_mode must be pixel or angle_rad';
      }
    }
    return errors;
  }

  /// Builds the protocol-level baseline view of a [DaemonState].
  static Map<String, dynamic> baselineFromState(DaemonState s) {
    final w = s.worker;
    if (w == null) return const {};
    final v = w.vision;
    final c = w.camera;
    final ctrl = w.control;
    final ov = w.overlay;
    final gs = v.greenScore;
    return <String, dynamic>{
      greenYMin: gs.yMin,
      greenGMin: gs.gMin,
      greenScoreMin: gs.scoreMin,
      greenRgMin: gs.rgMin,
      greenGbMin: gs.gbMin,
      if (v.detectRoi.length == 4) detectRoi: v.detectRoi.join(','),
      searchRadius: v.searchRadius,
      areaThreshold: v.areaThreshold,
      pixelsThreshold: v.pixelsThreshold,
      xStride: v.xStride,
      yStride: v.yStride,
      detectEveryN: v.detectEveryN,
      exposureUs: c.exposureUs,
      again: c.again,
      dgain: c.dgain,
      ispDgain: c.ispDgain,
      awbAuto: c.awbAuto,
      ispAdaptiveTone: c.ispAdaptiveTone,
      overlay: ov.enabled,
      overlayRoi: ov.roi,
      overlaySyncTimeoutMs: ov.syncTimeoutMs,
      controlMode: ctrl.mode,
      fx: ctrl.fx,
      fy: ctrl.fy,
      rollUnit: ctrl.rollUnit,
      rollSign: ctrl.rollSign,
      distance: ctrl.distance,
    };
  }
}
