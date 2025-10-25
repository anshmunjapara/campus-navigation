import 'dart:async';
import 'package:apple_maps_flutter/apple_maps_flutter.dart' as amf;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:geolocator/geolocator.dart';

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
  bool _isJourneyActive = false;
  bool get isJourneyActive => _isJourneyActive;

  amf.CameraPosition cameraPosition = const amf.CameraPosition(target: uRegina, zoom: 16);

  final Set<amf.Annotation> annotations = {};
  final Set<amf.Polyline> polylines = {};

  // Original route points (if provided by classroom)
  List<amf.LatLng> _routePoints = [];

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
    annotations
      ..clear()
      ..addAll(all.map((c) => amf.Annotation(
            annotationId: amf.AnnotationId(c.id),
            position: amf.LatLng(c.coordinate.lat, c.coordinate.lng),
            infoWindow: amf.InfoWindow(title: c.name, snippet: c.id),
            onTap: () => focusOn(c),
          )));
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
        accuracy: LocationAccuracy.best,
        distanceFilter: 2,
      ),
    ).listen((pos) {
      final userPos = amf.LatLng(pos.latitude, pos.longitude);

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

      // Update remaining route by trimming the already-walked segment
      if (_routePoints.isNotEmpty) {
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

      // Follow user
      _controller?.animateCamera(amf.CameraUpdate.newLatLng(userPos));

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
  }

  void stopJourney() {
    _positionSub?.cancel();
    _positionSub = null;
    _isJourneyActive = false;
    // Clear user trail but keep destination marker; also clear remaining route
    if (_routePoints.isNotEmpty) {
      polylines.removeWhere((p) => p.polylineId.value.startsWith('route_'));
    }
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
