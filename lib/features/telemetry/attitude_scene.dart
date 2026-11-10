import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Simple 3D vector used by the attitude renderer.
class AttitudeVector {
  const AttitudeVector(this.x, this.y, this.z);

  final double x;
  final double y;
  final double z;

  AttitudeVector operator +(AttitudeVector v) {
    return AttitudeVector(x + v.x, y + v.y, z + v.z);
  }

  AttitudeVector operator -(AttitudeVector v) {
    return AttitudeVector(x - v.x, y - v.y, z - v.z);
  }

  AttitudeVector operator *(double s) => AttitudeVector(x * s, y * s, z * s);

  double dot(AttitudeVector o) => x * o.x + y * o.y + z * o.z;

  AttitudeVector cross(AttitudeVector o) =>
      AttitudeVector(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x);

  double get length => math.sqrt(x * x + y * y + z * z);

  AttitudeVector normalized() {
    final l = length;
    return l < 1e-9 ? this : AttitudeVector(x / l, y / l, z / l);
  }
}

/// Fixed NED camera at k*(-1,0,0), looking at (0,0,0) along +X.
/// NED: +X north, +Y east, +Z down; visual up is therefore -Z.
class NedAttitudeCamera {
  const NedAttitudeCamera({this.k = 5.1}) : assert(k > 0);

  final double k;
  static const worldUp = AttitudeVector(0, 0, -1);

  AttitudeVector get position => AttitudeVector(-k, 0, 0);
  AttitudeVector get forward => (position * -1).normalized();
  AttitudeVector get right => forward.cross(worldUp).normalized();
  AttitudeVector get up => right.cross(forward);

  Offset project(AttitudeVector world, Size size, {double focal = 320}) {
    final rel = world - position;
    final z = rel.dot(forward);
    final scale = z > 1e-9 ? focal / z : 0.0;
    return Offset(
      size.width / 2 + rel.dot(right) * scale,
      size.height / 2 - rel.dot(up) * scale,
    );
  }

  /// Forward camera distance; larger values are farther away.
  double depth(AttitudeVector world) => (world - position).dot(forward);
}

/// Body-frame rotation from attitude angles (degrees):
/// `R = Rz(yaw) · Ry(pitch) · Rx(roll)` — right-handed NED yaw/pitch/roll,
/// with body +X forward, +Y right, +Z down.
class NedAttitudeRotation {
  NedAttitudeRotation(this.pitchDeg, this.rollDeg, this.yawDeg);

  final double pitchDeg;
  final double rollDeg;
  final double yawDeg;

  AttitudeVector apply(AttitudeVector p) {
    var v = _rotX(p, rollDeg * math.pi / 180);
    v = _rotY(v, pitchDeg * math.pi / 180);
    v = _rotZ(v, yawDeg * math.pi / 180);
    return v;
  }

  static AttitudeVector _rotX(AttitudeVector p, double a) => AttitudeVector(
    p.x,
    p.y * math.cos(a) - p.z * math.sin(a),
    p.y * math.sin(a) + p.z * math.cos(a),
  );

  static AttitudeVector _rotZ(AttitudeVector p, double a) => AttitudeVector(
    p.x * math.cos(a) - p.y * math.sin(a),
    p.x * math.sin(a) + p.y * math.cos(a),
    p.z,
  );

  static AttitudeVector _rotY(AttitudeVector p, double a) => AttitudeVector(
    p.x * math.cos(a) + p.z * math.sin(a),
    p.y,
    -p.x * math.sin(a) + p.z * math.cos(a),
  );
}
