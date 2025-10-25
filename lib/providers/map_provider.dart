import 'dart:async';
import 'package:apple_maps_flutter/apple_maps_flutter.dart' as amf;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:geolocator/geolocator.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'dart:math' as math;

import '../models/classroom.dart';
import '../classrooms_data.dart';

class MapProvider extends ChangeNotifier {
  // University of Regina approx center
  static const amf.LatLng uRegina = amf.LatLng(50.4152, -104.5886);

  String query = '';
  List<Classroom> all = [];
  List<Classroom> filtered = [];
  Classroom? selected;

  amf.AppleMapController? _controller;
  StreamSubscription<Position>? _positionSub;
  StreamSubscription<CompassEvent>? _compassSub;
  bool _isJourneyActive = false;
  bool get isJourneyActive => _isJourneyActive;

  // Whether AR view is active (suppress map polylines while true)
  bool _arActive = false;
  bool get isArActive => _arActive;

  amf.CameraPosition cameraPosition = const amf.CameraPosition(target: uRegina, zoom: 16);

  final Set<amf.Annotation> annotations = {};
  final Set<amf.Polyline> polylines = {};

  // Original route points (if provided by classroom)
  List<amf.LatLng> _routePoints = [];

  // Smoothed user position for stable camera and trimming
  amf.LatLng? _smoothedUser;
  DateTime _lastCameraUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  double? _headingDeg;

  Future<void> init() async {
    await _ensureLocationPermission();
    await _loadData();
    _buildAnnotations();
  }

  void onMapCreated(amf.AppleMapController c) {
    _controller = c;
  }

