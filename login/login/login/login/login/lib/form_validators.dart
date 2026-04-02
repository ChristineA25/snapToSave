
// lib/form_validators.dart
import 'dart:math';

class FormValidators {
  static const int kMaxTextLength = 65535;

  // ---------------------------------------------------------------------------
  // Pattern helpers
  // ---------------------------------------------------------------------------

  // 1, 2, 15
  static final RegExp _intRe = RegExp(r'^\d+$');

  // 0.5, 2, 2.75
  static final RegExp _realRe = RegExp(r'^\d+(?:\.\d+)?$');

  /// GBP price: optional £, optional thousands, max 2 dp
  /// Examples: 12, 1,234, 12.3, 12.34, £1,234.00, £6, 6, 6.0, 6.00
  ///
  /// Explanation:
  /// ^\s*£?\s*                  // optional whitespace + £ + whitespace
  /// (?:\d{1,3}(?:,\d{3})*|\d+) // either properly-grouped 1–3 digits + groups or just digits
  /// (?:\.\d{1,2})?             // optional . and 1–2 decimals
  /// \s*$                       // optional trailing whitespace
  static final RegExp _gbpRe = RegExp(
    r'^\s*£?\s*(?:\d{1,3}(?:,\d{3})*|\d+)(?:\.\d{1,2})?\s*$',
  );

  // ---------------------------------------------------------------------------
  // Length helpers
  // ---------------------------------------------------------------------------

  static String clampMaxLength(String s) =>
      s.length <= kMaxTextLength ? s : s.substring(0, kMaxTextLength);

  static bool exceedsMaxLength(String s) => s.length > kMaxTextLength;

  // ---------------------------------------------------------------------------
  // Quantity validators
  // ---------------------------------------------------------------------------

  /// Legacy: integer-only quantity (> 0)
  static String? validateQuantityInt(String? text) {
    final v = text?.trim() ?? '';
    if (v.isEmpty) return 'Required';
    if (!_intRe.hasMatch(v)) return 'Integers only';
    final n = int.tryParse(v);
    if (n == null) return 'Invalid number';
    if (n <= 0) return 'Must be > 0';
    if (n > 99999999) return 'Too large';
    return null;
    }

  /// Legacy: real-number quantity (> 0)
  static String? validateQuantityReal(String? text) {
    final v = text?.trim() ?? '';
    if (v.isEmpty) return 'Required';
    if (!_realRe.hasMatch(v)) return 'Numbers only (e.g., 0.5, 1, 2.75)';
    final d = double.tryParse(v);
    if (d == null) return 'Invalid number';
    if (d <= 0) return 'Must be > 0';
    if (d > 99999999) return 'Too large';
    return null;
  }

  /// ✅ New: quantity rule depends on unit.
  ///
  /// - For "pcs" or "pack" → integers only (> 0)
  /// - For other units → decimals OK (> 0)
  ///
  /// Pass the raw quantity text and the selected unit (can be null/empty).
  static String? validateQuantityByUnit(String? qtyText, String? unitRaw) {
    final qty = (qtyText ?? '').trim();
    final unit = (unitRaw ?? '').trim().toLowerCase();

    if (qty.isEmpty) return 'Required';

    final isIntegerUnit = unit == 'pcs' || unit == 'pack';

    if (isIntegerUnit) {
      // enforce integers
      if (!_intRe.hasMatch(qty)) return 'Integers only for $unit';
      final n = int.tryParse(qty);
      if (n == null) return 'Invalid number';
      if (n <= 0) return 'Must be > 0';
      if (n > 99999999) return 'Too large';
      return null;
    } else {
      // allow decimals
      if (!_realRe.hasMatch(qty)) {
        return 'Numbers only (e.g., 0.5, 1, 2.75)';
      }
      final d = double.tryParse(qty);
      if (d == null) return 'Invalid number';
      if (d <= 0) return 'Must be > 0';
      if (d > 99999999) return 'Too large';
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Price (GBP)
  // ---------------------------------------------------------------------------

  /// Price must be a valid GBP number. Accepts with/without £; up to 2 dp; > 0
  static String? validateGbpPrice(String? text) {
    final v = (text ?? '').trim();
    if (v.isEmpty) return 'Required';
    if (!_gbpRe.hasMatch(v)) return 'Invalid price';

    final numeric = _normalizeGbp(v);
    final d = double.tryParse(numeric);
    if (d == null) return 'Invalid number';
    if (d <= 0) return 'Must be > 0';
    if (d > 1e9) return 'Too large';
    return null;
  }

  /// Returns normalized numeric like "1234.50" (no £, no commas)
  static String _normalizeGbp(String raw) {
    var t = raw.replaceAll('£', '').replaceAll(',', '').trim();
    if (t.endsWith('.')) t = t.substring(0, t.length - 1);
    return t;
  }

  // ---------------------------------------------------------------------------
  // Address helper (unchanged logic; fixed split regex)
  // ---------------------------------------------------------------------------

  /// Extract two tokens before ", UK" (case-insensitive) -> "OUTCODE INCODE"
  /// Returns null if the pattern isn't found.
  static String? extractUkPostcodeFromAddress(String address) {
    final s = address.trim();
    final idx = s.toLowerCase().lastIndexOf(', uk');
    if (idx <= 0) return null;

    final before = s.substring(0, idx).trim();
    // tokenise by whitespace and commas; take last two tokens
    final tokens =
        before.split(RegExp(r'[\s,]+')).where((t) => t.isNotEmpty).toList();

    if (tokens.length < 2) return null;
    final last = tokens[tokens.length - 1];
    final prev = tokens[tokens.length - 2];
    return '$prev $last'.toUpperCase();
  }
}
