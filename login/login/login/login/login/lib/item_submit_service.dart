
import 'dart:convert';
import 'package:http/http.dart' as http;

class ItemCreatePayload {
  final String name;
  final String? brand;
  final String quantity;       // "2kg", "545ml", "6pcs"
  final String? feature;
  final String? productColor;  // "white, blue"
  final String? picWebsite;    // optional

  ItemCreatePayload({
    required this.name,
    required this.quantity,
    this.brand,
    this.feature,
    this.productColor,
    this.picWebsite,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'brand': brand,
        'quantity': quantity,
        'feature': feature,
        'productColor': productColor,
        'picWebsite': picWebsite,
      };
}

class ItemSubmitService {
  final String baseUrl; // should end with trailing slash (your _baseUrl does) [1](https://uweacuk-my.sharepoint.com/personal/ka4_au_live_uwe_ac_uk/Documents/Microsoft%20Copilot%20Chat%20Files/photo_taking.dart)
  ItemSubmitService(this.baseUrl);

  Uri get _create => Uri.parse('${baseUrl}api/items/create');
  Uri get _createBatch => Uri.parse('${baseUrl}api/items/create-batch');

  Future<String> createItem(ItemCreatePayload p) async {
    final resp = await http.post(
      _create,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(p.toJson()),
    );
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      return (json['id'] ?? '').toString();
    }
    throw Exception('Create failed: ${resp.statusCode} ${resp.body}');
  }

  Future<List<String>> createItems(List<ItemCreatePayload> list) async {
    if (list.isEmpty) return <String>[];
    final resp = await http.post(
      _createBatch,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'items': list.map((e) => e.toJson()).toList()}),
    );
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      final ids = (json['ids'] as List?)?.map((e) => '$e').toList() ?? <String>[];
      return ids;
    }
    throw Exception('Create-batch failed: ${resp.statusCode} ${resp.body}');
  }
}