  Future<void> _ensureLocationPermission() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      debugPrint('Location services are disabled.');
      return;
    }
    LocationPermission perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.deniedForever || perm == LocationPermission.denied) {
      debugPrint('Location permission denied.');
    }
  }

  Future<void> _loadData() async {
    List<Classroom> loaded = [];
    try {
      final jsonStr = await rootBundle.loadString('assets/data/classrooms.json');
      final data = ClassroomData.fromJsonString(jsonStr);
      loaded = [...data.classrooms];
    } catch (e) {
      debugPrint('Unable to load classrooms.json from assets: $e');
      // Use code-defined data if provided (no dummy data)
      if (kClassrooms.isNotEmpty) {
        loaded = [...kClassrooms];
      }
    }
    all = loaded..sort((a, b) => a.name.compareTo(b.name));
    filtered = all;
    notifyListeners();
  }

  void _buildAnnotations() {
    // Start with no class markers; show destination marker only after selection
    annotations.clear();
    notifyListeners();
  }

  void setQuery(String q) {
    query = q;
    final t = q.trim().toLowerCase();
    if (t.isEmpty) {
      filtered = all;
    } else {
      filtered = all.where((c) => c.name.toLowerCase().contains(t) || c.id.toLowerCase().contains(t)).toList();
    }
    notifyListeners();
  }

  Future<void> focusOn(Classroom c) async {
    selected = c;
    polylines.clear();
    debugPrint('Focusing on ${c.id} @ ${c.coordinate.lat}, ${c.coordinate.lng}');

    // Show a dedicated destination marker with the classroom name
    annotations.removeWhere((a) => a.annotationId.value == 'destination');
    annotations.add(amf.Annotation(
      annotationId: amf.AnnotationId('destination'),
      position: amf.LatLng(c.coordinate.lat, c.coordinate.lng),
      infoWindow: amf.InfoWindow(title: c.name, snippet: c.id),
    ));

    // Cache full route if provided
    _routePoints = (c.polyline ?? [])
        .map((p) => amf.LatLng(p.lat, p.lng))
        .toList();

    if (_routePoints.isNotEmpty) {
      polylines.add(amf.Polyline(
        polylineId: amf.PolylineId('route_${c.id}'),
        points: _routePoints,
        color: const Color(0xFF0A84FF),
        width: 5,
      ));
    }
    notifyListeners();
    await _controller?.animateCamera(amf.CameraUpdate.newCameraPosition(amf.CameraPosition(
      target: amf.LatLng(c.coordinate.lat, c.coordinate.lng),
      zoom: 18,
    )));
  }

  void startJourney() {
    final dest = selected?.coordinate;
    if (dest == null) return;
    _isJourneyActive = true;
    notifyListeners();

    _positionSub?.cancel();
    _positionSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
      ),
    ).listen((pos) {
      final newPos = amf.LatLng(pos.latitude, pos.longitude);
      // Low-pass smoothing
      const alpha = 0.3;
      if (_smoothedUser == null) {
        _smoothedUser = newPos;
      } else {
        _smoothedUser = amf.LatLng(
          _smoothedUser!.latitude + alpha * (newPos.latitude - _smoothedUser!.latitude),
          _smoothedUser!.longitude + alpha * (newPos.longitude - _smoothedUser!.longitude),
        );
      }
      final userPos = _smoothedUser!;

      // Update/replace user marker
      annotations.removeWhere((a) => a.annotationId.value == 'user');
      annotations.add(
        amf.Annotation(
          annotationId: amf.AnnotationId('user'),
          position: userPos,
          infoWindow: const amf.InfoWindow(title: 'You'),
          icon: amf.BitmapDescriptor.defaultAnnotation,
        ),
      );

      // Update heading wedge polyline if heading available
      polylines.removeWhere((p) => p.polylineId.value == 'user_heading');
      if (_headingDeg != null && !_arActive) {
        final wedge = _buildHeadingWedge(userPos, _headingDeg!);
        polylines.add(amf.Polyline(
          polylineId: amf.PolylineId('user_heading'),
          points: wedge,
          color: const Color(0x660A84FF),
          width: 8,
        ));
      }

      // Update remaining route by trimming the already-walked segment
      if (!_arActive && _routePoints.isNotEmpty) {
        final remaining = _remainingRouteFrom(userPos);
        polylines
          ..removeWhere((p) => p.polylineId.value.startsWith('route_'))
          ..add(amf.Polyline(
            polylineId: amf.PolylineId('route_${selected!.id}'),
            points: remaining,
            color: const Color(0xFF0A84FF),
            width: 5,
          ));
      }

      // Throttled camera follow
      final now = DateTime.now();
      final since = now.difference(_lastCameraUpdate).inMilliseconds;
      if (since > 300) {
        _controller?.animateCamera(amf.CameraUpdate.newLatLng(userPos));
        _lastCameraUpdate = now;
      }

      notifyListeners();

      // Stop when close to destination
      final distance = Geolocator.distanceBetween(
        pos.latitude,
        pos.longitude,
        dest.lat,
        dest.lng,
      );
      if (distance < 10) {
        stopJourney();
      }
    }, onError: (e) {
      debugPrint('Position stream error: $e');
      stopJourney();
    });

    // Compass for heading wedge
    _compassSub?.cancel();
    _compassSub = FlutterCompass.events?.listen((event) {
      if (event.heading != null) {
        final h = event.heading!;
        _headingDeg = _smoothHeading(_headingDeg, h, 0.2);
      }
    });
  }

  void stopJourney() {
    _positionSub?.cancel();
    _positionSub = null;
    _compassSub?.cancel();
    _compassSub = null;
    _isJourneyActive = false;
    _smoothedUser = null;
    // Clear user trail but keep destination marker; also clear remaining route and heading wedge
    polylines.removeWhere((p) => p.polylineId.value.startsWith('route_') || p.polylineId.value == 'user_heading');
    notifyListeners();
  }

  // AR lifecycle hooks: hide map route while AR is open
  void arStart() {
    _arActive = true;
    polylines.clear();
    notifyListeners();
  }

  void arStop() {
    _arActive = false;
    notifyListeners();
  }

  // Compute the remaining route by trimming from the nearest route point to the current user position.
  List<amf.LatLng> _remainingRouteFrom(amf.LatLng user) {
    if (_routePoints.length <= 1) return _routePoints;
    int nearestIdx = 0;
    double best = double.infinity;
    for (int i = 0; i < _routePoints.length; i++) {
      final d = _haversineMeters(user, _routePoints[i]);
      if (d < best) {
        best = d;
        nearestIdx = i;
      }
    }
    // Ensure we always keep at least a tiny segment to render
    final slice = _routePoints.sublist(nearestIdx.clamp(0, _routePoints.length - 1));
    return slice;
  }

  double _haversineMeters(amf.LatLng a, amf.LatLng b) {
    return Geolocator.distanceBetween(a.latitude, a.longitude, b.latitude, b.longitude);
  }

  // Build a wedge polyline around the user pointing to heading
  List<amf.LatLng> _buildHeadingWedge(amf.LatLng user, double headingDeg) {
    const double dist = 20; // meters
    const double halfAngle = 35; // degrees
    final left = _offset(user, dist, headingDeg - halfAngle);
    final front = _offset(user, dist * 1.2, headingDeg);
    final right = _offset(user, dist, headingDeg + halfAngle);
    return [user, left, front, right, user];
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

  amf.LatLng _offset(amf.LatLng origin, double distanceMeters, double bearingDeg) {
    const double R = 6378137; // earth radius meters
    final brng = bearingDeg * (3.141592653589793 / 180.0);
    final lat1 = origin.latitude * (3.141592653589793 / 180.0);
    final lon1 = origin.longitude * (3.141592653589793 / 180.0);
    final lat2 = math.asin(math.sin(lat1) + math.cos(lat1) * math.cos(brng) * (distanceMeters / R));
    final lon2 = lon1 + math.atan2(math.sin(brng) * (distanceMeters / R) * math.cos(lat1), math.cos(distanceMeters / R) - math.sin(lat1) * math.sin(lat2));
    return amf.LatLng(lat2 * 180.0 / 3.141592653589793, lon2 * 180.0 / 3.141592653589793);
  }

  void clearSelection() {
    selected = null;
    polylines.clear();
    annotations.removeWhere((a) => a.annotationId.value == 'destination');
    notifyListeners();
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    super.dispose();
  }
}
