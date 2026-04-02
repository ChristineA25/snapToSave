
class Place {
  final String id;
  final String name;
  final String formattedAddress;
  final double lat;
  final double lng;
  final String? postcode;

  const Place({
    required this.id,
    required this.name,
    required this.formattedAddress,
    required this.lat,
    required this.lng,
    this.postcode,
  });
}
