import 'package:dart_control_panel/core/board/models/json_view.dart';
import 'package:dart_control_panel/core/board/models/profile.dart';

/// Parsed daemon state (`result.payload.payload` after unwrapping the state
/// envelope in [DaemonState.fromEnvelope]).
///
/// Forward compatible: unknown keys at any depth are ignored; missing nested
/// sections default to empty/null rather than failing.
class DaemonState {
  DaemonState.fromEnvelope(Map<String, dynamic> envelope)
    : envelope = Map.unmodifiable(envelope) {
    final v = JsonView(envelope);
    this.v = v.int_('v', 0);
    type = v.str('type');
    seq = v.int_('seq');
    monoUs = v.num_('mono_us')?.toInt();

    final p = v['payload'] == null
        ? const JsonView(null)
        : JsonView(Map<String, dynamic>.from(envelope['payload'] as Map));
    state = p.str('state');
    profile = p.str('profile');
    pendingProfile = p.strOrNull('pending_profile');
    final modeValue = p['mode'];
    final modeView = modeValue is Map
        ? JsonView(Map<String, dynamic>.from(modeValue))
        : const JsonView(null);
    mode =
        p.strOrNull('operating_mode') ??
        modeView.strOrNull('name') ??
        (modeValue is String ? modeValue : 'ground');
    imageSettingsLocked = modeView.flag(
      'image_settings_locked',
      mode == 'flight',
    );
    modePending = p.strOrNull('mode_pending');
    modeTransition = p.flag('mode_transition');
    rotation = p.int_('rotation');
    configRev = p.int_('config_rev');
    lastKnownGood = p.str('last_known_good');
    lastError = p.str('last_error');
    configWarning = p.str('config_warning');
    configPath = p.str('config_path');
    expected = p.nested('expected') == null
        ? null
        : Expected.fromJson(Map<String, dynamic>.from(p['expected'] as Map));
    workerPid = p.int_('worker_pid');
    daemonUptimeS = p.num_('daemon_uptime_s')?.toDouble();
    restarts = p.int_('restarts');
    features = Features.fromJson(p.nested('features'));
    flight = FlightState.fromJson(p.nested('flight'));
    udpTelemetry = DaemonUdpTelemetry.fromJson(p.nested('udp_telemetry'));
    fileService = FileServiceState.fromJson(p.nested('file_service'));
    resources = Resources.fromJson(p.nested('resources'));
    final workerView = p.nested('worker');
    worker = workerView == null ? null : WorkerState.fromJson(workerView);
  }

  /// The raw, unmodified state envelope as received from the daemon.
  final Map<String, dynamic> envelope;

  late final int v;
  late final String type;
  late final int seq;
  late final int? monoUs;

  late final String state;
  late final String profile;
  late final String? pendingProfile;

  /// Current operating mode: `ground` or `flight`.
  late final String mode;
  late final bool imageSettingsLocked;
  late final String? modePending;
  late final bool modeTransition;
  late final int rotation;
  late final int configRev;
  late final String lastKnownGood;
  late final String lastError;
  late final String configWarning;
  late final String configPath;
  late final Expected? expected;
  late final int workerPid;
  late final double? daemonUptimeS;
  late final int restarts;

  late final Features features;
  late final FlightState flight;
  late final DaemonUdpTelemetry udpTelemetry;
  late final FileServiceState fileService;
  late final Resources resources;
  late final WorkerState? worker;

  /// Convenience for the UI: worker section presence without unwrapping.
  String get workerStatus => worker?.lifecycle.state ?? '';

  bool get isTransitional => isTransitionalState(state);

  static bool isTransitionalState(String state) => const {
    'STARTING',
    'STANDBY_PENDING',
    'WAKING',
    'STOPPING',
    'FLIGHT_STARTING',
    'FLIGHT_STOPPING',
  }.contains(state);
}

class FlightState {
  const FlightState(this._v);
  factory FlightState.fromJson(JsonView? v) =>
      v == null ? const FlightState(null) : FlightState(v);

  final JsonView? _v;

