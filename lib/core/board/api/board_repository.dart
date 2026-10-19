import 'package:dart_control_panel/core/board/models/daemon_state.dart';
import 'package:dart_control_panel/core/board/models/profile.dart';
import 'package:dart_control_panel/core/board/api/daemon_client.dart';
import 'package:dart_control_panel/core/board/api/protocol_exception.dart';

/// Result of a successful `apply_runtime`: the daemon's confirmation message
/// plus the freshly fetched state (actual ISP/vision readback).
class ApplyRuntimeResult {
  const ApplyRuntimeResult({required this.message, required this.state});

  final String message;
  final DaemonState state;
}

/// Typed access to the board daemon over the NDJSON v1 control plane.
///
/// Owns the request-id allocator (monotonically increasing Dart int). All
/// state-returning operations unwrap the double envelope
/// (`result.payload` -> state envelope -> `result.payload.payload`), so every
/// method returning [DaemonState] is safe to feed the UI directly.
class BoardRepository {
  BoardRepository(this._client);

  final DaemonClient _client;
  int _nextId = 0;

  /// Monotonically increasing request id; never reused within a session.
  int get nextId => ++_nextId;

  /// The raw DaemonClient, for ops this repository does not type yet.
  DaemonClient get client => _client;

  /// `get_state` -> unwrapped [DaemonState].
  Future<DaemonState> getState() async {
    final msg = await _client.call(id: nextId, op: 'get_state');
    return DaemonState.fromEnvelope(_requirePayload(msg, 'get_state'));
  }

  /// `get_profiles` -> map keyed by profile name.
  Future<Map<String, Profile>> getProfiles() async {
    final msg = await _client.call(id: nextId, op: 'get_profiles');
    final payload = _requirePayload(msg, 'get_profiles');
    // Current protocol wraps the table so schema_version can evolve without
    // becoming a fake profile. Accept the short-lived flat v1 form too.
    final rawProfiles = payload['profiles'];
    final profiles = rawProfiles is Map
        ? Map<String, dynamic>.from(rawProfiles)
        : payload;
    return profiles.map((name, raw) {
      final json = raw is Map
          ? Map<String, dynamic>.from(raw)
          : <String, dynamic>{};
      return MapEntry(name, Profile.fromJson(json));
    });
  }

  /// The one complete persistent board configuration.
  Future<Map<String, dynamic>> getConfig() async {
    final msg = await _client.call(id: nextId, op: 'get_config');
    return Map<String, dynamic>.from(_requirePayload(msg, 'get_config'));
  }

  /// Replaces the complete persistent configuration after daemon validation.
  Future<DaemonState> setConfig(Map<String, dynamic> config) =>
      _stateOp('set_config', {'config': config});

  /// `get_schema` -> raw capability map.
  Future<Map<String, dynamic>> getSchema() async {
    final msg = await _client.call(id: nextId, op: 'get_schema');
    return _requirePayload(msg, 'get_schema');
  }

  /// The active worker's indexed UDP channels and negotiated UART types.
  Future<Map<String, dynamic>> getTelemetrySchema() async {
    final msg = await _client.call(id: nextId, op: 'get_telemetry_schema');
    return _requirePayload(msg, 'get_telemetry_schema');
  }

  /// Ground-only recording maintenance; HTTP file transport stays read-only.
  Future<Map<String, dynamic>> cleanupRecordings() async {
    final msg = await _client.call(id: nextId, op: 'cleanup_recordings');
    return _requirePayload(msg, 'cleanup_recordings');
  }

  Future<Map<String, dynamic>> deleteRecording(String path) async {
    final msg = await _client.call(
      id: nextId,
      op: 'delete_recording',
      args: {'path': path, 'confirm': true},
    );
    return _requirePayload(msg, 'delete_recording');
  }

