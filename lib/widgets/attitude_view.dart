import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Simple 3D vector used by the attitude renderer.
class _Vec3 {
  const _Vec3(this.x, this.y, this.z);

  final double x;
  final double y;
  final double z;

  _Vec3 operator +(Object other) {
    final v = other as _Vec3;
    return _Vec3(x + v.x, y + v.y, z + v.z);
  }

  _Vec3 operator -(Object other) {
    final v = other as _Vec3;
    return _Vec3(x - v.x, y - v.y, z - v.z);
  }

  _Vec3 operator *(double s) => _Vec3(x * s, y * s, z * s);

  double dot(_Vec3 o) => x * o.x + y * o.y + z * o.z;

  _Vec3 cross(_Vec3 o) => _Vec3(
        y * o.z - z * o.y,
        z * o.x - x * o.z,
        x * o.y - y * o.x,
      );

  double get length => math.sqrt(x * x + y * y + z * z);

  _Vec3 normalized() {
    final l = length;
    return l < 1e-9 ? this : _Vec3(x / l, y / l, z / l);
  }
}

/// Fixed-looking perspective camera (side view): positioned on a sphere
/// around the origin by [azimuthDeg] / [elevationDeg] at [distance], looking
/// at the origin with world +Y as up. The ground therefore stays put while
/// the missile rotates around its center.
class _Camera {
  const _Camera();

  // Fixed side-view angle: behind-left of the missile (nose points +Z).
  static const double _azimuthDeg = 212;
  static const double _elevationDeg = 20;
  static const double _distance = 7.2;
  static const _worldUp = _Vec3(0, 1, 0);

  _Vec3 get position {
    final a = _azimuthDeg * math.pi / 180;
    final e = _elevationDeg * math.pi / 180;
    return _Vec3(
      _distance * math.cos(e) * math.sin(a),
      _distance * math.sin(e),
      _distance * math.cos(e) * math.cos(a),
    );
  }

  _Vec3 get forward => (position * -1).normalized();
  _Vec3 get right => forward.cross(_worldUp).normalized();
  _Vec3 get up => right.cross(forward);

  /// Projects a world-space point into canvas space (perspective).
  Offset project(_Vec3 world, Size size, {double focal = 320}) {
    final rel = world - position;
    final z = rel.dot(forward); // positive = in front of the camera
    final x = rel.dot(right);
    final y = rel.dot(up);
    final scale = z > 1e-9 ? focal / z : 0.0;
    return Offset(
      size.width / 2 + x * scale,
      size.height / 2 - y * scale,
    );
  }

  /// View-space depth (larger = closer to the camera); used for sorting.
  double depth(_Vec3 world) => (world - position).dot(forward);
}

class _Face {
  _Face(this.color, this.points);
  final Color color;
  final List<_Vec3> points;
}

/// Missile geometry in the **body frame**, centered on the origin:
/// nose along +Z (longitudinal), Y up, X right. Rotating around the origin
/// therefore spins the missile around its own center point.
class _MissileGeometry {
  List<_Face> build() {
    const segments = 12;
    const bodyR = 0.24;
    const noseTip = _Vec3(0, 0, 1.12);
    const coneBaseZ = 0.45;
    const tailZ = -1.12;

    final faces = <_Face>[];
    final coneRing = _ring(coneBaseZ, bodyR, segments);
    final tailRing = _ring(tailZ, 0.17, segments);

    // nose cone
    for (var i = 0; i < segments; i++) {
      final a = coneRing[i];
      final b = coneRing[(i + 1) % segments];
      faces.add(_Face(const Color(0xFFBF6154), [noseTip, a, b]));
    }
    // body cylinder
    for (var i = 0; i < segments; i++) {
      final a = coneRing[i];
      final b = coneRing[(i + 1) % segments];
      final c = tailRing[(i + 1) % segments];
      final d = tailRing[i];
      faces.add(_Face(const Color(0xFF9AA0A6), [a, b, c, d]));
    }
    // tail cap
    const tailCenter = _Vec3(0, 0, tailZ);
    for (var i = 0; i < segments; i++) {
      final a = tailRing[i];
      final b = tailRing[(i + 1) % segments];
      faces.add(_Face(const Color(0xFF6D7175), [tailCenter, a, b]));
    }
    // fins (4, at 45° diagonals so they read as an X from behind)
    const finColor = Color(0xFFD64550);
    for (final a in const [45.0, 135.0, 225.0, 315.0]) {
      final rad = a * math.pi / 180.0;
      final dir = _Vec3(math.cos(rad), math.sin(rad), 0);
      final inner = dir * 0.17;
      final outer = dir * 0.62;
      faces.add(_Face(finColor, [
        inner + const _Vec3(0, 0, -0.55),
        inner + const _Vec3(0, 0, tailZ),
        outer + const _Vec3(0, 0, tailZ),
        outer + const _Vec3(0, 0, -0.55),
      ]));
    }
    return faces;
  }

  static List<_Vec3> _ring(double z, double r, int n) => [
        for (var i = 0; i < n; i++)
          _Vec3(r * math.cos(2 * math.pi * i / n),
              r * math.sin(2 * math.pi * i / n), z),
      ];
}

/// Body-frame rotation from attitude angles (degrees):
/// `R = Rz(yaw) · Ry(pitch) · Rz(roll)` — roll about the longitudinal axis
/// first, pitch about Y, then yaw about the world vertical.
class _AttitudeRotation {
  _AttitudeRotation(this.pitchDeg, this.rollDeg, this.yawDeg);

  final double pitchDeg;
  final double rollDeg;
  final double yawDeg;