  bool get active => _v?.flag('active') ?? false;
  String get state => _v?.str('state') ?? 'IDLE';
  String get triggerSource => _v?.str('trigger_source') ?? '';
  String get telemetryHost => _v?.str('telemetry_host') ?? '';
  int get startedMonoUs => _v?.int_('started_mono_us') ?? 0;
  String get recordPath => _v?.str('record_path') ?? '';
  String get telemetryPath => _v?.str('telemetry_path') ?? '';
  String get lastRecordPath => _v?.str('last_record_path') ?? '';
  String get lastTelemetryPath => _v?.str('last_telemetry_path') ?? '';
}

class FileServiceState {
  const FileServiceState(this._v);
  factory FileServiceState.fromJson(JsonView? v) =>
      v == null ? const FileServiceState(null) : FileServiceState(v);

  final JsonView? _v;

  bool get enabled => _v?.flag('enabled') ?? false;
  bool get available => _v?.flag('available') ?? false;
  bool get readOnly => _v?.flag('read_only') ?? true;
  bool get range => _v?.flag('range') ?? false;
  int get port => _v?.int_('port', 9002) ?? 9002;
  String get fingerprint => _v?.str('fingerprint') ?? '';
}

class Features {
  const Features(this._v);
  factory Features.fromJson(JsonView? v) =>
      v == null ? const Features(null) : Features(v);

  final JsonView? _v;

  bool get uartEnabled => _v?.flag('uart_enabled') ?? false;
  bool get rtsp => _v?.flag('rtsp') ?? false;
  bool get overlay => _v?.flag('overlay') ?? false;
  bool get recording => _v?.flag('recording') ?? false;
}

class DaemonUdpTelemetry {
  const DaemonUdpTelemetry(this._v);
  factory DaemonUdpTelemetry.fromJson(JsonView? v) =>
      v == null ? const DaemonUdpTelemetry(null) : DaemonUdpTelemetry(v);

  final JsonView? _v;

  bool get enabled => _v?.flag('enabled') ?? false;
  bool get running => _v?.flag('running') ?? false;
  bool get active => _v?.flag('active', running) ?? false;
  String get host => _v?.str('host') ?? '';
  int get port => _v?.int_('port', 1347) ?? 1347;
  int get hz => _v?.int_('hz') ?? 0;
  int get sentPackets => _v?.int_('sent_packets') ?? 0;
  int get sendErrors => _v?.int_('send_errors') ?? 0;
}

class Resources {
  const Resources(this._v);
  factory Resources.fromJson(JsonView? v) =>
      v == null ? const Resources(null) : Resources(v);

  final JsonView? _v;

  bool get vbActive => _v?.flag('vb_active') ?? false;
  int get vbPoolCount => _v?.int_('vb_pool_count') ?? 0;
  bool get mipiLoaded => _v?.flag('mipi_loaded') ?? false;
  int get mipiUsers => _v?.int_('mipi_users') ?? 0;
  double? get temperatureC => _v?.num_('temperature_c')?.toDouble();
  double? get powerW => _v?.num_('power_w')?.toDouble();
  bool get needsReboot => _v?.flag('needs_reboot') ?? false;
}

class WorkerState {
  factory WorkerState.fromJson(JsonView v) => WorkerState._(v);

  WorkerState._(this._v) {
    timestampMs = _v.int_('timestamp_ms');
    frameCount = _v.int_('frame_count');
    lifecycle = LifecycleState.fromJson(_v.nested('lifecycle'));
    performance = Performance.fromJson(_v.nested('performance'));
    target = Target.fromJson(_v.nested('target'));
    vision = Vision.fromJson(_v.nested('vision'));
    camera = Camera.fromJson(_v.nested('camera'));
    view = ViewState.fromJson(_v.nested('view'));
    overlay = OverlayState.fromJson(_v.nested('overlay'));
    control = ControlState.fromJson(_v.nested('control'));
    uart = UartState.fromJson(_v.nested('uart'));
    stream = StreamState.fromJson(_v.nested('stream'));
    udpTelemetry = WorkerUdpTelemetry.fromJson(_v.nested('udp_telemetry'));
    debug = DebugState.fromJson(_v.nested('debug'));
  }

  final JsonView _v;

  late final int timestampMs;
  late final int frameCount;

  late final LifecycleState lifecycle;
  late final Performance performance;
  late final Target target;
  late final Vision vision;
  late final Camera camera;
  late final ViewState view;
  late final OverlayState overlay;
  late final ControlState control;
  late final UartState uart;
  late final StreamState stream;
  late final WorkerUdpTelemetry udpTelemetry;
  late final DebugState debug;
}

