
// services/distance_filter_service.dart
import 'dart:convert';
import 'package:http/http.dart' as http;

/// Encapsulates distance filtering based on walking time from home/work
/// using Google Geocoding + Directions APIs.
class DistanceFilterService {
  final String userId;
  final String adminLoginBase; // e.g., https://.../api/admin/loginTable/
  final String mapsApiKey;
  final http.Client _http;

  DistanceFilterService({
    required this.userId,
    required this.adminLoginBase,
    required this.mapsApiKey,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  String? _homeAdd;
  String? _workAdd;
  ({double lat, double lng})? _home;
  ({double lat, double lng})? _work;

  // Caches
  final Map<String, ({double lat, double lng})> _geocodeCache = {};
  // true  => within threshold
  // false => over threshold
  // null  => not computed yet
  final Map<String, bool?> _allowedByAddressCache = {};

  /// Call once during page init
  Future<void> init() async {
    await _loadAddresses();
    if (_homeAdd != null && _homeAdd!.trim().isNotEmpty) {
      _home = await _geocode(_homeAdd!);
    }
    if (_workAdd != null && _workAdd!.trim().isNotEmpty) {
      _work = await _geocode(_workAdd!);
    }
  }

  /// Synchronous cache hit if available (null if not yet computed).
  bool? cachedAllowFor({required String? shopAddress, required String? channel, int thresholdMin = 30}) {
    if (_isOnline(channel)) return true;
    final addr = (shopAddress ?? '').trim();
    if (addr.isEmpty) return true; // unknown address => don't block
    return _allowedByAddressCache[addr];
  }

  /// Main gate: returns true if (a) online, (b) unknown address, or
  /// (c) walking from home <= threshold OR walking from work <= threshold.
  /// On errors/timeouts, returns true (don’t block).
  Future<bool> allowFor({required String? shopAddress, required String? channel, int thresholdMin = 30}) async {
    if (_isOnline(channel)) return true;
    final addr = (shopAddress ?? '').trim();
    if (addr.isEmpty) return true;

    final cached = _allowedByAddressCache[addr];
    if (cached != null) return cached;

    try {
      // Resolve destination
      final dest = await _geocode(addr);
      if (dest == null) {
        _allowedByAddressCache[addr] = true;
        return true;
      }

      // If we have neither home nor work, don't block
      if (_home == null && _work == null) {
        _allowedByAddressCache[addr] = true;
        return true;
      }

      int? homeSecs;
      int? workSecs;

      if (_home != null) {
        homeSecs = await _walkingSeconds(_home!.lat, _home!.lng, dest.lat, dest.lng);
      }
      if (_work != null) {
        workSecs = await _walkingSeconds(_work!.lat, _work!.lng, dest.lat, dest.lng);
      }

      // If both were computed and both are > threshold => block (false)
      // Otherwise allow.
      final thr = thresholdMin * 60;
      final bothKnown = (homeSecs != null) && (workSecs != null);
      final homeTooFar = (homeSecs != null) && (homeSecs > thr);
      final workTooFar = (workSecs != null) && (workSecs > thr);

      final allowed = bothKnown ? !(homeTooFar && workTooFar)
                                : !(homeTooFar == true && _work == null) && !(workTooFar == true && _home == null);

      _allowedByAddressCache[addr] = allowed;
      return allowed;
    } catch (_) {
      _allowedByAddressCache[addr] = true;
      return true; // fail‑open to avoid hiding results on transient errors
    }
  }

  // ---- Internals ------------------------------------------------------------

  bool _isOnline(String? channel) {
    final c = (channel ?? '').toLowerCase();
    return c == 'online' || c == 'delivery';
  }

  Future<void> _loadAddresses() async {
    final url = Uri.parse('$adminLoginBase$userId');
    final res = await _http.get(url).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return;

    final decoded = json.decode(res.body);
    Map<String, dynamic>? row;
    if (decoded is List && decoded.isNotEmpty && decoded.first is Map) {
      row = Map<String, dynamic>.from(decoded.first as Map);
    } else if (decoded is Map<String, dynamic>) {
      row = decoded;
    }
    if (row == null) return;

    String _s(dynamic v) => v == null ? '' : (v is String ? v : v.toString());
    _homeAdd = _s(row['homeAdd']).trim();
    _workAdd = _s(row['workAdd']).trim();
  }

  Future<({double lat, double lng})?> _geocode(String address) async {
    if (_geocodeCache.containsKey(address)) return _geocodeCache[address];
    final url = Uri.parse(
      'https://maps.googleapis.com/maps/api/geocode/json?address=${Uri.encodeComponent(address)}&key=$mapsApiKey',
    );
    final res = await _http.get(url).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return null;
    final data = json.decode(res.body) as Map<String, dynamic>;
    final status = (data['status'] ?? '').toString();
    if (status != 'OK') return null;
    final results = (data['results'] as List?) ?? const [];
    if (results.isEmpty) return null;
    final loc = results.first['geometry']?['location'];
    if (loc == null) return null;
    final result = (lat: (loc['lat'] as num).toDouble(), lng: (loc['lng'] as num).toDouble());
    _geocodeCache[address] = result;
    return result;
    // Your shell screenshots confirm the shape: status OK, results[0].geometry.location.lat/lng. 
    // (We rely on that structure here.)
  }

  Future<int?> _walkingSeconds(double oLat, double oLng, double dLat, double dLng) async {
    final params = {
      'origin': '$oLat,$oLng',
      'destination': '$dLat,$dLng',
      'mode': 'walking',
      'key': mapsApiKey,
    };
    final url = Uri.parse(
      'https://maps.googleapis.com/maps/api/directions/json?origin=${Uri.encodeComponent(params['origin']!)}'
      '&destination=${Uri.encodeComponent(params['destination']!)}'
      '&mode=walking&key=$mapsApiKey',
    );
    final res = await _http.get(url).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return null;
    final data = json.decode(res.body) as Map<String, dynamic>;
    if ((data['status'] ?? '') != 'OK') return null;
    final routes = (data['routes'] as List?) ?? const [];
    if (routes.isEmpty) return null;
    final legs = (routes.first['legs'] as List?) ?? const [];
    if (legs.isEmpty) return null;
    final dur = legs.first['duration'];
    if (dur == null) return null;
    // Example from your screenshot: {"text":"1 day 18 hours","value":151160}
    return (dur['value'] as num?)?.toInt();
  }
}
