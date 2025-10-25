import 'dart:async';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';

import '../models/classroom.dart';

class ArNavScreen extends StatefulWidget {
  final Classroom destination;
  const ArNavScreen({super.key, required this.destination});

  @override
  State<ArNavScreen> createState() => _ArNavScreenState();
}

class _ArNavScreenState extends State<ArNavScreen> {
  CameraController? _cam;
  StreamSubscription<Position>? _posSub;
  StreamSubscription<CompassEvent>? _compassSub;
  double? _headingDeg; // device heading degrees (0..360)
  Position? _position; // user location

  @override
  void initState() {
    super.initState();
    _initCamera();
    _startSensors();
  }

  Future<void> _initCamera() async {
    try {
      final cams = await availableCameras();
      final back = cams.firstWhere((c) => c.lensDirection == CameraLensDirection.back, orElse: () => cams.first);
      final controller = CameraController(back, ResolutionPreset.high, enableAudio: false);
      await controller.initialize();
      if (!mounted) return;
      setState(() => _cam = controller);
    } catch (e) {
      debugPrint('Camera init failed: $e');
    }
  }

  void _startSensors() async {
    // location stream
    _posSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.bestForNavigation, distanceFilter: 0),
    ).listen((pos) {
      if (!mounted) return;
      setState(() {
        _position = pos;
      });
    });

    // compass stream
    _compassSub = FlutterCompass.events?.listen((event) {
      if (!mounted) return;
      if (event.heading != null) {
        final h = event.heading!;
        setState(() => _headingDeg = _smoothHeading(_headingDeg, h, 0.2));
      }
    });
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _compassSub?.cancel();
    _cam?.dispose();
    super.dispose();
  }

  double _bearingDegrees(double lat1, double lon1, double lat2, double lon2) {
    final phi1 = lat1 * math.pi / 180;
    final phi2 = lat2 * math.pi / 180;
    final dLon = (lon2 - lon1) * math.pi / 180;
    final y = math.sin(dLon) * math.cos(phi2);
    final x = math.cos(phi1) * math.sin(phi2) - math.sin(phi1) * math.cos(phi2) * math.cos(dLon);
    final brng = math.atan2(y, x);
    return (brng * 180 / math.pi + 360) % 360;
  }

  @override
  Widget build(BuildContext context) {
    final cam = _cam;
    final pos = _position;
    final heading = _headingDeg;
    final dest = widget.destination.coordinate;

    double? arrowRotationRad;
    double? distanceToDest;

    // Project polyline into screen-space offsets for AR overlay (disabled)
    // final List<Offset> routeOffsets = const []; // kept for optional overlay toggle

    if (pos != null && heading != null) {
      final route = widget.destination.polyline ?? const [];
      // Lookahead target along path to keep arrow "stuck" to route
      final lookahead = _dynamicLookahead(pos.speed);
      Coord targetCoord = route.isNotEmpty
          ? _lookaheadTarget(route, pos, lookaheadMeters: lookahead)
          : dest;

      final bearing = _bearingDegrees(pos.latitude, pos.longitude, targetCoord.lat, targetCoord.lng);
      final diff = ((bearing - heading + 540) % 360) - 180; // -180..180
      arrowRotationRad = diff * math.pi / 180;
      distanceToDest = Geolocator.distanceBetween(pos.latitude, pos.longitude, dest.lat, dest.lng);

      // AR path overlay disabled
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          if (cam != null && cam.value.isInitialized)
            CameraPreview(cam)
          else
            const Center(child: CircularProgressIndicator()),

          // Optional AR path overlay (disabled)
          // final bool showArPath = false;
          // if (showArPath)
          //   Positioned.fill(
          //     child: CustomPaint(
          //       painter: _ArPathPainter(const []),
          //     ),
          //   ),

          // Arrow overlay
          Center(
            child: Transform.rotate(
              angle: arrowRotationRad ?? 0,
              child: Icon(
                Icons.navigation_rounded,
                size: 120,
                color: Colors.white.withValues(alpha: 0.9),
              ),
            ),
          ),

          // HUD with name, distance, and Map/AR toggle
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Toggle
                  Align(
                    alignment: Alignment.topCenter,
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          FilledButton.tonal(
                            onPressed: () => Navigator.of(context).pop(),
                            child: const Text('Map'),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            onPressed: null, // already in AR
                            child: const Text('AR'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(widget.destination.name, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
                            const SizedBox(height: 4),
                            if (distanceToDest != null)
                              Text('${distanceToDest.toStringAsFixed(distanceToDest > 100 ? 0 : 1)} m', style: const TextStyle(color: Colors.white70)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Compute a lookahead target along the polyline from user's projected position
  Coord _lookaheadTarget(List<Coord> route, Position user, {double lookaheadMeters = 12}) {
    if (route.isEmpty) return Coord(lat: user.latitude, lng: user.longitude);
    if (route.length == 1) return route.first;

    // Use first point as local origin for planar projection
    final origin = route.first;

    // Precompute XY in meters for route points
    final pts = route
        .map((c) => _toXY(c.lat, c.lng, origin.lat, origin.lng))
        .toList(growable: false);
    final u = _toXY(user.latitude, user.longitude, origin.lat, origin.lng);

    // Find closest point on any segment (projection)
    double bestDist2 = double.infinity;
    int bestSeg = 0;
    double bestT = 0.0;
    for (int i = 0; i < pts.length - 1; i++) {
      final a = pts[i];
      final b = pts[i + 1];
      final ab = b - a;
      final ap = u - a;
      final ab2 = ab.dx * ab.dx + ab.dy * ab.dy;
      double t = 0.0;
      if (ab2 > 0) {
        t = ((ap.dx * ab.dx + ap.dy * ab.dy) / ab2).clamp(0.0, 1.0);
      }
      final proj = Offset(a.dx + t * ab.dx, a.dy + t * ab.dy);
      final dx = u.dx - proj.dx, dy = u.dy - proj.dy;
      final d2 = dx * dx + dy * dy;
      if (d2 < bestDist2) {
        bestDist2 = d2;
        bestSeg = i;
        bestT = t;
      }
    }

    // Advance along path by lookaheadMeters from projection
    double remain = lookaheadMeters;
    int seg = bestSeg;
    double t = bestT;
    while (true) {
      final a = pts[seg];
      final b = pts[seg + 1];
      final ab = b - a;
      final segLen = math.sqrt(ab.dx * ab.dx + ab.dy * ab.dy);
      final along = (1.0 - t) * segLen;
      if (remain <= along) {
        final ratio = t + remain / segLen;
        final px = a.dx + ratio * ab.dx;
        final py = a.dy + ratio * ab.dy;
        return _xyToCoord(px, py, origin.lat, origin.lng);
      } else {
        remain -= along;
        if (seg + 1 >= pts.length - 1) {
          // at end
          final end = pts.last;
          return _xyToCoord(end.dx, end.dy, origin.lat, origin.lng);
        }
        seg += 1;
        t = 0.0;
      }
    }
  }

  Offset _toXY(double lat, double lng, double oLat, double oLng) {
    const R = 6378137.0;
    final x = (lng - oLng) * (math.pi / 180.0) * R * math.cos(((lat + oLat) / 2.0) * (math.pi / 180.0));
    final y = (lat - oLat) * (math.pi / 180.0) * R;
    return Offset(x, y);
  }

  double _wrapAngle(double a) {
    var x = a % 360.0;
    if (x < -180) x += 360;
    if (x > 180) x -= 360;
    return x;
  }

  double _smoothHeading(double? prev, double current, double alpha) {
    if (prev == null) return current;
    final diff = _wrapAngle(current - prev);
    return prev + alpha * diff;
  }

  double _dynamicLookahead(double? speedMs) {
    // 8–25 m lookahead based on speed
    final v = (speedMs ?? 0).isFinite ? (speedMs ?? 0) : 0.0;
    final clamped = v < 0 ? 0 : (v > 3 ? 3 : v);
    return clamped * 4 + 8; // 0 m/s -> 8m, 3 m/s -> 20m
  }

  Coord _xyToCoord(double x, double y, double oLat, double oLng) {
    const R = 6378137.0;
    final lat = y / R * 180.0 / math.pi + oLat;
    final lng = x / (R * math.cos(((lat + oLat) / 2.0) * (math.pi / 180.0))) * 180.0 / math.pi + oLng;
    return Coord(lat: lat, lng: lng);
  }

  // AR route overlay disabled; helper methods removed.
}

/*
class _ArPathPainter extends CustomPainter {
  final List<Offset> offsets;
  _ArPathPainter(this.offsets);

  @override
  void paint(Canvas canvas, Size size) {
    if (offsets.length < 2) return;

    final center = Offset(size.width / 2, size.height / 2 + 100); // bias path lower
    final path = Path()..moveTo(center.dx + offsets.first.dx, center.dy + offsets.first.dy);
    for (int i = 1; i < offsets.length; i++) {
      final o = offsets[i];
      path.lineTo(center.dx + o.dx, center.dy + o.dy);
    }

    final paint = Paint()
      ..color = const Color(0xFF0A84FF).withValues(alpha: 0.9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // Outline for contrast
    final outline = Paint()
      ..color = Colors.black.withValues(alpha: 0.4)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    canvas.drawPath(path, outline);
    canvas.drawPath(path, paint);

    // Draw dots on points
    final dot = Paint()..color = Colors.white.withValues(alpha: 0.9);
    for (final o in offsets) {
      canvas.drawCircle(Offset(center.dx + o.dx, center.dy + o.dy), 2, dot);
    }
  }

  @override
  bool shouldRepaint(covariant _ArPathPainter oldDelegate) => oldDelegate.offsets != offsets;
}
*/
