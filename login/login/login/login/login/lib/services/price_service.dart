
// lib/services/price_service.dart
import 'dart:convert';
import 'package:http/http.dart' as http;

class PriceRow {
  final int? id; // optional id for forced insert
  final String itemID;
  final String shopID;
  final String channel; // "online"/"physical"
  final String date; // YYYY-MM-DD
  final double? normalPrice;
  final double? discountPrice;
  final String? discountCond;
  final String? shopAdd;

  PriceRow({
    this.id,
    required this.itemID,
    required this.shopID,
    required this.channel,
    required this.date,
    this.normalPrice,
    this.discountPrice,
    this.discountCond,
    this.shopAdd,
  });

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'itemID': itemID,
        'shopID': shopID,
        'channel': channel,
        'date': date,
        'normalPrice': normalPrice,
        'discountPrice': discountPrice,
        'discountCond': discountCond,
        'shopAdd': shopAdd,
      };
}

class PriceService {
  final String baseUrl;
  PriceService(this.baseUrl);

  Uri get _createBatch => Uri.parse('${baseUrl}api/prices/create-batch');
  Uri get _listPrices => Uri.parse('${baseUrl}api/prices');

  // ------------------------------------------------------------
  // findPrice() — unchanged
  // ------------------------------------------------------------
  Future<Map<String, dynamic>?> findPrice({
    required String itemID,
    required String shopID,
    required String channel,
    required String date, // YYYY-MM-DD
  }) async {
    final url = Uri.parse(
      '${baseUrl}api/prices'
      '?itemID=${Uri.encodeQueryComponent(itemID)}'
      '&shopID=${Uri.encodeQueryComponent(shopID)}'
      '&channel=${Uri.encodeQueryComponent(channel)}'
      '&from=${Uri.encodeQueryComponent(date)}'
      '&to=${Uri.encodeQueryComponent(date)}',
    );

    final r = await http.get(url);
    if (r.statusCode < 200 || r.statusCode >= 300) return null;

    final map = jsonDecode(r.body) as Map<String, dynamic>;
    final rows = (map['rows'] as List?) ?? const [];
    if (rows.isEmpty) return null;

    return Map<String, dynamic>.from(rows.first as Map);
  }

  // ------------------------------------------------------------
  // UPDATED updatePrice() — the ONLY REQUIRED CHANGE
  // ------------------------------------------------------------
  Future<void> updatePrice({
    required int id,
    double? normalPrice,
    double? discountPrice,
    String? discountCond,
  }) async {
    // build payload with only the fields you want to update
    final payload = <String, dynamic>{};

    if (normalPrice != null) payload['normalPrice'] = normalPrice;
    if (discountPrice != null) payload['discountPrice'] = discountPrice;
    if (discountCond != null) payload['discountCond'] = discountCond;

    final resp = await http.put(
      Uri.parse('${baseUrl}api/prices/$id'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode(payload),
    );

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception(
          'Failed to update price: ${resp.statusCode} ${resp.body}');
    }
  }

  // ------------------------------------------------------------
  // createBatch() — unchanged
  // ------------------------------------------------------------
  Future<int> createBatch(List<PriceRow> rows) async {
    if (rows.isEmpty) return 0;

    final payload = {
      'rows': rows.map((e) => e.toJson()).toList(),
    };

    final resp = await http.post(
      _createBatch,
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode(payload),
    );

    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      final map = jsonDecode(resp.body) as Map<String, dynamic>;
      return (map['count'] as num?)?.toInt() ?? rows.length;
    }

    throw Exception(
      'POST /api/prices/create-batch failed (${resp.statusCode}): ${resp.body}',
    );
  }
}
