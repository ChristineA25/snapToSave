
import 'dart:convert';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'place.dart';

class PlacesService {
  final String apiKey;
  final http.Client _client;

  PlacesService(this.apiKey, {http.Client? client}) : _client = client ?? http.Client();

  /// Searches text with optional Bristol bias; returns places with postcode parsed from formattedAddress.
  Future<List<Place>> searchText({
    required String query,
    LatLng? biasCenter,
    double radiusMeters = 5000,
    String languageCode = 'en',
  }) async {
    final uri = Uri.parse('https://places.googleapis.com/v1/places:searchText');

    // Request body (mirrors your curl)
    final body = <String, dynamic>{
      'textQuery': query,
      'languageCode': languageCode,
      if (biasCenter != null)
        'locationBias': {
          'circle': {
            'center': {
              'latitude': biasCenter.latitude,
              'longitude': biasCenter.longitude,
            },
            'radius': radiusMeters,
          }
        },
    };

    final headers = {
      'Content-Type': 'application/json',
      'X-Goog-Api-Key': apiKey,
      // Ask only for the fields we need to reduce cost/latency.
      'X-Goog-FieldMask':
          'places.id,places.displayName,places.formattedAddress,places.location',
    };

    final resp = await _client.post(uri, headers: headers, body: jsonEncode(body));
    if (resp.statusCode != 200) {
      throw Exception('Places API error ${resp.statusCode}: ${resp.body}');
    }

    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    final list = (json['places'] as List?) ?? const [];

    return list.map<Place>((p) {
      final id = (p['id'] as String?) ?? '';
      final displayName = (p['displayName']?['text'] as String?) ?? 'Unknown';
      final addr = (p['formattedAddress'] as String?) ?? '';
      final loc = p['location'] as Map<String, dynamic>? ?? {};
      final lat = (loc['latitude'] as num?)?.toDouble() ?? 0;
      final lng = (loc['longitude'] as num?)?.toDouble() ?? 0;
      final postcode = _extractUKPostcode(addr);
      return Place(
        id: id.isEmpty ? '$lat,$lng' : id,
        name: displayName,
        formattedAddress: addr,
        lat: lat,
        lng: lng,
        postcode: postcode,
      );
    }).toList();
  }

  /// UK postcode extractor (handles typical patterns: BS1 3DX, EC1A 1BB, W1A 0AX, etc.)
  String? _extractUKPostcode(String input) {
    final re = RegExp(
      r'([A-Z]{1,2}\d{1,2}[A-Z]?\s?\d[A-Z]{2})',
      caseSensitive: false,
    );
    final m = re.firstMatch(input);
    if (m != null) return m.group(1)?.toUpperCase().replaceAll(RegExp(r'\s+'), ' ');
    return null;
    }
}
