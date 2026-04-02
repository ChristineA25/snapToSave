
import 'dart:convert';
import 'package:http/http.dart' as http;

class ItemResolverService {
  final String baseUrl; // your screen defines _baseUrl with trailing slash [1](https://uweacuk-my.sharepoint.com/personal/ka4_au_live_uwe_ac_uk/Documents/Microsoft%20Copilot%20Chat%20Files/photo_taking.dart)
  ItemResolverService(this.baseUrl);

  Uri get _brandItemResolve => Uri.parse('${baseUrl}api/items/resolve');
  Uri get _itemOnlyResolve  => Uri.parse('${baseUrl}api/items/resolve-by-item');

  Future<Map<String, dynamic>> resolveBrandItem({
    required String brand,
    required String item,
    double? qtyValue,
    String? qtyUnit,
  }) async {
    final body = <String, dynamic>{'brand': brand, 'item': item};
    if (qtyValue != null && (qtyUnit?.trim().isNotEmpty ?? false)) {
      body['quantity'] = {'value': qtyValue, 'unit': qtyUnit!.toLowerCase()};
    }
    final resp = await http.post(
      _brandItemResolve,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      return {
        'exactId': (json['exactId'] as String?) ?? '',
        'candidates': ((json['candidates'] ?? []) as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList(),
      };
    }
    throw Exception('Resolver HTTP ${resp.statusCode}: ${resp.body}');
  }

  Future<Map<String, dynamic>> resolveItemOnly({
    required String item,
    double? qtyValue,
    String? qtyUnit,
  }) async {
    final body = <String, dynamic>{'item': item};
    if (qtyValue != null && (qtyUnit?.trim().isNotEmpty ?? false)) {
      body['quantity'] = {'value': qtyValue, 'unit': qtyUnit!.toLowerCase()};
    }
    final resp = await http.post(
      _itemOnlyResolve,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      return {
        'exactId': (json['exactId'] as String?) ?? '',
        'candidates': ((json['candidates'] ?? []) as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList(),
      };
    }
    throw Exception('Resolver HTTP ${resp.statusCode}: ${resp.body}');
  }
}
