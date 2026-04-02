
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

class BrandService {
  BrandService(this.baseUrl, {this.apiKey});
  final String baseUrl;            // e.g., https://your-app.up.railway.app/
  final String? apiKey;

  Future<List<String>> fetchBrands({Duration timeout = const Duration(seconds: 8)}) async {
    final uri = Uri.parse(baseUrl).resolve('brands');
    final headers = <String, String>{'Accept': 'application/json'};
    if (apiKey != null && apiKey!.isNotEmpty) {
      headers['x-api-key'] = apiKey!;
    }
    try {
      final resp = await http.get(uri, headers: headers).timeout(timeout);
      if (resp.statusCode != 200) {
        throw HttpException('HTTP ${resp.statusCode}: ${resp.body}');
      }
      final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
      final list = (decoded['brands'] as List?) ?? const [];
      return list
          .map((e) => (e ?? '').toString())
          .where((s) => s.trim().isNotEmpty)
          .toList();
    } on SocketException {
      throw Exception('Network unreachable');
    } on HttpException catch (e) {
      throw Exception('Server error: ${e.message}');
    }
  }
}
