
// postcode_service.dart
//
// Postcode validation fully disabled.
// This makes the app usable in regions without postcodes (e.g., Hong Kong)
// and prevents any postcodes.io network calls.

class PostcodeService {
  /// Always returns true. Postcode validation disabled.
  static Future<bool> validatePostcode(String postcode) async {
    return true;
  }

  /// Always returns true. Address-based postcode validation disabled.
  static Future<bool> validatePostcodeFromAddress(String address) async {
    return true;
  }
}
