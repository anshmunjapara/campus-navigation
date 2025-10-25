import 'dart:convert';

class Coord {
  final double lat;
  final double lng;
  const Coord({required this.lat, required this.lng});

  static double _toDouble(dynamic v, {required String field}) {
    if (v is num) return v.toDouble();
    if (v is String) return double.parse(v);
    throw FormatException('Invalid $field: expected number or numeric string, got $v');
  }

  factory Coord.fromJson(Map<String, dynamic> json) {
    dynamic rawLat = json.containsKey('lat') ? json['lat'] : (json['latitude'] ?? json['y']);
    dynamic rawLng = json.containsKey('lng') ? json['lng'] : (json['longitude'] ?? json['lon'] ?? json['long'] ?? json['x']);
    // Handle accidentally nested coordinate objects (e.g., {lat: {lat:.., lng:..}, lng: ..})
    if (rawLat is Map) {
      rawLat = rawLat['lat'] ?? rawLat['latitude'] ?? rawLat['y'];
    }
    if (rawLng is Map) {
      rawLng = rawLng['lng'] ?? rawLng['longitude'] ?? rawLng['lon'] ?? rawLng['long'] ?? rawLng['x'];
    }
    if (rawLat == null || rawLng == null) {
      throw FormatException('Missing lat/lng in coordinate object: $json');
    }
    var lat = _toDouble(rawLat, field: 'lat');
    var lng = _toDouble(rawLng, field: 'lng');
    // Heuristic: swap if lat magnitude looks like a longitude
    if (lat.abs() > 90 && lng.abs() <= 90) {
      final tmp = lat; lat = lng; lng = tmp;
    }
    return Coord(lat: lat, lng: lng);
  }

  Map<String, dynamic> toJson() => {"lat": lat, "lng": lng};
}

class Classroom {
  final String id;
  final String name;
  final Coord coordinate;
  final List<Coord>? polyline;

  const Classroom({
    required this.id,
    required this.name,
    required this.coordinate,
    this.polyline,
  });

  static Coord _parseCoordFromDynamic(dynamic v) {
    if (v is Map<String, dynamic>) {
      // Flatten nested forms like {'lat': {'lat':..,'lng':..}, 'lng': {...}}
      final latVal = v['lat'] ?? v['latitude'] ?? v['y'];
      final lngVal = v['lng'] ?? v['longitude'] ?? v['lon'] ?? v['long'] ?? v['x'];
      if (latVal is Map || lngVal is Map) {
        final flat = <String, dynamic>{
          'lat': (latVal is Map)
              ? (latVal['lat'] ?? latVal['latitude'] ?? latVal['y'])
              : latVal,
          'lng': (lngVal is Map)
              ? (lngVal['lng'] ?? lngVal['longitude'] ?? lngVal['lon'] ?? lngVal['long'] ?? lngVal['x'])
              : lngVal,
        };
        return Coord.fromJson(flat);
      }
      return Coord.fromJson(v);
    }
    if (v is List && v.length >= 2) {
      final a = Coord._toDouble(v[0], field: 'lat');
      final b = Coord._toDouble(v[1], field: 'lng');
      // Detect [lng, lat] order and swap if needed
      if (a.abs() > 90 && b.abs() <= 90) {
        return Coord(lat: b, lng: a);
      }
      return Coord(lat: a, lng: b);
    }
    if (v is String && v.contains(',')) {
      final parts = v.split(',');
      final a = double.parse(parts[0].trim());
      final b = double.parse(parts[1].trim());
      if (a.abs() > 90 && b.abs() <= 90) {
        return Coord(lat: b, lng: a);
      }
      return Coord(lat: a, lng: b);
    }
    throw FormatException('Unsupported coordinate entry: $v');
  }

  factory Classroom.fromJson(Map<String, dynamic> json) {
    final id = (json['id'] ?? json['code'] ?? json['name']) as String;
    final name = (json['name'] ?? json['title'] ?? json['id']) as String;

    // coordinate may be nested or top-level
    Coord coord;
    if (json['coordinate'] != null) {
      coord = _parseCoordFromDynamic(json['coordinate']);
    } else {
      final lat = json['lat'] ?? json['latitude'];
      final lng = json['lng'] ?? json['longitude'] ?? json['lon'] ?? json['long'];
      if (lat == null || lng == null) {
        throw FormatException('Missing coordinate for classroom $id');
      }
      coord = Coord(lat: Coord._toDouble(lat, field: 'lat'), lng: Coord._toDouble(lng, field: 'lng'));
    }

    List<Coord>? poly;
    final rawPolyline = json['polyline'] ?? json['routePolyline'] ?? json['route'];
    if (rawPolyline is List) {
      poly = rawPolyline.map(_parseCoordFromDynamic).toList();
    }

    return Classroom(id: id, name: name, coordinate: coord, polyline: poly);
  }
}

class ClassroomData {
  final List<Classroom> classrooms;
  ClassroomData(this.classrooms);

  factory ClassroomData.fromJsonString(String str) {
    final Map<String, dynamic> m = json.decode(str) as Map<String, dynamic>;
    final raw = m['classrooms'];
    if (raw is List) {
      final list = raw.cast<Map<String, dynamic>>();
      return ClassroomData(list.map(Classroom.fromJson).toList());
    }
    // Also support a plain list at the top-level
    if (raw == null) {
      // Try interpreting the whole JSON as a list
      final decoded = json.decode(str);
      if (decoded is List) {
        final list = decoded.cast<Map<String, dynamic>>();
        return ClassroomData(list.map(Classroom.fromJson).toList());
      }
    }
    throw FormatException('Invalid classrooms JSON format. Expected {"classrooms": [...]} or an array.');
  }
}
