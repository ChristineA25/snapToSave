
import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

/// Simple API client for your 53a4 service shops endpoints.
class ShopsApi {
  /// Base URL of your deployed service (no trailing slash).
  final String baseUrl;

  /// Optional API key header value, if you set API_KEY in Railway.
  final String? apiKey;

  /// Default HTTP timeout.
  final Duration timeout;

  ShopsApi({
    this.baseUrl = 'https://nodejs-production-53a4.up.railway.app',
    this.apiKey,
    this.timeout = const Duration(seconds: 12),
  });

  Map<String, String> _headers({Map<String, String>? extra}) {
    final h = <String, String>{
      'Accept': 'application/json',
      'Content-Type': 'application/json',
    };
    if (apiKey != null && apiKey!.trim().isNotEmpty) {
      h['x-api-key'] = apiKey!;
    }
    if (extra != null) h.addAll(extra);
    return h;
  }

  /// GET /shops  ->  { "shops": ["Lidl","Savers","Tesco", ...] }
  /// Returns a sorted list of unique shop names.
  Future<List<String>> fetchShops() async {
    final uri = Uri.parse('$baseUrl/shops');

    final resp = await http
        .get(uri, headers: _headers())
        .timeout(timeout, onTimeout: () {
      throw TimeoutException('GET /shops timed out after ${timeout.inSeconds}s');
    });

    if (resp.statusCode != 200) {
      throw HttpExceptionWithBody(
        'GET /shops failed (${resp.statusCode})',
        statusCode: resp.statusCode,
        body: resp.body,
      );
    }

    final decoded = jsonDecode(resp.body);
    if (decoded is! Map<String, dynamic> || decoded['shops'] == null) {
      throw const FormatException('Unexpected payload shape from /shops');
    }

    final shops = (decoded['shops'] as List)
        .map((e) => (e ?? '').toString().trim())
        .where((s) => s.isNotEmpty)
        .toSet() // dedupe
        .toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    return shops;
  }

  /// POST /shops/add  body: { "name": "<Shop Name>" }
  /// Returns the inserted/acknowledged shop (as the API echoes it back).
  Future<ShopResult> addShop(String name) async {
    final clean = name.trim();
    if (clean.isEmpty) {
      throw ArgumentError('Shop name must not be empty.');
    }

    final uri = Uri.parse('$baseUrl/shops/add');
    final resp = await http
        .post(uri, headers: _headers(), body: jsonEncode({'name': clean}))
        .timeout(timeout, onTimeout: () {
      throw TimeoutException('POST /shops/add timed out after ${timeout.inSeconds}s');
    });

    // API returns 201 on success, 200/409/400/500 in other scenarios.
    if (resp.statusCode != 201 && resp.statusCode != 200) {
      throw HttpExceptionWithBody(
        'POST /shops/add failed (${resp.statusCode})',
        statusCode: resp.statusCode,
        body: resp.body,
      );
    }

    final decoded = jsonDecode(resp.body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Unexpected payload shape from /shops/add');
    }

    final shopName = (decoded['shopName'] ?? '').toString().trim();
    final shopId = (decoded['shopId'] ?? '').toString().trim();

    if (shopName.isEmpty) {
      throw const FormatException('Missing "shopName" in /shops/add response');
    }

    return ShopResult(shopName: shopName, shopId: shopId);
  }
}

/// Simple model for the /shops/add response.
class ShopResult {
  final String shopName;
  final String shopId; // may be empty if server returned empty

  ShopResult({required this.shopName, required this.shopId});

  @override
  String toString() => 'ShopResult(shopName: $shopName, shopId: $shopId)';
}

/// Richer HTTP exception that includes body for debugging.
class HttpExceptionWithBody implements Exception {
  final String message;
  final int statusCode;
  final String body;

  HttpExceptionWithBody(this.message,
      {required this.statusCode, required this.body});

  @override
  String toString() => 'HttpExceptionWithBody($statusCode): $message\n$body';
}
