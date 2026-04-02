
import 'dart:convert';
import 'package:http/http.dart' as http;

class ItemInputService {
  final String baseUrl;
  ItemInputService(this.baseUrl);

  /// Create a new itemInput row
  /// Returns the inserted row id (or 0 if the backend didn't return it)
  Future<int> create(Map<String, dynamic> row) async {
    final uri = Uri.parse('${baseUrl}api/item-input');
    final resp = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(row),
    );

    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      final map = jsonDecode(resp.body) as Map<String, dynamic>;
      return (map['id'] as num?)?.toInt() ?? 0;
    }

    throw Exception('item-input insert failed: ${resp.statusCode} ${resp.body}');
  }

  /// Fetch ALL rows from /api/item-input by sending the special header.
  /// Returns the JSON array at response.rows (List<dynamic>).
  ///
  /// NOTE:
  /// - This will return *all* rows in a single response if your backend
  ///   recognizes the header `x-all: 1` and removes LIMIT/OFFSET.
  /// - Consider memory implications if your table is very large.
  Future<List<dynamic>> fetchAll() async {
    final uri = Uri.parse('${baseUrl}api/item-input');
    final resp = await http.get(
      uri,
      headers: {
        'x-all': '1',                // <-- triggers "no limit" mode on your server
        'Accept': 'application/json' // optional but explicit
      },
    );

    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      final map = jsonDecode(resp.body) as Map<String, dynamic>;
      // Expected shape: { count: <int>, rows: [...] }
      final rows = map['rows'];
      if (rows is List) return rows;
      throw Exception('Unexpected response shape: "rows" is not a List');
    }

    throw Exception('item-input fetchAll failed: ${resp.statusCode} ${resp.body}');
  }

  /// Optional: classic pagination helper if you ever need it.
  /// Example: await fetchPaged(limit: 1000, offset: 0);
  Future<List<dynamic>> fetchPaged({int limit = 200, int offset = 0, Map<String, String>? filters}) async {
    final query = <String, String>{
      'limit': '$limit',
      'offset': '$offset',
      ...?filters, // e.g. {'userID':'u1', 'from':'2025-01-01', 'to':'2025-12-31'}
    };

    final uri = Uri.parse('${baseUrl}api/item-input').replace(queryParameters: query);
    final resp = await http.get(uri, headers: {'Accept': 'application/json'});

    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      final map = jsonDecode(resp.body) as Map<String, dynamic>;
      final rows = map['rows'];
      if (rows is List) return rows;
      throw Exception('Unexpected response shape: "rows" is not a List');
    }

    throw Exception('item-input fetchPaged failed: ${resp.statusCode} ${resp.body}');
  }
}
