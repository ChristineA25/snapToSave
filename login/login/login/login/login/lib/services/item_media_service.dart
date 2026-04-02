
// services/item_media_service.dart
import 'dart:convert';
import 'package:http/http.dart' as http;

/// Caches lookups in memory so repeated tiles don't re-fetch the same URL.
class ItemMediaService {
  final String baseUrl;

  /// Cache: itemId -> image URL (or null if not found)
  final Map<String, String?> _picCacheByItemId = {};

  /// Cache: name\nbrand (lowercased key) -> image URL (or null), used only when no itemId is given
  final Map<String, String?> _picCacheByText = {};

  ItemMediaService(this.baseUrl);

  /// Resolve picture by itemId only.
  /// Returns a direct image URL (or null if not found).
  Future<String?> picForItemId(String itemId) async {
    if (itemId.isEmpty) return null;
    if (_picCacheByItemId.containsKey(itemId)) return _picCacheByItemId[itemId];

    // Single call; we'll filter by exact id client-side.
    final uri = Uri.parse('${_ensureSlash(baseUrl)}api/items/all');
    try {
      final resp = await http.get(uri);
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        final map = _safeDecode(resp.body);
        final List items = (map['items'] ?? map['rows'] ?? []) as List;
        for (final raw in items) {
          final it = Map<String, dynamic>.from(raw as Map);
          // Accept either 'id' or 'itemID' from the items endpoint
          final idInRow = (it['id'] ?? it['itemID'] ?? '').toString();
          if (idInRow == itemId) {
            final url = _firstPic(it);
            _picCacheByItemId[itemId] = (url?.isNotEmpty ?? false) ? url : null;
            return _picCacheByItemId[itemId];
          }
        }
      }
    } catch (_) {
      // absorb and return null
    }
    _picCacheByItemId[itemId] = null;
    return null;
  }

  /// General resolver:
  /// - If itemId is provided AND `idOnlyWhenIdPresent == true` (default),
  ///   it will NEVER fall back to name/brand.
  /// - If itemId is empty, optionally try name+brand, then name.
  Future<String?> picFor({
    String? itemId,
    String? name,
    String? brand,
    bool idOnlyWhenIdPresent = true, // <-- strict by default
  }) async {
    final id = (itemId ?? '').trim();

    if (id.isNotEmpty) {
      // Always try by ID first
      final byId = await picForItemId(id);

      // If we’re strict, never fall back to text search
      if (idOnlyWhenIdPresent) {
        return (byId != null && byId.isNotEmpty) ? byId : null;
      }

      // Optional: if not strict AND ID failed, we may choose to fall back
      if (byId != null && byId.isNotEmpty) return byId;
      // else: continue to text fallback below...
    }

    // ---- text fallback (only when there is no id, or strict==false) ----
    final keyName = (name ?? '').trim().toLowerCase();
    final keyBrand = (brand ?? '').trim().toLowerCase();
    final compositeKey = '$keyName\n$keyBrand';
    if (keyName.isNotEmpty && _picCacheByText.containsKey(compositeKey)) {
      return _picCacheByText[compositeKey];
    }

    final uri = Uri.parse('${_ensureSlash(baseUrl)}api/items/all');
    String? url;
    // Prefer name + brand match
    if (keyName.isNotEmpty && keyBrand.isNotEmpty) {
      url = await _searchAndPick(uri, name: keyName, brand: keyBrand);
    }
    // Fallback to name only
    url ??= await _searchAndPick(uri, name: keyName);

    _picCacheByText[compositeKey] = (url != null && url.isNotEmpty) ? url : null;
    return _picCacheByText[compositeKey];
  }

  // --------
  // Helpers
  // --------

  String _ensureSlash(String s) => s.isEmpty ? s : (s.endsWith('/') ? s : '$s/');

  Map<String, dynamic> _safeDecode(String body) {
    final dynamic data = jsonDecode(body);
    if (data is Map<String, dynamic>) return data;
    if (data is List) return <String, dynamic>{'items': data};
    return <String, dynamic>{};
  }

  /// Picks a picture URL from an item map using common keys (plus historical typos).
  String? _firstPic(Map<String, dynamic> it) {
    final candidates = <String?>[
      it['picWebsite']?.toString(), // primary

      // historical typos seen before:
      it['picbiesite']?.toString(),
      it['picibesite']?.toString(),
      it['picbesite']?.toString(),

      // generic fallbacks:
      it['picture']?.toString(),
      it['pic']?.toString(),
      it['image']?.toString(),
      it['imageUrl']?.toString(),
      it['img']?.toString(),
    ];
    for (final c in candidates) {
      if (c == null) continue;
      final t = c.trim();
      if (t.isEmpty) continue;
      if (t.startsWith('http://') || t.startsWith('https://')) return t;
    }
    return null;
  }

  /// Fetches all items and chooses a suitable image by string matching.
  Future<String?> _searchAndPick(
    Uri uri, {
    required String? name,
    String? brand,
  }) async {
    try {
      final resp = await http.get(uri);
      if (resp.statusCode < 200 || resp.statusCode >= 300) return null;

      final map = _safeDecode(resp.body);
      final List items = (map['items'] ?? map['rows'] ?? []) as List;
      if (items.isEmpty) return null;

      final lname = (name ?? '').toLowerCase();
      final lbrand = (brand ?? '').toLowerCase();

      // Prefer items matching both name & brand
      if (lname.isNotEmpty && lbrand.isNotEmpty) {
        for (final raw in items) {
          final it = Map<String, dynamic>.from(raw as Map);
          final n = (it['name'] ?? it['itemName'] ?? '').toString().toLowerCase();
          final b = (it['brand'] ?? '').toString().toLowerCase();
          if (n.contains(lname) && b.contains(lbrand)) {
            final url = _firstPic(it);
            if (url != null && url.isNotEmpty) return url;
          }
        }
      }

      // Then match by name only
      if (lname.isNotEmpty) {
        for (final raw in items) {
          final it = Map<String, dynamic>.from(raw as Map);
          final n = (it['name'] ?? it['itemName'] ?? '').toString().toLowerCase();
          if (n.contains(lname)) {
            final url = _firstPic(it);
            if (url != null && url.isNotEmpty) return url;
          }
        }
      }

      // Finally, give up (we don't choose "any valid" image to avoid mismatches)
      return null;
    } catch (_) {
      return null;
    }
  }
}
