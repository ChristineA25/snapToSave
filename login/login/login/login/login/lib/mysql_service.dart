
import 'package:mysql1/mysql1.dart';

class MySqlService {
  // For production, do NOT hardcode secrets in mobile apps.
  // Use a secure backend API and call it over HTTPS.
  static final settings = ConnectionSettings(
    host: 'interchange.proxy.rlwy.net', // e.g. internal/private host (NOT reachable from devices)
    port: 15829,
    user: 'root',
    password: 'lpQANJYLNWVirTntkjuuKeCpxSdRtcVU',
    db: 'railway',
    // Note: mysql1 on Flutter typically doesn't support custom CA certs.
    // If the server enforces SSL with CA pinning, this may fail.
  );

  /// Fetches one column from a table and returns it as List<String>.
  static Future<List<String>> fetchColumn({
    required String table,
    required String column,
    String? whereClause,   // e.g., "WHERE category = 'groceries'"
    String? orderByClause, // e.g., "ORDER BY `shopName` ASC"
    bool distinct = false,
  }) async {
    MySqlConnection? conn;
    try {
      conn = await MySqlConnection.connect(settings);
      final buffer = StringBuffer('SELECT ');
      if (distinct) buffer.write('DISTINCT ');
      buffer.write('`$column` FROM `$table` ');
      if (whereClause != null && whereClause.trim().isNotEmpty) {
        buffer.write('$whereClause ');
      }
      if (orderByClause != null && orderByClause.trim().isNotEmpty) {
        buffer.write('$orderByClause ');
      }
      buffer.write(';');

      final sql = buffer.toString();
      final results = await conn.query(sql);

      return results.map((row) => row[0]?.toString() ?? '').toList();
    } catch (e, st) {
      // Added logging so you see the exact failure in console
      // Typical causes: host not reachable from device, SSL handshake failure, firewall rules.
      // You will see this when your UI shows "Failed to load Source options: ..."
      // and can diagnose the underlying network problem.
      // ignore: avoid_print
      print('MySQL fetchColumn failed: $e\n$st');
      rethrow;
    } finally {
      await conn?.close();
    }
  }
}
