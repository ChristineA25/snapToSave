
// lib/item_service.dart
//
// Minimal, tolerant client for your Node/Express API on Railway.
// Endpoints expected:
//
// GET /items -> { items: [...] } (optional filters: brand, channel, shopID)
// GET /items-textless -> { items: [...] } (from itemColor4.item; items suitable for textless photos)
// GET /item-colors -> { items: [ { item: "...", colors: ["..."] }, ... ] } (from prices.productColor)
// GET /item-colors-textless -> { items: [ { item: "...", colors: ["..."] }, ... ] } (from itemColor4.color)
// NEW: GET /items-screenshot -> { items: [...] } (items harvested from Screenshot table)
//
// Example:
// final svc = ItemService('https://your-app.up.railway.app/', apiKey: 'XYZ');
// final items = await svc.fetchItems(filters: {'brand': 'tesco'});
// final colorMap = await svc.fetchItemColors();
// final textlessColorMap = await svc.fetchItemColorsForTextless();
import 'dart:async'; // <-- Needed for TimeoutException
import 'dart:convert';
import 'package:http/http.dart' as http;

class ItemService {
  ItemService(
    String baseUrl, {
    this.apiKey,
    http.Client? client,
    this.verbose = false,
  })  : _baseUri = Uri.parse(baseUrl.endsWith('/') ? baseUrl : '$baseUrl/'),
        _client = client ?? http.Client();

  /// Canonical base URI with trailing slash ensured.
  final Uri _baseUri;

  /// Optional API key to send as `x-api-key`.
  final String? apiKey;

  /// Shared HTTP client for reuse & testability.
  final http.Client _client;

  /// Optional verbose logging to print unexpected shapes.
  final bool verbose;

  /// Dispose sockets if you constructed the client internally.
  void close() => _client.close();

  /// Common headers for all requests.
  Map<String, String> get _headers {
    final h = <String, String>{
      'Accept': 'application/json',
      'User-Agent': 'ItemService/1.0 (Flutter; Dart)',
    };
    if (apiKey?.isNotEmpty == true) h['x-api-key'] = apiKey!;
    return h;
  }

  /// Builds a URI for /items with optional query parameters (filters).
  Uri _itemsUri({Map<String, String>? query}) {
    final u = _baseUri.resolve('items');
    return Uri(
      scheme: u.scheme,
      host: u.host,
      port: u.hasPort ? u.port : null,
      path: u.path,
      queryParameters: (query == null || query.isEmpty) ? null : query,
    );
  }

  Uri _resolve(String path, {Map<String, String>? query}) {
    final u = _baseUri.resolve(path);
    return Uri(
      scheme: u.scheme,
      host: u.host,
      port: u.hasPort ? u.port : null,
      path: u.path,
      queryParameters: (query == null || query.isEmpty) ? null : query,
    );
  }

  String _snippet(String s, {int max = 400}) =>
      s.length <= max ? s : '${s.substring(0, max)}…';

  // ---------------------------------------------------------------------------
  // Items list (supports filters)
  // ---------------------------------------------------------------------------

  /// Normal items list (supports filters: e.g. {'brand':'tesco','channel':'physical'}).
  Future<List<String>> fetchItems({
    Duration timeout = const Duration(seconds: 20),
    Map<String, String>? filters,
  }) async {
    try {
      final uri = _itemsUri(query: filters);
      final resp = await _client.get(uri, headers: _headers).timeout(timeout);
      if (resp.statusCode != 200) {
        throw HttpException('HTTP ${resp.statusCode}: ${_snippet(resp.body)}');
      }
      final body = jsonDecode(resp.body);
      final raw = (body is Map<String, dynamic>) ? body['items'] : null;
      return _coerceNames(raw);
    } on TimeoutException {
      // Specific catches MUST come before any broader catch.
      throw Exception('Request timed out');
    } on http.ClientException {
      throw Exception('Network unreachable');
    } on HttpException catch (e) {
      throw Exception('Server error: ${e.message}');
    } on FormatException {
      throw Exception('Invalid JSON from server');
    }
  }

  /// Items intended for textless images (itemColor4.item).
  Future<List<String>> fetchItemsForTextless({
    Duration timeout = const Duration(seconds: 20),
  }) async {
    try {
      final uri = _resolve('items-textless');
      final resp = await _client.get(uri, headers: _headers).timeout(timeout);
      if (resp.statusCode != 200) {
        throw HttpException('HTTP ${resp.statusCode}: ${_snippet(resp.body)}');
      }
      final body = jsonDecode(resp.body);
      final raw = (body is Map<String, dynamic>) ? body['items'] : null;
      return _coerceNames(raw);
    } on TimeoutException {
      throw Exception('Request timed out');
    } on http.ClientException {
      throw Exception('Network unreachable');
    } on HttpException catch (e) {
      throw Exception('Server error: ${e.message}');
    } on FormatException {
      throw Exception('Invalid JSON from server');
    }
  }