class LifecycleState {
  const LifecycleState(this._v);
  factory LifecycleState.fromJson(JsonView? v) =>
      v == null ? const LifecycleState(null) : LifecycleState(v);

  final JsonView? _v;

  String get state => _v?.str('state') ?? '';
  bool get sensorStandby => _v?.flag('sensor_standby') ?? false;
  int get reg0100 => _v?.int_('reg0100') ?? 0;
  int get standbyMs => _v?.int_('standby_ms') ?? 0;
  double get lastWakeMs => _v?.dbl('last_wake_ms') ?? 0;
  int get standbyCount => _v?.int_('standby_count') ?? 0;
  int get standbyFailures => _v?.int_('standby_failures') ?? 0;
  int get wakeCount => _v?.int_('wake_count') ?? 0;
  int get wakeFailures => _v?.int_('wake_failures') ?? 0;
}

class Performance {
  const Performance(this._v);
  factory Performance.fromJson(JsonView? v) =>
      v == null ? const Performance(null) : Performance(v);

  final JsonView? _v;

  double get fps => _v?.dbl('fps') ?? 0;
  int get requestedFps => _v?.int_('requested_fps') ?? 0;
  double get processMs => _v?.dbl('process_ms') ?? 0;
  double get detectionFps => _v?.dbl('detection_fps') ?? 0;
  double get processMaxMs => _v?.dbl('process_max_ms') ?? 0;
  int get timeouts => _v?.int_('timeouts') ?? 0;
  int get errors => _v?.int_('errors') ?? 0;
}

class Target {
  const Target(this._v);
  factory Target.fromJson(JsonView? v) =>
      v == null ? const Target(null) : Target(v);

  final JsonView? _v;

  bool get found => _v?.flag('found') ?? false;
  int get x => _v?.int_('x') ?? 0;
  int get y => _v?.int_('y') ?? 0;
  int get pixels => _v?.int_('pixels') ?? 0;
  int get area => _v?.int_('area') ?? 0;
  List<int> get rect => _v?.intList('rect') ?? const [];
  double get brightness => _v?.dbl('brightness') ?? 0;
  double get pitchControl => _v?.dbl('pitch_control') ?? 0;
  double get yawControl => _v?.dbl('yaw_control') ?? 0;
}

class GreenScore {
  const GreenScore(this._v);
  factory GreenScore.fromJson(JsonView? v) =>
      v == null ? const GreenScore(null) : GreenScore(v);

  final JsonView? _v;

  int get yMin => _v?.int_('y_min') ?? 0;
  int get gMin => _v?.int_('g_min') ?? 0;
  int get scoreMin => _v?.int_('score_min') ?? 0;
  int get rgMin => _v?.int_('rg_min') ?? 0;
  int get gbMin => _v?.int_('gb_min') ?? 0;
}

class VisionProfileUs {
  const VisionProfileUs(this._v);
  factory VisionProfileUs.fromJson(JsonView? v) =>
      v == null ? const VisionProfileUs(null) : VisionProfileUs(v);

  final JsonView? _v;

  int get threshold => _v?.int_('threshold') ?? 0;
  int get blob => _v?.int_('blob') ?? 0;
  int get coarseSamples => _v?.int_('coarse_samples') ?? 0;
  int get fineSamples => _v?.int_('fine_samples') ?? 0;
  int get coarsePasses => _v?.int_('coarse_passes') ?? 0;
  int get finePasses => _v?.int_('fine_passes') ?? 0;
}

class Vision {
  const Vision(this._v);
  factory Vision.fromJson(JsonView? v) =>
      v == null ? const Vision(null) : Vision(v);

  final JsonView? _v;

  GreenScore get greenScore => GreenScore.fromJson(_v?.nested('green_score'));
  List<int> get detectRoi => _v?.intList('detect_roi') ?? const [];
  int get searchRadius => _v?.int_('search_radius') ?? 0;
  int get areaThreshold => _v?.int_('area_threshold') ?? 0;
  int get pixelsThreshold => _v?.int_('pixels_threshold') ?? 0;
  int get xStride => _v?.int_('x_stride') ?? 0;
  int get yStride => _v?.int_('y_stride') ?? 0;
  int get detectEveryN => _v?.int_('detect_every_n') ?? 0;
  int get detectionFrames => _v?.int_('detection_frames') ?? 0;
  int get jobsDropped => _v?.int_('jobs_dropped') ?? 0;
  int get detectionAgeFrames => _v?.int_('detection_age_frames') ?? 0;
  VisionProfileUs get profileUs =>
      VisionProfileUs.fromJson(_v?.nested('profile_us'));
}