  /// `get_logs` with 1..500 lines.
  Future<List<String>> getLogs({int lines = 120}) async {
    final msg = await _client.call(
      id: nextId,
      op: 'get_logs',
      args: {'lines': lines.clamp(1, 500).toInt()},
    );
    final payload = _requirePayload(msg, 'get_logs');
    final raw = payload['lines'];
    if (raw is! List) return const [];
    return raw.whereType<String>().toList();
  }

  /// `heartbeat` -> daemon time/state map.
  Future<Map<String, dynamic>> heartbeat() async {
    final msg = await _client.call(id: nextId, op: 'heartbeat');
    return _requirePayload(msg, 'heartbeat');
  }

  /// `apply_runtime` with only the changed fields, then refreshes state so
  /// the UI shows the actual ISP/vision readback. On `ok:false` the daemon
  /// error surfaces as [OperationFailedException] and no refresh happens.
  Future<ApplyRuntimeResult> applyRuntime(Map<String, dynamic> args) async {
    final msg = await _client.call(id: nextId, op: 'apply_runtime', args: args);
    final refreshed = await getState();
    return ApplyRuntimeResult(message: msg.message ?? '', state: refreshed);
  }

  // --- P4 camera lifecycle (all return the state envelope, unwrapped) ------

  /// `start_worker`; without [profile] the daemon uses last-known-good.
  Future<DaemonState> startWorker({String? profile}) =>
      _stateOp('start_worker', profile == null ? null : {'profile': profile});

  Future<DaemonState> stopWorker() => _stateOp('stop_worker');

  Future<DaemonState> restartWorker() => _stateOp('restart_worker');

  /// GC4653 software standby; the control plane stays online.
  Future<DaemonState> cameraStandby() => _stateOp('camera_standby');

  /// Fast wake with continuous-frame verification.
  Future<DaemonState> cameraWake() => _stateOp('camera_wake');

  /// Transactional readout profile switch; the daemon rolls back on failure.
  Future<DaemonState> applyReadoutProfile(String profile) =>
      _stateOp('apply_readout_profile', {'profile': profile});

  Future<DaemonState> setUart(bool enabled) =>
      _stateOp('set_uart', {'enabled': enabled});

  /// 0/90/180/270 only; restarts the worker while running.
  Future<DaemonState> setRotation(int degrees) =>
      _stateOp('set_rotation', {'degrees': degrees});

  /// Atomically switches the complete board policy between ground/flight.
  Future<DaemonState> setOperatingMode(String mode) =>
      _stateOp('set_operating_mode', {'mode': mode});

  /// Starts/stops one flight capture session. Valid only in flight mode.
  Future<DaemonState> setFlightActive(bool active) =>
      _stateOp('set_flight_active', {'active': active});

  /// Reboots the board with the required explicit confirmation. Returns the
  /// reboot schedule payload. Never call this without a user double-confirm.
  Future<Map<String, dynamic>> rebootBoard({bool confirm = true}) async {
    final msg = await _client.call(
      id: nextId,
      op: 'reboot_board',
      args: {'confirm': confirm},
    );
    final payload = msg.payload;
    if (payload == null) {
      throw ProtocolDecodeException('reboot_board returned no payload');
    }
    return payload;
  }

  /// Sends an arbitrary request. Only for emerging-v1 operations; typed
  /// helpers above are the primary interface.
  Future<Map<String, dynamic>> callRaw(
    String op, {
    Map<String, dynamic>? args,
  }) async {
    final msg = await _client.call(id: nextId, op: op, args: args);
    return msg.payload ?? const {};
  }

  Future<void> close() => _client.close();

  Map<String, dynamic> _requirePayload(ResponseMessage msg, String op) {
    final payload = msg.payload;
    if (payload == null) {
      throw ProtocolDecodeException('$op returned no payload');
    }
    return payload;
  }

  Future<DaemonState> _stateOp(String op, [Map<String, dynamic>? args]) async {
    final msg = await _client.call(id: nextId, op: op, args: args);
    return DaemonState.fromEnvelope(_requirePayload(msg, op));
  }
}
