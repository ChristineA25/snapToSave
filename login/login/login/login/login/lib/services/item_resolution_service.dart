
import 'dart:convert';
import 'package:http/http.dart' as http;

class ItemResolutionResult {
  final String? exactId;
  final List<String> suggestedFeatures;
  final List<Map<String, dynamic>> candidates;

  ItemResolutionResult({
    required this.exactId,
    required this.suggestedFeatures,
    required this.candidates,
  });

  factory ItemResolutionResult.fromJson(Map<String, dynamic> json) {
    return ItemResolutionResult(
      exactId: json['exactId'] as String?,
      suggestedFeatures: ((json['suggestedFeatures'] ?? []) as List)
          .map((e) => e.toString())
          .toList(),
      candidates: ((json['candidates'] ?? []) as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(),
    );
  }
}

class ItemResolutionService {
  /// e.g. 'https://nodejs-production-53a4.up.railway.app/'
  final String baseUrl;

  const ItemResolutionService(this.baseUrl);

  /// Resolve against backend items resolver.
  ///
  /// - `qtyValue` + `qtyUnit` are optional unless `strictQty == true`.
  /// - When `strictQty` is true, the server requires a matching quantity (with
  ///   unit normalization: L⇄ml, kg⇄g, pcs/pack plurals).
  Future<ItemResolutionResult> resolve({
    required String brand,
    required String item,
    double? qtyValue,
    String? qtyUnit, // 'pcs','kg','g','L','ml','pack'
    List<String>? selectedFeatures,
    bool strictQty = false, // NEW: enforce quantity on submit
  }) async {
    final uri = Uri.parse('${baseUrl}api/items/resolve');

    final body = <String, dynamic>{
      'brand': brand,
      'item': item,
      'strictQty': strictQty, // NEW
    };

    if (qtyValue != null && qtyUnit != null && qtyUnit.trim().isNotEmpty) {
      body['quantity'] = {'value': qtyValue, 'unit': qtyUnit.toLowerCase()};
    }

    if (selectedFeatures != null && selectedFeatures.isNotEmpty) {
      body['selectedFeatures'] = selectedFeatures;
    }

    final r = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );

    if (r.statusCode >= 200 && r.statusCode < 300) {
      return ItemResolutionResult.fromJson(
        jsonDecode(r.body) as Map<String, dynamic>,
      );
    }
    throw Exception('Resolver HTTP ${r.statusCode}: ${r.body}');
  }
}