class CameraIsp {
  const CameraIsp(this._v);
  factory CameraIsp.fromJson(JsonView? v) =>
      v == null ? const CameraIsp(null) : CameraIsp(v);

  final JsonView? _v;

  bool get valid => _v?.flag('valid') ?? false;
  int get exposureUs => _v?.int_('exposure_us') ?? 0;
  int get again => _v?.int_('again') ?? 0;
  int get dgain => _v?.int_('dgain') ?? 0;
  int get ispDgain => _v?.int_('isp_dgain') ?? 0;
  int get iso => _v?.int_('iso') ?? 0;
  int get averageLuma => _v?.int_('average_luma') ?? 0;
  bool get awbAuto => _v?.flag('awb_auto') ?? false;
  bool get wbValid => _v?.flag('wb_valid') ?? false;
  List<int> get wbGain => _v?.intList('wb_gain') ?? const [];
  int get colorTemperature => _v?.int_('color_temperature') ?? 0;
}

class Camera {
  const Camera(this._v);
  factory Camera.fromJson(JsonView? v) =>
      v == null ? const Camera(null) : Camera(v);

  final JsonView? _v;

  List<int> get output => _v?.intList('output') ?? const [];
  List<int> get sensor => _v?.intList('sensor') ?? const [];
  String get format => _v?.str('format') ?? '';
  int get exposureUs => _v?.int_('exposure_us') ?? 0;
  int get gain => _v?.int_('gain') ?? 0;
  int get again => _v?.int_('again') ?? 0;
  int get dgain => _v?.int_('dgain') ?? 0;
  int get ispDgain => _v?.int_('isp_dgain') ?? 0;
  bool get awbAuto => _v?.flag('awb_auto') ?? false;
  bool get ispAdaptiveTone => _v?.flag('isp_adaptive_tone') ?? true;
  bool get streaming => _v?.flag('streaming') ?? false;
  CameraIsp get isp => CameraIsp.fromJson(_v?.nested('isp'));
}

class WorkerUdpTelemetry {
  const WorkerUdpTelemetry(this._v);
  factory WorkerUdpTelemetry.fromJson(JsonView? v) =>
      v == null ? const WorkerUdpTelemetry(null) : WorkerUdpTelemetry(v);

  final JsonView? _v;

  bool get enabled => _v?.flag('enabled') ?? false;
  bool get running => _v?.flag('running') ?? false;
  bool get active => _v?.flag('active', running) ?? false;
  String get host => _v?.str('host') ?? '';
  int get port => _v?.int_('port', 1347) ?? 1347;
  int get hz => _v?.int_('hz') ?? 0;
  int get sequence => _v?.int_('sequence') ?? 0;
  int get sentPackets => _v?.int_('sent_packets') ?? 0;
  int get sendErrors => _v?.int_('send_errors') ?? 0;
  int get lastSendAgeMs => _v?.int_('last_send_age_ms') ?? -1;
}

class ViewState {
  const ViewState(this._v);
  factory ViewState.fromJson(JsonView? v) =>
      v == null ? const ViewState(null) : ViewState(v);

  final JsonView? _v;

  String get profile => _v?.str('profile') ?? '';
  bool get cropEnabled => _v?.flag('crop_enabled') ?? false;
  List<int> get crop => _v?.intList('crop') ?? const [];
  List<int> get preRotationOutput =>
      _v?.intList('pre_rotation_output') ?? const [];
  int get rotation => _v?.int_('rotation') ?? 0;
  int get visibleOffsetX => _v?.int_('visible_offset_x') ?? 0;
  List<int> get output => _v?.intList('output') ?? const [];
  List<double> get scale => _v?.dblList('scale') ?? const [];
  String get coordinateSpace => _v?.str('coordinate_space') ?? '';
}

