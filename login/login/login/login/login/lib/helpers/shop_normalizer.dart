
// lib/helpers/shop_normalizer.dart
import '../services/google_places_service.dart';

/// Fallback: remove common small-format suffixes (Express, Local, etc.)
String stripCommonRetailSuffixes(String raw) {
  final suffixes = <String>{'express', 'local', 'extra', 'metro', 'superstore'};
  final toks = raw.trim().split(RegExp(r'\s+'));
  if (toks.length >= 2 && suffixes.contains(toks.last.toLowerCase())) {
    toks.removeLast();
  }
  return toks.join(' ').trim();
}

/// Very light “prefix agreement” score between a probe and the top result.
double _prefixMatchScore(String probe, String topName) {
  final q = probe.toLowerCase().trim();
  final t = topName.toLowerCase().trim();
  if (q.isEmpty || t.isEmpty) return 0.0;
  if (t.startsWith(q)) return q.length / t.length; // probe shorter
  if (q.startsWith(t)) return t.length / q.length; // top shorter
  return 0.0;
}

/// Derive the likely brand root for a shop name.
/// - If Places API is available, progressively trims the last word and stops
///   when prefix-based relevance would drop; keeps the previous best.
/// - Always tries a suffix-strip first, so it works well even offline.
class ShopNormalizer {
  final GooglePlacesService places;

  ShopNormalizer({required this.places});

  Future<String> deduceOriginal(String raw) async {
    if (raw.trim().isEmpty) return raw.trim();

    // Step 1: cheap local improvement (works even with no API key)
    String current = stripCommonRetailSuffixes(raw);
    String best = current;

    // Step 2: if no API, stop here
    final hasApi = places.apiKey.trim().isNotEmpty;
    if (!hasApi) return best;

    // Step 3: query once, then iterate while score does not drop
    List<String> topNow = await places.textSearchDisplayNames(current);
    double prevScore =
        topNow.isNotEmpty ? _prefixMatchScore(current, topNow.first) : 0.0;

    final toks = current.split(RegExp(r'\s+'));
    while (toks.length > 1) {
      toks.removeLast();
      final probe = toks.join(' ');
      final names = await places.textSearchDisplayNames(probe);
      final score = names.isNotEmpty ? _prefixMatchScore(probe, names.first) : 0.0;

      // if adding this trim reduces agreement noticeably, stop
      if (score + 0.15 < prevScore) break;

      best = probe;
      prevScore = score;
    }

    return best.trim().isEmpty ? raw.trim() : best.trim();
  }
}
