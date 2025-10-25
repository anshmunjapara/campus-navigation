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
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.best, distanceFilter: 1),
    ).listen((pos) {
      if (!mounted) return;
      setState(() => _position = pos);
    });

    // compass stream
    _compassSub = FlutterCompass.events?.listen((event) {
      if (!mounted) return;
      if (event.heading != null) {
        setState(() => _headingDeg = event.heading);
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
    double? distance;
    if (pos != null && heading != null) {
      final bearing = _bearingDegrees(pos.latitude, pos.longitude, dest.lat, dest.lng);
      final diff = ((bearing - heading + 540) % 360) - 180; // -180..180
      arrowRotationRad = diff * math.pi / 180;
      distance = Geolocator.distanceBetween(pos.latitude, pos.longitude, dest.lat, dest.lng);
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          if (cam != null && cam.value.isInitialized)
            CameraPreview(cam)
          else
            const Center(child: CircularProgressIndicator()),

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
                            if (distance != null)
                              Text('${distance.toStringAsFixed(distance > 100 ? 0 : 1)} m', style: const TextStyle(color: Colors.white70)),
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
}
