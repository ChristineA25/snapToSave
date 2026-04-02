
// shop_service.dart
import 'dart:convert';
import 'package:http/http.dart' as http;

class ShopService {
  final String baseUrl;
  ShopService(this.baseUrl);

  Future<List<String>> fetchShops() async {
    final uri = Uri.parse('${baseUrl}shops');
    final resp = await http.get(uri);
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      final list = (json['shops'] as List?)?.cast<String>() ?? const <String>[];
      return list.where((s) => s.trim().isNotEmpty).toList();
    }
    throw Exception('Shops HTTP ${resp.statusCode}: ${resp.body}');
  }

  // ✅ Added: used by photo_taking.dart during submit to persist new shops.
  Future<Map<String, dynamic>> addShop(String name) async {
    final uri = Uri.parse('${baseUrl}shops/add');
    final resp = await http.post(
      uri,
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'name': name.trim()}),
    );
    if (resp.statusCode == 200 || resp.statusCode == 201) {
      return jsonDecode(resp.body) as Map<String, dynamic>;
    }
    throw Exception('POST /shops/add failed (${resp.statusCode}): ${resp.body}');
  }
}
