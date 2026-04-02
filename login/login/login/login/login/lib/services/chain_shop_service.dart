
// lib/services/chain_shop_service.dart
import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../utils/shop_normalizer.dart' as sn; // uses chainRoot()  [1](https://uweacuk-my.sharepoint.com/personal/ka4_au_live_uwe_ac_uk/Documents/Microsoft%20Copilot%20Chat%20Files/form_validators.dart)

/// Loads { shops: [ { shopName: "...", shopID: "..." }, ... ] }
/// from `${baseUrl}api/chain-shop` once, then resolves names → shopID.
class ChainShopService {
  final String baseUrl;
  final http.Client _client;
  final Duration timeout;
  Map<String, String>? _nameToId; // cache: normalized-root(lower) → shopID

  ChainShopService(
    this.baseUrl, {
    http.Client? client,
    this.timeout = const Duration(seconds: 20),
  }) : _client = client ?? http.Client();

  Future<void> _ensureLoaded() async {
    if (_nameToId != null) return;
    final uri = Uri.parse('${baseUrl}api/chain-shop'); // same _baseUrl you already use  [1](https://uweacuk-my.sharepoint.com/personal/ka4_au_live_uwe_ac_uk/Documents/Microsoft%20Copilot%20Chat%20Files/form_validators.dart)
    final resp = await _client.get(uri).timeout(timeout);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('HTTP ${resp.statusCode}: ${resp.body}');
    }
    final decoded = jsonDecode(resp.body);
    final List shops = (decoded is Map<String, dynamic>) ? (decoded['shops'] as List? ?? const []) : const [];
    final map = <String, String>{};
    for (final e in shops) {
      if (e is! Map) continue;
      final name = (e['shopName'] ?? '').toString().trim();
      final id   = (e['shopID'] ?? '').toString().trim();
      if (name.isEmpty || id.isEmpty) continue;
      // Normalize the name the same way your UI does, then lower-case as key
      final root = sn.chainRoot(name);
      if (root.isNotEmpty) map[root.toLowerCase()] = id;
    }
    _nameToId = map;
  }

  /// Resolve a user-entered or dropdown source name to a canonical shopID.
  /// Fallback: return null if not found (caller can use the root as a last resort).
  Future<String?> resolveIdForName(String inputName) async {
    await _ensureLoaded();
    final root = sn.chainRoot(inputName).toLowerCase();
    if (root.isEmpty) return null;
    final direct = _nameToId![root];
    if (direct != null && direct.trim().isNotEmpty) return direct;
    // Optional: try first token as a light fallback (e.g., "tesco extra" → "tesco")
    final first = root.split(RegExp(r'\s+')).first;
    return _nameToId![first];
  }

  void close() => _client.close();
}
