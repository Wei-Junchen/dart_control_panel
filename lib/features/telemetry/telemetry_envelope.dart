/// A point for the chart: [seconds] = how far back in time (0 = now).
class TelemetryPoint {
  const TelemetryPoint(this.seconds, this.value);

  final double seconds;
  final double value;
}

/// Pixel/time buckets retain extrema (including single-sample spikes), unlike
/// every-Nth-point sampling. Input order is preserved even for reversed X.
class TelemetryEnvelope {
  TelemetryEnvelope(this.from, this.to, int columns)
    : _buckets = List.filled(columns.clamp(1, 8192), null);
  final double from, to;
  final List<_Bucket?> _buckets;
  int _order = 0;
  void add(TelemetryPoint point) {
    if (!point.value.isFinite || point.seconds < from || point.seconds > to) {
      return;
    }
    final index = to <= from
        ? 0
        : ((point.seconds - from) / (to - from) * _buckets.length)
              .floor()
              .clamp(0, _buckets.length - 1);
    final value = (_order++, point);
    final b = _buckets[index];
    if (b == null) {
      _buckets[index] = _Bucket(value);
    } else {
      b.last = value;
      if (point.value < b.min.$2.value) b.min = value;
      if (point.value > b.max.$2.value) b.max = value;
    }
  }

  List<TelemetryPoint> get points {
    final result = <int, TelemetryPoint>{};
    for (final b in _buckets) {
      if (b == null) continue;
      for (final value in [b.first, b.min, b.max, b.last]) {
        result[value.$1] = value.$2;
      }
    }
    final keys = result.keys.toList()..sort();
    return [for (final key in keys) result[key]!];
  }
}

class _Bucket {
  _Bucket(this.first) : min = first, max = first, last = first;
  final (int, TelemetryPoint) first;
  (int, TelemetryPoint) min, max, last;
}
