
// lib/utils/shop_normalizer.dart
library shop_normalizer;

/// Known small-format suffixes to drop when forming a chain root.
const Set<String> _suffixes = {
  'express', 'local', 'extra', 'metro', 'superstore'
};

String _normalizeSpaces(String s) =>
    s.replaceAll(RegExp(r'\s+'), ' ').trim();

/// Remove a single trailing small-format suffix (Express, Local, Extra, ...).
String stripCommonSuffixes(String raw) {
  final toks = raw.trim().split(RegExp(r'\s+'));
  if (toks.length >= 2 && _suffixes.contains(toks.last.toLowerCase())) {
    toks.removeLast();
  }
  return _normalizeSpaces(toks.join(' '));
}

/// Return the canonical chain root for a shop/source name.
/// Strategy:
/// 1) Lower noise: strip a trailing small-format suffix.
/// 2) Trim/normalize spaces.
String chainRoot(String name) {
  if (name.trim().isEmpty) return name.trim();
  final stripped = stripCommonSuffixes(name);
  final cleaned = _normalizeSpaces(stripped);
  return cleaned.isEmpty ? name.trim() : cleaned;
}

/// Collapse a whole list of online sources into unique chain roots
/// by common “first word” grouping. For each group (e.g., "tesco ..."),
/// pick the shortest normalized variant as the representative, which
/// naturally becomes just "tesco" when "tesco express"/"tesco extra" exist.
List<String> collapseToChainRoots(List<String> options) {
  // Pre-normalize -> chain roots
  final normalized = <String>[];
  for (final s in options) {
    final r = chainRoot(s);
    if (r.isNotEmpty) normalized.add(r);
  }
  // Group by first token (common word)
  final Map<String, List<String>> byFirst = {};
  for (final r in normalized) {
    final toks = r.toLowerCase().split(RegExp(r'\s+'));
    final first = toks.isNotEmpty ? toks.first : r.toLowerCase();
    byFirst.putIfAbsent(first, () => []).add(r);
  }
  // Choose shortest string per group (stable: deterministic)
  final result = <String>[];
  for (final entry in byFirst.entries) {
    entry.value.sort((a, b) {
      final ca = a.length.compareTo(b.length);
      return ca != 0 ? ca : a.toLowerCase().compareTo(b.toLowerCase());
    });
    result.add(entry.value.first);
  }
  // Preserve roughly original appearance order by sorting case-insensitively
  result.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return result;
}