  _Vec3 apply(_Vec3 p) {
    var v = _rotZ(p, rollDeg * math.pi / 180);
    v = _rotY(v, pitchDeg * math.pi / 180);
    v = _rotZ(v, yawDeg * math.pi / 180);
    return v;
  }

  static _Vec3 _rotZ(_Vec3 p, double a) => _Vec3(
        p.x * math.cos(a) - p.y * math.sin(a),
        p.x * math.sin(a) + p.y * math.cos(a),
        p.z,
      );

  static _Vec3 _rotY(_Vec3 p, double a) => _Vec3(
        p.x * math.cos(a) + p.z * math.sin(a),
        p.y,
        -p.x * math.sin(a) + p.z * math.cos(a),
      );
}

/// 3D missile attitude indicator, viewed from behind-left:
/// - the missile spins around its own center (body-frame rotation);
/// - two orthogonal triads, both anchored at the missile center:
///   a fixed, never-rotating ground/inertial frame (neutral X/Y/Z) and the
///   rigid-body frame (colored x/y/z) that rotates with the model — when the
///   two frames diverge, yaw/pitch/roll are directly readable.
class AttitudeView extends StatelessWidget {
  const AttitudeView({
    super.key,
    required this.pitchDeg,
    required this.rollDeg,
    required this.yawDeg,
  });

  final double pitchDeg;
  final double rollDeg;
  final double yawDeg;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1,
      child: CustomPaint(
        painter: _AttitudePainter(
          pitchDeg: pitchDeg,
          rollDeg: rollDeg,
          yawDeg: yawDeg,
        ),
      ),
    );
  }
}

class _AttitudePainter extends CustomPainter {
  _AttitudePainter({
    required this.pitchDeg,
    required this.rollDeg,
    required this.yawDeg,
  });

  final double pitchDeg;
  final double rollDeg;
  final double yawDeg;

  static const _axisLen = 0.9;

  // ground/inertial frame: fixed in space, one neutral color for the triad
  static const _worldAxes = [
    (_Vec3(1, 0, 0), Color(0xFFB0BEC5), 'X'),
    (_Vec3(0, 1, 0), Color(0xFFB0BEC5), 'Y'),
    (_Vec3(0, 0, 1), Color(0xFFB0BEC5), 'Z'),
  ];
  // rigid-body frame: rotates with the missile, colored per axis
  static const _bodyAxes = [
    (_Vec3(1, 0, 0), Color(0xFFE57373), 'x'),
    (_Vec3(0, 1, 0), Color(0xFF81C784), 'y'),
    (_Vec3(0, 0, 1), Color(0xFF64B5F6), 'z'),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    double safeDeg(double v) => v.isNaN ? 0.0 : v;
    final rotation = _AttitudeRotation(
      safeDeg(pitchDeg),
      safeDeg(rollDeg),
      safeDeg(yawDeg),
    );
    final camera = _Camera();

    // ground/inertial frame: fixed at the missile center, never rotates
    _paintAxisFrame(canvas, size, camera, rotation, _worldAxes,
        worldFrame: true);
    _paintMissile(canvas, size, camera, rotation);
    // rigid-body frame: driven by the attitude; drawn last so it stays
    // readable even when it overlaps with the world frame (level attitude)
    _paintAxisFrame(canvas, size, camera, rotation, _bodyAxes,
        worldFrame: false);
  }

  void _paintMissile(
      Canvas canvas, Size size, _Camera camera, _AttitudeRotation rotation) {
    final projected = <({double depth, Path path, Color color})>[];
    for (final face in _MissileGeometry().build()) {
      final world = [for (final p in face.points) rotation.apply(p)];
      final offsets = [for (final p in world) camera.project(p, size)];
      final depth = world.map(camera.depth).reduce(math.min);
      final path = Path()
        ..moveTo(offsets.first.dx, offsets.first.dy);
      for (final o in offsets.skip(1)) {
        path.lineTo(o.dx, o.dy);
      }
      path.close();
      projected.add((depth: depth, path: path, color: face.color));
    }
    // far faces first (smaller camera depth)
    projected.sort((a, b) => a.depth.compareTo(b.depth));
    for (final f in projected) {
      canvas.drawPath(f.path, Paint()..color = f.color);
      canvas.drawPath(f.path, Paint()
        ..color = const Color(0x33000000)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8);
    }
    // center marker (rotation pivot)
    final c = camera.project(const _Vec3(0, 0, 0), size);
    canvas.drawCircle(c, 2.5, Paint()..color = const Color(0xFFEEEEEE));
  }

  /// Draws one orthogonal triad, both anchored at the missile center:
  /// the fixed world frame (unrotated) or the rigid-body frame (rotated by
  /// the current attitude).
  void _paintAxisFrame(
    Canvas canvas,
    Size size,
    _Camera camera,
    _AttitudeRotation rotation,
    List<(_Vec3, Color, String)> axes, {
    required bool worldFrame,
  }) {
    const at = _Vec3(0, 0, 0);
    final origin = camera.project(at, size);
    for (final (dir, color, label) in axes) {
      final rotated = worldFrame ? dir : rotation.apply(dir);
      final end = camera.project(at + rotated * _axisLen, size);
      canvas.drawLine(origin, end, Paint()
        ..color = color
        ..strokeWidth = worldFrame ? 2.0 : 1.6);
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: color,
            fontSize: worldFrame ? 12 : 10,
            fontWeight: FontWeight.bold,
            fontStyle: worldFrame ? FontStyle.normal : FontStyle.italic,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, end + const Offset(3, -13));
    }
  }

  @override
  bool shouldRepaint(covariant _AttitudePainter old) =>
      old.pitchDeg != pitchDeg ||
      old.rollDeg != rollDeg ||
      old.yawDeg != yawDeg;
}