  /// NEW: Items harvested from your Screenshot table.
  /// Backend should return { items: [...] } or a plain list.
  Future<List<String>> fetchScreenshotItems({
    Duration timeout = const Duration(seconds: 20),
  }) async {
    try {
      // Adjust the path if your backend exposes a different route
      final uri = _resolve('items-screenshot');
      final resp = await _client.get(uri, headers: _headers).timeout(timeout);
      if (resp.statusCode != 200) {
        throw HttpException('HTTP ${resp.statusCode}: ${_snippet(resp.body)}');
      }
      final body = jsonDecode(resp.body);

      // Accept flexible shapes:
      // 1) { items: [...] }
      // 2) [ "string", { name: "..." }, ... ]
      if (body is Map<String, dynamic>) {
        return _coerceNames(body['items']);
      }
      if (body is List) {
        return _coerceNames(body);
      }
      // Unknown shape -> empty list
      return const <String>[];
    } on TimeoutException {
      throw Exception('Request timed out');
    } on http.ClientException {
      throw Exception('Network unreachable');
    } on HttpException catch (e) {
      throw Exception('Server error: ${e.message}');
    } on FormatException {
      throw Exception('Invalid JSON from server');
    }
  }

  // ---------------------------------------------------------------------------
  // Item → colours maps
  // ---------------------------------------------------------------------------

  /// From /item-colors (prices.productColor).
  /// Returns: { 'basmati rice': ['white','grey','purple','black', ...], ... }
  /// Optional filters: brand, channel, shopID.
  Future<Map<String, List<String>>> fetchItemColors({
    Map<String, String>? filters,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    try {
      final uri = _resolve('item-colors', query: filters);
      final resp = await _client.get(uri, headers: _headers).timeout(timeout);
      if (resp.statusCode != 200) {
        throw HttpException('HTTP ${resp.statusCode}: ${_snippet(resp.body)}');
      }
      final body = jsonDecode(resp.body);
      final itemsField = (body is Map<String, dynamic>) ? body['items'] : null;
      return _coerceItemColorMap(itemsField);
    } on TimeoutException {
      throw Exception('Request timed out');
    } on http.ClientException {
      throw Exception('Network unreachable');
    } on HttpException catch (e) {
      throw Exception('Server error: ${e.message}');
    } on FormatException {
      throw Exception('Invalid JSON from server');
    }
  }

  /// From /item-colors-textless (itemColor4.color).
  /// Returns: { 'apple': ['red','green'], 'lemon': ['yellow'], ... }
  Future<Map<String, List<String>>> fetchItemColorsForTextless({
    Duration timeout = const Duration(seconds: 20),
  }) async {
    try {
      final uri = _resolve('item-colors-textless');
      final resp = await _client.get(uri, headers: _headers).timeout(timeout);
      if (resp.statusCode != 200) {
        throw HttpException('HTTP ${resp.statusCode}: ${_snippet(resp.body)}');
      }
      final body = jsonDecode(resp.body);
      final itemsField = (body is Map<String, dynamic>) ? body['items'] : null;
      return _coerceItemColorMap(itemsField);
    } on TimeoutException {
      throw Exception('Request timed out');
    } on http.ClientException {
      throw Exception('Network unreachable');
    } on HttpException catch (e) {
      throw Exception('Server error: ${e.message}');
    } on FormatException {
      throw Exception('Invalid JSON from server');
    }
  }

  // ---------------------------------------------------------------------------
  // Utilities
  // ---------------------------------------------------------------------------

  /// Shared list clean‑up: tolerate strings or maps with name/item/title keys.
  List<String> _coerceNames(dynamic itemsField) {
    if (itemsField is! List) return const <String>[];
    final set = <String>{};
    for (final e in itemsField) {
      String s = '';
      if (e is String) {
        s = e.trim();
      } else if (e is Map) {
        final m = Map<String, dynamic>.from(e);
        s = (m['name'] ?? m['item'] ?? m['title'] ?? '').toString().trim();
        if (s.isEmpty && verbose) {
          // ignore: avoid_print
          print('WARN _coerceNames: no name/item/title in $m');
        }
      } else {
        s = (e?.toString() ?? '').trim();
      }
      if (s.isNotEmpty) set.add(s);
    }
    final list = set.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return list;
  }

  List<String> _splitTokens(String s) {
    return s
        .toLowerCase()
        .split(RegExp(r'[,\\;/\|]')) // commas, semicolons, slashes, pipes
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toList();
  }

  /// Coerces { items: [ { item: "...", colors: ["a","b",...] }, ... ] } into
  /// a Map<String, List<String>> where colour tokens are lowercased & trimmed.
  Map<String, List<String>> _coerceItemColorMap(dynamic itemsField) {
    final Map<String, List<String>> out = {};
    if (itemsField is! List) return out;
    for (final e in itemsField) {
      if (e is! Map) continue;
      final m = Map<String, dynamic>.from(e);
      final item = (m['item'] ?? '').toString().trim();
      if (item.isEmpty) continue;
      final colorsAny = m['colors'];
      List<String> colors;
      if (colorsAny is List) {
        colors = colorsAny
            .map((c) => c.toString().trim().toLowerCase())
            .where((c) => c.isNotEmpty)
            .toList();
      } else if (colorsAny is String) {
        colors = _splitTokens(colorsAny);
      } else {
        colors = const <String>[];
      }
      if (colors.isNotEmpty) {
        out[item] = colors;
      }
    }
    return out;
  }
}

/// Lightweight HttpException so we don't depend on dart:io.
class HttpException implements Exception {
  HttpException(this.message);
  final String message;
  @override
  String toString() => 'HttpException: $message';
}
