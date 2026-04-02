
// lib/services/google_places_service.dart
import 'dart:convert';
import 'package:http/http.dart' as http;

/// Minimal Google Places Text Search wrapper that only fetches displayName.
/// API key is optional; if empty, calls will no-op and return [].
class GooglePlacesService {
  final String apiKey;

  const GooglePlacesService({required this.apiKey});

  Future<List<String>> textSearchDisplayNames(String query) async {
    if (apiKey.trim().isEmpty) return const <String>[];
    try {
      final url = Uri.parse('https://places.googleapis.com/v1/places:searchText');
      final resp = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'X-Goog-Api-Key': apiKey,
          'X-Goog-FieldMask': 'places.displayName',
        },
        body: jsonEncode({'textQuery': query}),
      );
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        final map = jsonDecode(resp.body) as Map<String, dynamic>;
        final List places = (map['places'] ?? []) as List;
        return places
            .map((p) => (((p as Map)['displayName'] ?? {}) as Map)['text'] ?? '')
            .map((s) => s.toString())
            .where((s) => s.isNotEmpty)
            .toList();
      }
    } catch (_) {
      // swallow; higher-level code will fallback safely
    }
    return const <String>[];
  }
}
