import 'daemon_state.dart';

/// Builds a copy-pasteable diagnostics summary from the live daemon state.
/// Used by the Diagnostics screen ("Copy summary") and by CLI diagnostics.
String buildDiagnosticsSummary(
  DaemonState state, {
  String? board,
  String? appVersion,
}) {
  final w = state.worker;
  final sb = StringBuffer()
    ..writeln('=== Dart Guidance control panel diagnostics ===')
    ..writeln('board=${board ?? '-'}')
    ..writeln('app_version=${appVersion ?? '-'}')
    ..writeln('daemon: ${state.state} '
        'profile=${state.profile} rotation=${state.rotation} '
        'config_rev=${state.configRev}')
    ..writeln('  pending_profile=${state.pendingProfile ?? '-'} '
        'last_known_good=${state.lastKnownGood}')
    ..writeln('  pid=${state.workerPid} '
        'uptime_s=${(state.daemonUptimeS ?? 0).toStringAsFixed(1)} '
        'restarts=${state.restarts}')
    ..writeln('  last_error=${state.lastError.isEmpty ? '-' : state.lastError}')
    ..writeln('features: preset=${state.features.preset} '
        'rtsp=${state.features.rtsp} recording=${state.features.recording} '
        'overlay=${state.features.overlay} uart=${state.features.uartEnabled}')
    ..writeln('resources: temperature_c=${state.resources.temperatureC ?? '-'} '
        'vb_pool=${state.resources.vbPoolCount} '
        'mipi=${state.resources.mipiLoaded}(users=${state.resources.mipiUsers}) '
        'needs_reboot=${state.resources.needsReboot}');
  if (w != null) {
    sb
      ..writeln('worker: frames=${w.frameCount} '
          'lifecycle_state=${w.lifecycle.state} '
          'sensor_standby=${w.lifecycle.sensorStandby} '
          'standby_count=${w.lifecycle.standbyCount} '
          'wake_failures=${w.lifecycle.wakeFailures}')
      ..writeln(
          'performance: fps=${w.performance.fps.toStringAsFixed(1)} '
          'requested=${w.performance.requestedFps} '
          'detection_fps=${w.performance.detectionFps.toStringAsFixed(1)} '
          'process_ms=${w.performance.processMs.toStringAsFixed(2)} '
          'max_ms=${w.performance.processMaxMs.toStringAsFixed(2)} '
          'errors=${w.performance.errors} timeouts=${w.performance.timeouts}')
      ..writeln('target: found=${w.target.found} '
          'pos=(${w.target.x},${w.target.y}) pixels=${w.target.pixels} '
          'area=${w.target.area} brightness=${w.target.brightness.toStringAsFixed(1)}')
      ..writeln(
          'camera: requested exposure_us=${w.camera.exposureUs} '
          'again=${w.camera.again}/${w.camera.dgain}/${w.camera.ispDgain} '
          '| actual ${w.camera.isp.exposureUs}/'
          '${w.camera.isp.again}/${w.camera.isp.dgain}/${w.camera.isp.ispDgain} '
          'iso=${w.camera.isp.iso} luma=${w.camera.isp.averageLuma} '
          'awb_auto=${w.camera.awbAuto} '
          'wb_gain=${w.camera.isp.wbGain.join('/')} '
          'ct_k=${w.camera.isp.colorTemperature}')
      ..writeln('vision: mode=${w.vision.detectorMode} '
          'roi=${w.vision.detectRoi.join(',')} '
          'fps_estimate=${w.vision.detectionFrames} '
          'jobs_dropped=${w.vision.jobsDropped}')
      ..writeln('uart: open=${w.uart.open} '
          'rx=${w.uart.rxPackets} tx=${w.uart.txPackets} '
          'crc_errors=${w.uart.crcErrors} telemetry=${w.uart.telemetryValid} '
          'p/r/y=${w.uart.pitch.toStringAsFixed(1)}/'
          '${w.uart.roll.toStringAsFixed(1)}/${w.uart.yaw.toStringAsFixed(1)}')
      ..writeln('stream: rtsp=${w.stream.rtspEnabled}:${w.stream.rtspPort} '
          'clients=${w.stream.rtspClients} recording=${w.stream.recording} '
          'path=${w.stream.recordPath.isEmpty ? '-' : w.stream.recordPath} '
          'fps=${w.stream.recordFps} source=${w.stream.sourceFrames} '
          'encoded_mb=${(w.stream.encodedBytes / 1048576).toStringAsFixed(1)} '
          'record_errors=${w.stream.recordErrors}');
  }
  return sb.toString();
}