class OverlayState {
  const OverlayState(this._v);
  factory OverlayState.fromJson(JsonView? v) =>
      v == null ? const OverlayState(null) : OverlayState(v);

  final JsonView? _v;

  bool get enabled => _v?.flag('enabled') ?? false;
  bool get roi => _v?.flag('roi') ?? false;
  bool get frameSync => _v?.flag('frame_sync') ?? false;
  int get syncTimeoutMs => _v?.int_('sync_timeout_ms', 6) ?? 6;
  int get matchedFrames => _v?.int_('matched_frames') ?? 0;
  int get missedFrames => _v?.int_('missed_frames') ?? 0;
  int get lastWaitUs => _v?.int_('last_wait_us') ?? 0;
  int get maxWaitUs => _v?.int_('max_wait_us') ?? 0;
  int get detectionFrameId => _v?.int_('detection_frame_id') ?? 0;
}

class ControlState {
  const ControlState(this._v);
  factory ControlState.fromJson(JsonView? v) =>
      v == null ? const ControlState(null) : ControlState(v);

  final JsonView? _v;

  String get mode => _v?.str('mode') ?? '';
  double get fx => _v?.dbl('fx') ?? 0;
  double get fy => _v?.dbl('fy') ?? 0;
  String get rollUnit => _v?.str('roll_unit') ?? '';
  double get rollSign => _v?.dbl('roll_sign', 1) ?? 1;
  double get distance => _v?.dbl('distance') ?? 0;
}

class UartState {
  const UartState(this._v);
  factory UartState.fromJson(JsonView? v) =>
      v == null ? const UartState(null) : UartState(v);

  final JsonView? _v;

  bool get open => _v?.flag('open') ?? false;
  int get rxBytes => _v?.int_('rx_bytes') ?? 0;
  int get rxPackets => _v?.int_('rx_packets') ?? 0;
  int get crcErrors => _v?.int_('crc_errors') ?? 0;
  int get decodeErrors => _v?.int_('decode_errors') ?? 0;
  int get alignDrops => _v?.int_('align_drops') ?? 0;
  int get txPackets => _v?.int_('tx_packets') ?? 0;
  int get txErrors => _v?.int_('tx_errors') ?? 0;
  int get txLastGapUs => _v?.int_('tx_last_gap_us') ?? 0;
  int get txMinGapUs => _v?.int_('tx_min_gap_us') ?? 0;
  int get txMaxGapUs => _v?.int_('tx_max_gap_us') ?? 0;
  bool get telemetryValid => _v?.flag('telemetry_valid') ?? false;
  double get pitch => _v?.dbl('pitch') ?? 0;
  double get roll => _v?.dbl('roll') ?? 0;
  double get yaw => _v?.dbl('yaw') ?? 0;
  double get airSpeed => _v?.dbl('air_speed') ?? 0;
  Map<String, dynamic> get rxLayout => _v?.raw('rx_layout') ?? const {};
  Map<String, double> get values {
    final raw = _v?.raw('values') ?? const {};
    return {
      for (final entry in raw.entries)
        if (entry.value is num) entry.key: (entry.value as num).toDouble(),
    };
  }
}

class StreamState {
  const StreamState(this._v);
  factory StreamState.fromJson(JsonView? v) =>
      v == null ? const StreamState(null) : StreamState(v);

  final JsonView? _v;

  bool get rtspEnabled => _v?.flag('rtsp_enabled') ?? false;
  int get rtspPort => _v?.int_('rtsp_port', 8554) ?? 8554;
  int get sourceFrames => _v?.int_('source_frames') ?? 0;
  int get inputFrames => _v?.int_('input_frames') ?? 0;
  int get rtspClients => _v?.int_('rtsp_clients') ?? 0;
  int get encodedFrames => _v?.int_('encoded_frames') ?? 0;
  int get encodedBytes => _v?.int_('encoded_bytes') ?? 0;
}

class DebugState {
  const DebugState(this._v);
  factory DebugState.fromJson(JsonView? v) =>
      v == null ? const DebugState(null) : DebugState(v);

  final JsonView? _v;

  int get clients => _v?.int_('clients') ?? 0;
  int get accepted => _v?.int_('accepted') ?? 0;
  int get commands => _v?.int_('commands') ?? 0;
  int get errors => _v?.int_('errors') ?? 0;
}
