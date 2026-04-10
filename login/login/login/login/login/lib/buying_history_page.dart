// buying_history_page.dart — Part 1 of 2
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'services/item_media_service.dart';


// buying_history_page.dart
import 'services/distance_filter_service.dart'; // NEW


/// ---------------------------------------------------------------------------
/// Buying History Page
/// - Fetches purchase records from a REST API backed by your MySQL `itemInput`
///   table (brand, itemName, feature, quantity, priceValue, channel, shop_name,
///   shop_address, chainShopID, createdAt) — *preserved*.
/// - Adds a feature-flag to serve **hard-coded** data for demos/offline use.
/// - Preserves existing functionality (search, filters, sorting, pull-to-refresh,
///   cheaper alternatives, back behavior, layouts).
/// ---------------------------------------------------------------------------
class BuyingHistoryPage extends StatefulWidget {
  final String userId;

  const BuyingHistoryPage({
    super.key,
    required this.userId,
  });

  @override
  State<BuyingHistoryPage> createState() => _BuyingHistoryPageState();
}

class _BuyingHistoryPageState extends State<BuyingHistoryPage> {

  static const String pricesUrl = 'https://nodejs-production-53a4.up.railway.app/api/prices';

  /// Update: direct endpoint (no query string filter; we filter locally).
  static const String endpointUrl =
      'https://nodejs-production-53a4.up.railway.app/api/item-input';

  static const String itemsCatalogUrl =
    'https://nodejs-production-53a4.up.railway.app/api/items/all';

  static const String chainShopUrl =
      'https://nodejs-production-53a4.up.railway.app/api/chain-shop';

  // NEW: base endpoint to fetch a user's allergens (built-in + custom_*)
  static const String userAllergenBase = 'https://nodejs-production-f031.up.railway.app/api/admin/userAllergen?userID=';

  
  // ✅ NEW: user blacklist endpoint (returns items as JSON-STRING; we parse it)
  static const String userBlacklistBase =
      'https://nodejs-production-f031.up.railway.app/api/user/blacklist?userID=';

  static const String kMapsApiKey =
      String.fromEnvironment('GMAPS_API_KEY', defaultValue: 'AIzaSyBE4LsC6I-OQwcsC3dmH4IrGTv3oFnhyT4'); // <-- set via --dart-define

  late DistanceFilterService _distance; 
      

  // ✅ NEW: fast membership checks
  Set<String> _blacklistedItemIds = {};

  // Map: shopId or shopCode (lowercased) -> shopName
  final Map<String, String> _shopNameByKey = {};

  // NEW: base for the items search service
    final ItemMediaService _media =
        ItemMediaService('https://nodejs-production-53a4.up.railway.app/');

    // Keyed by normalized item name (e.g., "semi skimmed milk")
    Map<String, List<String>> _itemIdsByNameKey = {};

    // NEW: store item information again (catalog from /api/items/all)
    Map<String, ItemCatalogEntry> _itemsById = {};

    Map<String, List<String>> _itemIdsByFamily = {};   
    Map<String, _ProductFamily> _familyByItemId = {};

    List<PriceEntry> _allPrices = [];
    Map<String, List<PriceEntry>> _pricesByItemId = {};

    // NEW: allergen word set (normalized, lowercase, tokenized)
    Set<String> _allergenWords = {};

  /// Flip to `true` if you want to run purely with hard-coded demo data.
  static const bool kForceHardCodedBuyingHistory = false;

  late Future<List<Purchase>> _future;

  String _query = '';
  String _channelFilter = 'All'; // All | Online | Physical
  String _sort = 'Newest'; // Newest | Oldest | Price ↑ | Price ↓

  String _resolveShopName({String? shopId, String? shopCode}) {
    final id = (shopId ?? '').toLowerCase().trim();
    final cd = (shopCode ?? '').toLowerCase().trim();
    if (id.isNotEmpty && _shopNameByKey.containsKey(id)) {
      return _shopNameByKey[id]!;
    }
    if (cd.isNotEmpty && _shopNameByKey.containsKey(cd)) {
      return _shopNameByKey[cd]!;
    }
    // Fallback: prefer code, then id, then generic
    if (cd.isNotEmpty) return cd;
    if (id.isNotEmpty) return id;
    return 'Other store';
  }

  // Add this field to your _BuyingHistoryPageState class
  double _userOffsetHours = 0.0;

  @override
  void initState() {
    super.initState();

    // ✅ initialize immediately
    _future = fetchPurchases(widget.userId);

    // ✅ then run your async bootstrap
    _initData();
  }
  
  Future<void> _initData() async {
    // 0) Fetch and apply timezone offset first (keeps your custom date display)
    final String userTzCode = await _fetchUserTimeZone(widget.userId);
    _userOffsetHours = await _fetchOffsetForRegion(userTzCode);

    // 1) Bootstrap data that other features depend on
    await _fetchUserBlacklist(widget.userId); // blacklist first → used by suggestions
    await _fetchUserAllergens(widget.userId);
    await _fetchChainShops();
    await _fetchItemsCatalog();
    await _fetchPrices();

    // 2) Distance filter service: loads homeAdd/workAdd and geocodes once
    _distance = DistanceFilterService(
      userId: widget.userId,
      adminLoginBase:
          'https://nodejs-production-f031.up.railway.app/api/admin/loginTable/',
      mapsApiKey: kMapsApiKey, // set via --dart-define GMAPS_API_KEY=...
    );
    await _distance.init(); // gets {homeAdd, workAdd} -> lat/lng & warms caches

    // 3) Kick off purchases fetch (page content)
    setState(() {
      _future = fetchPurchases(widget.userId);
    });
  }

  // ✅ NEW: read { userID: "...", items: "[\"id1\",\"id2\"]" }
  Future<void> _fetchUserBlacklist(String userId) async {
    try {
      final uri = Uri.parse('$userBlacklistBase${Uri.encodeComponent(userId)}');
      final res = await http.get(uri).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final Map<String, dynamic> body = json.decode(res.body);
        final raw = (body['items'] as String?) ?? '[]'; // stringified JSON
        final List<dynamic> ids = json.decode(raw);
        setState(() {
          _blacklistedItemIds = ids.map((e) => e.toString()).toSet();
        });
      } else {
        // Soft-fail: keep empty blacklist
        _blacklistedItemIds = {};
      }
    } catch (_) {
      _blacklistedItemIds = {};
    }
  }

  Future<String> _fetchUserTimeZone(String userId) async {
  try {
    final url = 'https://nodejs-production-f031.up.railway.app/api/admin/loginTable/$userId';
    final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
    if (res.statusCode == 200) {
      final data = json.decode(res.body);
      return _asString(data['displayTime']).toLowerCase().trim();
    }
  } catch (e) {
    debugPrint("Error fetching user timezone: $e");
  }
  return 'gbr'; // Fallback
}

  Future<double> _fetchOffsetForRegion(String isoCode) async {
    if (isoCode.isEmpty) return 0.0;
    try {
      const url = 'https://nodejs-production-53a4.up.railway.app/phone/regions/with-sites?timeoutMs=20000&concurrency=4&overallMs=90000';
      final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 15));
      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        final List rows = data['rows'] ?? [];
        final region = rows.firstWhere(
          (r) => _asString(r['regionID']).toLowerCase() == isoCode,
          orElse: () => null,
        );
        if (region != null) return _asDouble(region['offsetHrsVsUtc']);
      }
    } catch (e) {
      debugPrint("Error fetching region offset: $e");
    }
    return 0.0;
  }

  Future<List<Purchase>> fetchPurchases(
  String userId, {
  bool forceNetwork = false,
}) async {
  // 1. Handle Hardcoded Flag
  if (kForceHardCodedBuyingHistory && !forceNetwork) {
    return _hardcodedPurchasesFor(userId);
  }

  try {
    final uri = Uri.parse(endpointUrl);
    final res = await http
        .get(
          uri,
          headers: {
            'x-all': '1', // ✅ Required to bypass default LIMIT/OFFSET
          },
        );

    if (res.statusCode == 200) {
      final dynamic data = json.decode(res.body);
      List<dynamic> rows;
      if (data is Map && data['rows'] is List) {
        rows = List<dynamic>.from(data['rows'] as List);
      } else if (data is List) {
        rows = data;
      } else {
        rows = const [];
      }

      final List<Purchase> items = rows.map<Purchase>((raw) {
        final r = Map<String, dynamic>.from(raw as Map);
        
        // --- TIMEZONE ADJUSTMENT ---
        // Uses the _userOffsetHours fetched during _initData
        DateTime? rawDate = _asDateTime(r['createdAt']);
        DateTime adjustedDate = rawDate != null 
            ? rawDate.add(Duration(minutes: (_userOffsetHours * 60).toInt()))
            : DateTime.now();

        final brand = _asString(r['brand']);
        final itemName = _asString(r['itemName']);
        final feature = _asString(r['feature']);
        final quantity = _asString(r['quantity']);
        final shopName = _asString(r['shop_name']);
        final chain = _asString(r['chainShopID']);
        
        final discountApplied = r['discountApplied'];
        final hasDiscount = (discountApplied is num && discountApplied != 0);

        return Purchase(
          userId: _asString(r['userID']),
          productName: _composeTitle(itemName, feature, quantity),
          brand: brand,
          store: shopName.isNotEmpty ? shopName : (chain.isNotEmpty ? chain : 'Unknown store'),
          price: _asDouble(r['priceValue']),
          purchasedAt: adjustedDate, // <--- Customized Time
          itemId: _asString(r['itemID']), // Required for suggestions
          quantity: quantity,
          channel: _asString(r['channel']),
          shopAddress: _asString(r['shop_address']),
          chainShopId: chain,
          rawItemName: itemName,
          rawFeature: feature,
          rawItemNo: _asString(r['itemNo']),
          discountType: hasDiscount ? 'Discount applied' : null,
        );
      }).where((p) => p.userId == userId).toList();

      if (items.isNotEmpty) {
        // --- DATA ENRICHMENT & CATALOG MAPPING ---
        for (var p in items) {
          if (p.itemId != null && _itemsById.containsKey(p.itemId)) {
            final catalog = _itemsById[p.itemId]!;
            
            // Fill missing brand/feature from catalog
            if (p.brand.isEmpty) p.brand = catalog.brand;
            if (p.rawFeature == null || p.rawFeature!.isEmpty || p.rawFeature == 'null') {
              p.rawFeature = catalog.feature;
            }

            // Re-compose title if original was generic
            if (p.productName.isEmpty || p.productName.toLowerCase().contains('unknown')) {
              p.productName = _composeTitle(
                catalog.name, 
                p.rawFeature ?? '', 
                p.quantity ?? catalog.quantity ?? ''
              );
            }
          }
        }
        return items;
      }
    }
    // Fallback if status code not 200 or list empty
    return _mockPurchases.where((p) => p.userId == userId).toList();
  } catch (e) {
    debugPrint("Error in fetchPurchases: $e");
    return _mockPurchases.where((p) => p.userId == userId).toList();
  }
}

  Future<void> _fetchChainShops() async {
    try {
      final uri = Uri.parse(chainShopUrl);
      final res = await http.get(uri).timeout(const Duration(seconds: 12));
      if (res.statusCode == 200) {
        final decoded = json.decode(res.body);
        final List shops = (decoded is Map && decoded['shops'] is List)
            ? List.from(decoded['shops'] as List)
            : (decoded is List ? decoded : const []);
        final map = <String, String>{};
        for (final raw in shops) {
          final m = Map<String, dynamic>.from(raw as Map);
          final name = _asString(m['shopName']).trim();
          final id = _asString(m['shopID']).trim();
          if (name.isEmpty) continue;
          // Index by ID (lowercase)
          if (id.isNotEmpty) map[id.toLowerCase()] = name;
          // Optionally index by a code alias if your data has it, e.g. "shopCD"
          final code = _asString(m['shopCD']).trim();
          if (code.isNotEmpty) map[code.toLowerCase()] = name;
        }
        if (mounted) {
          setState(() => _shopNameByKey
            ..clear()
            ..addAll(map));
        }
      }
    } catch (_) {
      // soft-fail; we can still show IDs if name not found
    }
  }

  
  // NEW: fetch all recent prices and group them by itemID for fast lookup
  Future<void> _fetchPrices() async {
    try {
      final uri = Uri.parse(pricesUrl);
      final res = await http.get(uri).timeout(const Duration(seconds: 12));
      if (res.statusCode == 200) {
        final dynamic data = json.decode(res.body);

        final List rows = (data is Map && data['rows'] is List)
            ? List.from(data['rows'] as List)
            : (data is List ? data : const []);

        final List<PriceEntry> list = rows.map<PriceEntry>((raw) {
          final m = Map<String, dynamic>.from(raw as Map);
          return PriceEntry.fromJson(m);
        }).toList();

        // Index by itemID and sort per item by effective price ascending
        final byId = <String, List<PriceEntry>>{};
        for (final p in list) {
          if (p.itemId.isEmpty) continue;
          (byId[p.itemId] ??= <PriceEntry>[]).add(p);
        }
        for (final e in byId.entries) {
          e.value.sort((a, b) => a.effectivePrice.compareTo(b.effectivePrice));
        }

        if (mounted) {
          setState(() {
            _allPrices = list;
            _pricesByItemId = byId;
          });
        }
      }
    } catch (_) {
      // swallow errors; we'll just fall back to existing mock suggestion
    }
  }

  // --- Allergen support -------------------------------------------------------

  Future<void> _fetchUserAllergens(String userId) async {
    try {
      final uri = Uri.parse('$userAllergenBase${Uri.encodeComponent(userId)}');
      final res = await http.get(uri).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final dynamic data = json.decode(res.body);

        // The API you showed returns { page, pageSize, total, rows: [ { userID, allergenID }, ... ] }
        final List rows = (data is Map && data['rows'] is List)
            ? List.from(data['rows'] as List)
            : (data is List ? data : const []);

        final Set<String> words = {};
        for (final raw in rows) {
          final m = Map<String, dynamic>.from(raw as Map);
          final id = _asString(m['allergenID']).trim();
          if (id.isEmpty) continue;

          // Normalize: lowercase; split on non-letters; also strip "custom_" prefix and underscores
          void addVariants(String s) {
            final base = s.toLowerCase();
            words.add(base);
            words.add(base.replaceFirst(RegExp(r'^custom_'), ''));   // custom_sesame_oil -> sesame_oil
            words.add(base.replaceAll('_', ' '));                    // sesame_oil -> sesame oil
          }
          addVariants(id);

          // Also split to tokens to catch "sesame" within "sesame oil"
          final tokens = id
              .toLowerCase()
              .replaceAll(RegExp(r'[^a-z0-9\s_]'), ' ')
              .replaceAll('_', ' ')
              .split(RegExp(r'\s+'))
              .where((t) => t.isNotEmpty);
          words.addAll(tokens);
        }

        if (mounted) {
          setState(() => _allergenWords = words);
        }
      }
    } catch (e) {
      debugPrint('Error fetching user allergens: $e');
      // Leave _allergenWords empty on failure.
    }
  }

  bool _textHasAllergen(String text) {
    if (_allergenWords.isEmpty) return false;
    final norm = text
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\s_]'), ' ')
        .replaceAll('_', ' ');
    // token match OR substring fallback (keeps it simple)
    for (final w in _allergenWords) {
      if (w.isEmpty) continue;
      if (norm.contains(w)) return true;
    }
    return false;
  }

  bool _entryHasAllergen(ItemCatalogEntry entry) {
    final buf = StringBuffer();
    buf.write(entry.name);
    if ((entry.feature ?? '').isNotEmpty) buf.write(' ${entry.feature}');
    if (entry.brand.isNotEmpty) buf.write(' ${entry.brand}');
    return _textHasAllergen(buf.toString());
  }

  // Safe-check for a free text title when catalog entry is missing
  bool _titleHasAllergen(String title) => _textHasAllergen(title);

  
// buying_history_page.dart  (inside _BuyingHistoryPageState)
// REPLACE the whole _suggestFromPriceData with this distance-aware version.

List<Alternative> _suggestFromPriceData(Purchase purchase) {
  final List<Alternative> suggestions = [];

  // --- current context -------------------------------------------------------
  final id = purchase.itemId ?? '';
  final currentPrice = purchase.price;
  final currentChain = (purchase.chainShopId ?? '').toLowerCase().trim();
  final currentStoreName = purchase.store.toLowerCase().trim();

  // Catalog & PPU for the purchased item (unchanged)
  final cat = (id.isNotEmpty) ? _itemsById[id] : null;
  final currentPPU = _pricePerUnit(
    price: currentPrice,
    quantity: purchase.quantity,
    fallbackQuantity: cat?.quantity,
  );

  // --- helpers ---------------------------------------------------------------
  bool _isSameStore(PriceEntry p) {
    final sc = p.shopCode.toLowerCase();
    final sid = p.shopId.toLowerCase();
    return sc == currentChain || sid == currentChain || (currentChain.isEmpty && currentStoreName.contains(sc));
  }

  Alternative _altFrom(PriceEntry p, ItemCatalogEntry base) {
    final q = base.quantity ?? purchase.quantity ?? '';
    final f = base.feature ?? purchase.rawFeature ?? '';
    final ppu = _pricePerUnit(price: p.effectivePrice, quantity: q, fallbackQuantity: q);
    final title = _composeTitle(base.name, f, q);
    return Alternative(
      productName: title,
      brand: base.brand,
      store: _resolveShopName(shopId: p.shopId, shopCode: p.shopCode),
      price: p.effectivePrice,
      quantity: q,
      feature: f,
      ppu: ppu,
      itemId: base.id,
      channel: p.channel,
      shopAddress: p.shopAddress,
      discountType: p.hasDiscount ? 'discount applied' : null,
      discountWhat: p.discountWhat,
    );
  }

  // --- allergen/blacklist guards (preserved) --------------------------------
  bool _candidateIsAllergen(ItemCatalogEntry base) => _entryHasAllergen(base);
  bool _candidateTitleIsAllergen(String title) => _titleHasAllergen(title);
  bool _isBlacklistedId(String? itemId) {
    if (itemId == null || itemId.isEmpty) return false;
    return _blacklistedItemIds.contains(itemId);
  }
  final purchasedIsBlacklisted = _isBlacklistedId(id);

  // --- NEW: distance screen --------------------------------------------------
  bool _maybeAllowedByDistance(Alternative alt) {
    // First consult cache (sync). If null, kick async compute and allow for now.
    final cached = _distance.cachedAllowFor(
      shopAddress: alt.shopAddress,
      channel: alt.channel,
      thresholdMin: 30,
    );
    if (cached == null) {
      _distance
          .allowFor(shopAddress: alt.shopAddress, channel: alt.channel, thresholdMin: 30)
          .then((_) { if (mounted) setState(() {}); });
      return true; // optimistic until computed; UI will refresh when done
    }
    return cached;
  }

  // ========== RECOMMENDATION 1: same item cheaper elsewhere ==================
  // Only if we know the ID and the purchased item itself is not blacklisted
  if (id.isNotEmpty && !purchasedIsBlacklisted) {
    final base = _itemsById[id] ?? ItemCatalogEntry(
      id: id,
      name: purchase.productName,
      brand: purchase.brand,
      quantity: purchase.quantity,
      feature: purchase.rawFeature,
    );
    final renderedTitle = _composeTitle(base.name, base.feature ?? '', base.quantity ?? '');
    final safeFromAllergen =
        !_candidateIsAllergen(base) && !_candidateTitleIsAllergen(renderedTitle);

    if (safeFromAllergen) {
      final candidates = _pricesByItemId[id] ?? const <PriceEntry>[];
      for (final c in candidates) {
        if (c.effectivePrice < currentPrice && !_isSameStore(c)) {
          final alt = _altFrom(c, base);
          if (!_isBlacklistedId(alt.itemId) &&
              !_candidateTitleIsAllergen(alt.productName) &&
              _maybeAllowedByDistance(alt)) {
            suggestions.add(alt);
            break; // best same-item suggestion (sorted in _fetchPrices)
          }
        }
      }
    }
  }

  // ========== RECOMMENDATION 2: same name lower PPU (different ID) ==========
  final nameKey = _nameKey(purchase.rawItemName ?? purchase.productName);
  final sameNameIds = _itemIdsByNameKey[nameKey] ?? const <String>[];
  final List<Alternative> sameNameAlts = [];
  for (final otherId in sameNameIds) {
    if (otherId == id) continue; // want different item id
    if (_isBlacklistedId(otherId)) continue;
    final otherCat = _itemsById[otherId];
    final entries = _pricesByItemId[otherId];
    if (otherCat == null || entries == null || entries.isEmpty) continue;
    if (_candidateIsAllergen(otherCat)) continue;

    for (final p in entries) {
      if (_isSameStore(p)) continue; // different source
      final q = otherCat.quantity ?? purchase.quantity;
      final ppu = _pricePerUnit(price: p.effectivePrice, quantity: q, fallbackQuantity: q);
      if (ppu < currentPPU) {
        final alt = _altFrom(p, otherCat);
        if (!_isBlacklistedId(alt.itemId) &&
            !_candidateTitleIsAllergen(alt.productName) &&
            _maybeAllowedByDistance(alt)) {
          sameNameAlts.add(alt);
        }
      }
    }
  }
  if (sameNameAlts.isNotEmpty) {
    sameNameAlts.sort((a, b) =>
        (a.ppu ?? double.infinity).compareTo(b.ppu ?? double.infinity));
    suggestions.add(sameNameAlts.first);
  }

  // ========== RECOMMENDATION 3: other item of the lowest cost ===============
  // Fallback ONLY when above suggestions are empty or were filtered by distance.
  // We interpret “other item” as: from the same name group OR family, lowest absolute price
  if (suggestions.isEmpty) {
    final List<Alternative> anyCheaper = [];

    // 3a) within same "nameKey" space
    for (final otherId in sameNameIds) {
      if (_isBlacklistedId(otherId)) continue;
      final otherCat = _itemsById[otherId];
      final entries = _pricesByItemId[otherId];
      if (otherCat == null || entries == null || entries.isEmpty) continue;
      if (_candidateIsAllergen(otherCat)) continue;

      for (final p in entries) {
        final alt = _altFrom(p, otherCat);
        // Absolute price must beat current price, and pass distance
        if (alt.price < currentPrice &&
            !_isBlacklistedId(alt.itemId) &&
            !_candidateTitleIsAllergen(alt.productName) &&
            _maybeAllowedByDistance(alt)) {
          anyCheaper.add(alt);
        }
      }
    }

    // 3b) expand to "family" if nameKey produced nothing
    if (anyCheaper.isEmpty && id.isNotEmpty) {
      final fam = _familyByItemId[id];
      final familyIds = (fam != null) ? (_itemIdsByFamily[fam.family] ?? const <String>[]) : const <String>[];
      for (final otherId in familyIds) {
        if (_isBlacklistedId(otherId)) continue;
        final otherCat = _itemsById[otherId];
        final entries = _pricesByItemId[otherId];
        if (otherCat == null || entries == null || entries.isEmpty) continue;
        if (_candidateIsAllergen(otherCat)) continue;

        for (final p in entries) {
          final alt = _altFrom(p, otherCat);
          if (alt.price < currentPrice &&
              !_isBlacklistedId(alt.itemId) &&
              !_candidateTitleIsAllergen(alt.productName) &&
              _maybeAllowedByDistance(alt)) {
            anyCheaper.add(alt);
          }
        }
      }
    }

    if (anyCheaper.isNotEmpty) {
      anyCheaper.sort((a, b) => a.price.compareTo(b.price));
      suggestions.add(anyCheaper.first); // absolute cheapest acceptable item
    }
  }

  return suggestions;
}

  Future<void> _fetchItemsCatalog() async {
    try {
      final uri = Uri.parse(itemsCatalogUrl);
      final res = await http.get(uri).timeout(const Duration(seconds: 12));
      if (res.statusCode == 200) {
        final dynamic data = json.decode(res.body);

        // Handle either {"count": N, "rows": [...]} or a plain array
        final List rows = (data is Map && data['rows'] is List)
            ? List.from(data['rows'] as List)
            : (data is List ? data : const []);

        // --- existing: build byId (unchanged) ---
        final byId = <String, ItemCatalogEntry>{};

        // --- new: build family maps (note different names to avoid shadowing) ---
        final byFamily = <String, List<String>>{};
        final famById = <String, _ProductFamily>{};

        final byNameKey = <String, List<String>>{};

        for (final raw in rows) {
          final map = Map<String, dynamic>.from(raw as Map);
          final entry = ItemCatalogEntry.fromJson(map);
          if (entry.id.isEmpty) continue;

          byId[entry.id] = entry;

          final fam = _familyFromNameBrandFeature(
            name: entry.name,
            brand: entry.brand,
            feature: entry.feature ?? '',
          );
          famById[entry.id] = fam;
          (byFamily[fam.family] ??= <String>[]).add(entry.id);

          // NEW: index by normalized name (brand/size independent)
          final key = _nameKey(entry.name);
          (byNameKey[key] ??= <String>[]).add(entry.id);
        }

        if (mounted) {
          setState(() {
            _itemsById = byId;
            _itemIdsByFamily = byFamily;
            _familyByItemId = famById;
            // NEW
            _itemIdsByNameKey = byNameKey;
          });
        }

        for (final raw in rows) {
          final map = Map<String, dynamic>.from(raw as Map);
          final entry = ItemCatalogEntry.fromJson(map);
          if (entry.id.isEmpty) continue;

          // Keep original map
          byId[entry.id] = entry;

          // NEW: derive family metadata (lightweight heuristics)
          final fam = _familyFromNameBrandFeature(
            name: entry.name,
            brand: entry.brand,
            feature: entry.feature ?? '',
          );
          famById[entry.id] = fam;
          (byFamily[fam.family] ??= <String>[]).add(entry.id);
        }

        if (mounted) {
          setState(() {
            _itemsById = byId;           // existing
            _itemIdsByFamily = byFamily; // assign to state field
            _familyByItemId = famById;   // assign to state field
          });
        }
      }
    } catch (_) {
      // Swallow errors; catalog is optional for suggestions.
    }
  }


  Future<void> _refresh() async {
    setState(() {
      _future = fetchPurchases(widget.userId, forceNetwork: true);
    });
    await _future;
  }

  /// ▶ NEW: Hard-coded data generator (ties items to the provided userId
  /// so the list shows up regardless of what ID you pass in).
  List<Purchase> _hardcodedPurchasesFor(String userId) {
    final now = DateTime.now();
    return <Purchase>[
      Purchase(
        userId: userId,
        productName: 'Bananas 1kg',
        brand: 'Brand A',
        store: 'ASDA Bedminster',
        price: 0.98,
        purchasedAt: now.subtract(const Duration(days: 2, hours: 3)),
        quantity: '1kg',
        channel: 'Physical',
        shopAddress: 'East St, Bristol',
        rawFeature: 'Class I',
        rawItemNo: 'B002',
        discountType: 'Price Drop', // NEW
      ),
      // e.g., Greek Yogurt with a club-card promo
      Purchase(
        userId: userId,
        productName: 'Greek Yogurt 500g — Honey',
        brand: 'Fage',
        store: 'Sainsbury’s Online',
        price: 2.20,
        purchasedAt: now.subtract(const Duration(days: 3, hours: 6)),
        quantity: '500g',
        channel: 'Online',
        shopAddress: 'Delivery',
        rawFeature: 'Honey',
        rawItemNo: 'C003',
        discountType: 'Loyalty Card Price', // NEW
      ),
      // e.g., Eggs with “2 for £4” multibuy
      Purchase(
        userId: userId,
        productName: 'Free‑Range Eggs (12)',
        brand: 'Store Own',
        store: 'Lidl Kingswood',
        price: 2.49,
        purchasedAt: now.subtract(const Duration(days: 4)),
        quantity: '12 eggs',
        channel: 'Physical',
        shopAddress: 'Regent St, Kingswood',
        rawFeature: 'Free‑range',
        rawItemNo: 'D004',
        discountType: 'Multibuy 2 for £4', // NEW
      ),
      // Bread with "Buy 1 Get 1 Half Price"
      Purchase(
        userId: userId,
        productName: 'Brown Bread — Wholemeal 800g',
        brand: 'Hovis',
        store: 'Morrisons Fishponds',
        price: 1.25,
        purchasedAt: now.subtract(const Duration(days: 5, hours: 5)),
        quantity: '800g',
        channel: 'Physical',
        shopAddress: 'Fishponds Rd, Bristol',
        rawFeature: 'Wholemeal',
        rawItemNo: 'E005',
        discountType: 'BOGO Half Price', // NEW
      ),
      // Pasta with “Rollback”
      Purchase(
        userId: userId,
        productName: 'Pasta Fusilli 1kg',
        brand: 'Barilla',
        store: 'Amazon UK',
        price: 1.80,
        purchasedAt: now.subtract(const Duration(days: 6)),
        quantity: '1kg',
        channel: 'Online',
        shopAddress: 'Delivery',
        rawFeature: 'Fusilli',
        rawItemNo: 'F006',
        discountType: 'Deal of the Day', // NEW
      ),
      // Passata with “Yellow sticker”
      Purchase(
        userId: userId,
        productName: 'Tomato Passata 700g',
        brand: 'Cirio',
        store: 'Aldi Horfield',
        price: 1.15,
        purchasedAt: now.subtract(const Duration(days: 7)),
        quantity: '700g',
        channel: 'Physical',
        shopAddress: 'Gloucester Rd, Bristol',
        rawFeature: 'Passata',
        rawItemNo: 'G007',
        discountType: 'Markdown (yellow sticker)', // NEW
      ),
      // Cheese with “3 for £10 mix & match”
      Purchase(
        userId: userId,
        productName: 'Cheddar Cheese 400g — Mature',
        brand: 'Cathedral City',
        store: 'Co‑op Online',
        price: 3.50,
        purchasedAt: now.subtract(const Duration(days: 8, hours: 4)),
        quantity: '400g',
        channel: 'Online',
        shopAddress: 'Delivery',
        rawFeature: 'Mature',
        rawItemNo: 'H008',
        discountType: 'Mix & Match 3 for £10', // NEW
      ),
    ];
  }

  List<Purchase> _applyView(List<Purchase> purchases) {
    // Search filter
    final q = _query.trim().toLowerCase();
    Iterable<Purchase> view = purchases.where((p) {
      if (_channelFilter != 'All' &&
          (p.channel ?? '').toLowerCase() != _channelFilter.toLowerCase()) {
        return false;
      }
      if (q.isEmpty) return true;
      return p.productName.toLowerCase().contains(q) ||
          p.brand.toLowerCase().contains(q) ||
          p.store.toLowerCase().contains(q);
    });

    final list = view.toList();

    // Sorting
    switch (_sort) {
      case 'Newest':
        list.sort((a, b) => b.purchasedAt.compareTo(a.purchasedAt));
        break;
      case 'Oldest':
        list.sort((a, b) => a.purchasedAt.compareTo(b.purchasedAt));
        break;
      case 'Price ↑':
        list.sort((a, b) => a.price.compareTo(b.price));
        break;
      case 'Price ↓':
        list.sort((a, b) => b.price.compareTo(a.price));
        break;
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Buying History'),
        // ⬇️ Preserved: back button goes straight to the first route (HomePage).
        leading: BackButton(
          onPressed: () {
            Navigator.of(context).popUntil((route) => route.isFirst);
          },
        ),
      ),
      body: Column(
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    "User ID: ${widget.userId}",
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _ChannelFilter(
                  value: _channelFilter,
                  onChanged: (v) =>
                      setState(() => _channelFilter = v ?? _channelFilter),
                ),
                const SizedBox(width: 8),
                _SortMenu(
                  value: _sort,
                  onChanged: (v) => setState(() => _sort = v ?? _sort),
                ),
              ],
            ),
          ),
          // Search
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: TextField(
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: 'Search product / brand / store',
                filled: true,
                fillColor: Theme.of(context)
                    .colorScheme
                    .surfaceContainerHighest
                    .withOpacity(.4),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding:
                    const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          // Data
          Expanded(
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: FutureBuilder<List<Purchase>>(
                future: _future,
                builder: (context, snapshot) {
                  final loading =
                      snapshot.connectionState == ConnectionState.waiting &&
                          !snapshot.hasData;
                  final error = snapshot.hasError;
                  final data = snapshot.data ?? const <Purchase>[];

                  if (loading) {
                    return const _LoadingState();
                  }
                  if (error) {
                    // Show network error but still try to show any available data.
                    return _ErrorWithRetry(onRetry: _refresh);
                  }

                  final view = _applyView(data);
                  if (view.isEmpty) {
                    return const _EmptyState();
                  }

                  return ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: view.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final item = view[index];
                      final suggestions = _suggestFromPriceData(item); // Note: plural
                      return _PurchaseTile(
                        item: item,
                        suggestions: suggestions, 
                      );
                    },
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// -------------------------
/// UI Widgets
/// -------------------------
class _PurchaseTile extends StatelessWidget {
  final Purchase item;
  final List<Alternative> suggestions; // List instead of single item
  const _PurchaseTile({required this.item, required this.suggestions});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return _TileWithImage(
          item: item,
          suggestions: suggestions,
        );

  }
}

// NEW: Extracted widget that resolves and shows the network image per item
class _TileWithImage extends StatefulWidget {
  final Purchase item;
  final List<Alternative> suggestions; // Match what the UI uses
  const _TileWithImage({
    required this.item,
    required this.suggestions,
  });

  @override
  State<_TileWithImage> createState() => _TileWithImageState();
}

class _TileWithImageState extends State<_TileWithImage> {
  String? _picUrl;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _resolveImage();
    });
  }
  
  @override
  void didUpdateWidget(_TileWithImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.itemId != widget.item.itemId || 
        oldWidget.item.productName != widget.item.productName) {
      _loaded = false; 
      _resolveImage();
    }
  }

  Future<void> _resolveImage() async {
    if (_loaded) return;
    _loaded = true;

    final state = context.findAncestorStateOfType<_BuyingHistoryPageState>();
    final media = state?._media;
    String? url;

    if (media != null) {
      final id = (widget.item.itemId ?? '').trim();
      if (id.isNotEmpty) {
        url = await media.picFor(itemId: id, idOnlyWhenIdPresent: true);
      } else {
        final cleanName = (widget.item.rawItemName ?? '').trim();
        final brand = widget.item.brand.trim();
        if (cleanName.isNotEmpty) {
          url = await media.picFor(
            itemId: null,
            name: cleanName,
            brand: brand,
            idOnlyWhenIdPresent: true,
          );
        }
      }
    }

    if (mounted) {
      setState(() => _picUrl = (url != null && url.isNotEmpty) ? url : null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final hasSuggestion = widget.suggestions.isNotEmpty;

    // --- LOGIC FOR FEATURE FALLBACK ---
    // Check if the bought item has a valid feature.
    final rawF = (widget.item.rawFeature ?? '').trim();
    final hasValidFeature = rawF.isNotEmpty && rawF.toLowerCase() != 'null';
    
    // If not, try to grab the feature from the first suggestion (the 'picture item').
    String? displayFeature;
    if (hasValidFeature) {
      displayFeature = widget.item.rawFeature;
    } else if (hasSuggestion) {
      final suggestedFeature = (widget.suggestions.first.feature ?? '').trim();
      if (suggestedFeature.isNotEmpty && suggestedFeature.toLowerCase() != 'null') {
        displayFeature = suggestedFeature;
      }
    }

    return ListTile(
      leading: (_picUrl == null)
          ? null
          : CircleAvatar(
              backgroundColor: Colors.blue.shade50,
              backgroundImage: NetworkImage(_picUrl!),
              onBackgroundImageError: (_, __) {},
            ),
      title: Text(
        '${widget.item.brand.isNotEmpty ? '${widget.item.brand} • ' : ''}${widget.item.productName}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _Pill(
                  text: '£${widget.item.price.toStringAsFixed(2)}',
                  icon: Icons.payments,
                  color: colorScheme.primary,
                ),
                if ((widget.item.discountType ?? '').isNotEmpty)
                  _Pill(
                    text: widget.item.discountType!,
                    icon: Icons.local_offer,
                    color: Colors.redAccent,
                  ),
                if ((widget.item.quantity ?? '').isNotEmpty)
                  _Pill(
                    text: widget.item.quantity!,
                    icon: Icons.scale,
                    color: colorScheme.secondary,
                  ),
                if ((widget.item.channel ?? '').isNotEmpty)
                  _Pill(
                    text: widget.item.channel!,
                    icon: (widget.item.channel ?? '').toLowerCase() == 'online'
                        ? Icons.public
                        : Icons.store,
                    color: colorScheme.tertiary,
                  ),
                _Pill(
                  text: _formatDateTime(widget.item.purchasedAt),
                  icon: Icons.schedule,
                  color: colorScheme.outline,
                ),
                // UPDATED PILL: Uses the displayFeature resolved above
                if (displayFeature != null)
                  _Pill(
                    text: displayFeature,
                    icon: Icons.style,
                    color: Colors.deepPurple,
                  ),
                if ((widget.item.rawItemNo ?? '').isNotEmpty)
                  _Pill(
                    text: '#${widget.item.rawItemNo!}',
                    icon: Icons.numbers,
                    color: Colors.indigo,
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text.rich(
              TextSpan(
                children: [
                  const TextSpan(
                      text: 'Store: ',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  TextSpan(text: widget.item.store),
                  if ((widget.item.shopAddress ?? '').isNotEmpty)
                    const TextSpan(text: ' • '),
                  if ((widget.item.shopAddress ?? '').isNotEmpty)
                    TextSpan(
                      text: widget.item.shopAddress!,
                      style: TextStyle(color: Colors.grey.shade700),
                    ),
                ],
              ),
            ),
            if (hasSuggestion) ...[
              const SizedBox(height: 8),
              ...widget.suggestions.map((alt) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 6.0),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.green.withOpacity(.06),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.green.withOpacity(.25)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Cheaper at ${alt.store}: £${alt.price.toStringAsFixed(2)} '
                          '(${_formatSaving(widget.item.price - alt.price)} saving)',
                          style: TextStyle(
                              color: Colors.green.shade800,
                              fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          children: [
                            if (alt.brand.isNotEmpty)
                              _Pill(
                                  text: alt.brand,
                                  icon: Icons.flag,
                                  color: Colors.blueGrey),
                            if (alt.quantity != null)
                              _Pill(
                                  text: alt.quantity!,
                                  icon: Icons.scale,
                                  color: Colors.teal.shade700),
                            if (alt.feature != null)
                              _Pill(
                                  text: alt.feature!,
                                  icon: Icons.style,
                                  color: Colors.deepPurple),
                            if (alt.channel != null)
                              _Pill(
                                  text: alt.channel!,
                                  icon: alt.channel!.toLowerCase() == 'online'
                                      ? Icons.public
                                      : Icons.store,
                                  color: Colors.teal),
                            if (alt.discountWhat != null)
                              _Pill(
                                  text: alt.discountWhat!,
                                  icon: Icons.local_offer,
                                  color: Colors.redAccent),
                            if (alt.shopAddress != null)
                              _Pill(
                                  text: alt.shopAddress!,
                                  icon: Icons.place,
                                  color: Colors.brown),
                            if (alt.ppu != null)
                              _Pill(
                                  text: '£${alt.ppu!.toStringAsFixed(4)}/unit',
                                  icon: Icons.calculate,
                                  color: Colors.green.shade800),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ],
          ],
        ),
      ),
      trailing: Icon(
        hasSuggestion ? Icons.trending_down : Icons.check,
        color: hasSuggestion ? Colors.green : Colors.grey,
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String text;
  final IconData icon;
  final Color color;

  const _Pill({required this.text, required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    // Responsive pill that wraps to next line when needed
    return ConstrainedBox(
      constraints: BoxConstraints(
        // Cap pill width so it can wrap if text is long
        maxWidth: MediaQuery.of(context).size.width * 0.80,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: color.withOpacity(.10),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withOpacity(.28)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                text,
                style: TextStyle(color: color, fontWeight: FontWeight.w600),
                softWrap: true,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// buying_history_page.dart — Part 2 of 2
// (Continue pasting right after the _Pill widget from Part 1)

class _ChannelFilter extends StatelessWidget {
  final String value;
  // Nullable per DropdownButton onChanged signature
  final ValueChanged<String?> onChanged;

  const _ChannelFilter({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        value: value,
        items: const [
          DropdownMenuItem(value: 'All', child: Text('All')),
          DropdownMenuItem(value: 'Online', child: Text('Online')),
          DropdownMenuItem(value: 'Physical', child: Text('Physical')),
        ],
        onChanged: onChanged,
      ),
    );
  }
}

class _SortMenu extends StatelessWidget {
  final String value;
  // Nullable per DropdownButton onChanged signature
  final ValueChanged<String?> onChanged;

  const _SortMenu({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        value: value,
        items: const [
          DropdownMenuItem(value: 'Newest', child: Text('Newest')),
          DropdownMenuItem(value: 'Oldest', child: Text('Oldest')),
          DropdownMenuItem(value: 'Price ↑', child: Text('Price ↑')),
          DropdownMenuItem(value: 'Price ↓', child: Text('Price ↓')),
        ],
        onChanged: onChanged,
      ),
    );
  }
}

class _LoadingState extends StatelessWidget {
  const _LoadingState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24.0),
        child: CircularProgressIndicator(),
      ),
    );
  }
}

class _ErrorWithRetry extends StatelessWidget {
  final Future<void> Function() onRetry;

  const _ErrorWithRetry({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 80),
        Icon(Icons.wifi_off, size: 52, color: Colors.red.shade400),
        const SizedBox(height: 12),
        const Center(
          child: Text(
            'Couldn’t load history',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(height: 8),
        const Center(child: Text('Check your connection or pull to refresh.')),
        const SizedBox(height: 16),
        Center(
          child: OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        ),
      ],
    );
  }
}

/// -------------------------
/// Models
/// -------------------------
class Purchase {
  final String userId;
  String productName; // Removed final
  String brand;       // Removed final
  final String store;
  final double price;
  final DateTime purchasedAt;
  final String? itemId;
  String? quantity;    // Removed final
  final String? channel;
  final String? shopAddress;
  final String? chainShopId;
  final String? rawItemName;
  String? rawFeature;  // Removed final
  final String? rawItemNo;
  final String? discountType;

  Purchase({
    required this.userId,
    required this.productName,
    required this.brand,
    required this.store,
    required this.price,
    required this.purchasedAt,
    this.itemId,
    this.quantity,
    this.channel,
    this.shopAddress,
    this.chainShopId,
    this.rawItemName,
    this.rawFeature,
    this.rawItemNo,
    this.discountType,
  });
}


// UPDATE: enrich Alternative so UI can show channel, discount, shopId, address
class Alternative {
  final String productName;
  final String brand;
  final String store;
  final double price;

  // NEW: richer metadata for display
  final String? quantity;       // e.g., "1000ml"
  final String? feature;        // e.g., "organic", "mature"
  final double? ppu;            // normalized price-per-unit, e.g., £/ml or £/g
  final String? itemId;         // catalog item id (if known)

  // Existing optional fields (unchanged)
  final String? channel;        // "online" | "Physical"
  final String? discountType;   // "discount applied"
  final String? discountWhat;   // "clubcard", "multibuy 2 for £4"
  final String? shopId;
  final String? shopAddress;

  const Alternative({
    required this.productName,
    required this.brand,
    required this.store,
    required this.price,
    this.quantity,
    this.feature,
    this.ppu,
    this.itemId,
    this.channel,
    this.discountType,
    this.discountWhat,
    this.shopId,
    this.shopAddress,
  });
}


// 1) Add this small model near your other models (e.g., under `class Alternative`)
class ItemCatalogEntry {
  final String id;
  final String name;
  final String brand;
  final String? quantity;
  final String? feature;
  final String? picWebsite;

  const ItemCatalogEntry({
    required this.id,
    required this.name,
    required this.brand,
    this.quantity,
    this.feature,
    this.picWebsite,
  });

  factory ItemCatalogEntry.fromJson(Map<String, dynamic> r) {
    String _asStr(dynamic v) => (v == null) ? '' : (v is String ? v : v.toString());
    return ItemCatalogEntry(
      id: _asStr(r['id']),
      name: _asStr(r['name']),
      brand: _asStr(r['brand']),
      quantity: _asStr(r['quantity']).isEmpty ? null : _asStr(r['quantity']),
      feature: _asStr(r['feature']).isEmpty ? null : _asStr(r['feature']),
      picWebsite: _asStr(r['picWebsite']).isEmpty ? null : _asStr(r['picWebsite']),
    );
  }
}


// NEW: Model for one row from /api/prices
class PriceEntry {
  final String id;
  final String itemId;       // itemID
  final String channel;      // "online" | "in-store" (as per API)
  final String shopCode;     // shopCD (e.g., "tesco", "asda")
  final String shopId;       // shopID (may be empty)
  final String shopAddress;  // shopAdd (may be empty)
  final DateTime? date;      // parsed
  final double normalPrice;
  final double discountPrice;
  final String discountWhat; // e.g., "clubcard", "timed recommendation"

  PriceEntry({
    required this.id,
    required this.itemId,
    required this.channel,
    required this.shopCode,
    required this.shopId,
    required this.shopAddress,
    required this.date,
    required this.normalPrice,
    required this.discountPrice,
    required this.discountWhat,
  });

  bool get hasDiscount => discountPrice > 0 && discountPrice < normalPrice;
  double get effectivePrice {
    if (discountPrice > 0 && discountPrice < normalPrice) return discountPrice;
    return (normalPrice > 0) ? normalPrice : discountPrice;
  }

  factory PriceEntry.fromJson(Map<String, dynamic> r) {
    String s(dynamic v) => v == null ? '' : (v is String ? v : v.toString());
    double d(dynamic v) {
      if (v == null) return 0.0;
      if (v is num) return v.toDouble();
      final t = v.toString().trim();
      return double.tryParse(t) ?? 0.0;
    }

    // The feed you showed contains keys like: id, channel, itemID, shopCD, shopID,
    // date, normalPrice, discountPrice, shopAdd, discountEnd/discountCond/etc.
    // We'll read a few variations safely.
    // We explicitly check discountCond first as seen in your API response
    final discountRaw = s(r['discountCond'] ?? r['discountWhat'] ?? r['discountEnd'] ?? '');
    
    return PriceEntry(
      id: s(r['id']),
      itemId: s(r['itemID']),
      channel: s(r['channel']),
      shopCode: s(r['shopCD']),
      shopId: s(r['shopID']),
      shopAddress: s(r['shopAdd']),
      date: _asDateTime(r['date']),
      normalPrice: d(r['normalPrice']),
      discountPrice: d(r['discountPrice']),
      discountWhat: discountRaw,
    );
  }
}


/// -------------------------
/// Mock data (for fallback/offline demo)
/// -------------------------
/// CHANGE THIS TO MATCH YOUR REAL USERID FOR TESTING!
final List<Purchase> _mockPurchases = <Purchase>[
  Purchase(
    userId: 'user123', // <-- UPDATE THIS if you use mock fallback
    productName: 'Semi Skimmed Milk 2L',
    brand: 'Brand A',
    store: 'Store X',
    price: 1.95,
    purchasedAt: DateTime.now().subtract(const Duration(days: 1)),
    quantity: '2L',
    channel: 'Physical',
    shopAddress: '123 Demo Road, Bristol',
    //discountType: 'Loyalty Card Price',
  ),
];

final Map<String, List<Alternative>> _mockAlternatives = {
  'semi skimmed milk 2l': [
    Alternative(
      productName: 'Semi Skimmed Milk 2L',
      brand: 'Store Own',
      store: 'Store X',
      price: 1.65,
    ),
  ],
  'bananas 1kg': [
    Alternative(
      productName: 'Bananas 1kg',
      brand: 'Store Own',
      store: 'Tesco',
      price: 0.79,
    ),
  ],
  'brown bread — wholemeal 800g': [
    Alternative(
      productName: 'Wholemeal Bread 800g',
      brand: 'Store Own',
      store: 'ASDA',
      price: 1.05,
    ),
  ],
  'cheddar cheese 400g — mature': [
    Alternative(
      productName: 'Cheddar 400g — Mature',
      brand: 'Store Own',
      store: 'Sainsbury’s',
      price: 3.00,
    ),
  ],
};

Alternative? _findCheaperAlternative(Purchase purchase) {
  final key = purchase.productName.toLowerCase().trim();
  final candidates = _mockAlternatives[key];
  if (candidates == null || candidates.isEmpty) return null;

  final sorted = [...candidates]..sort((a, b) => a.price.compareTo(b.price));
  for (final c in sorted) {
    if (c.price < purchase.price) return c;
  }
  return null;
}

String _formatSaving(double saving) {
  if (saving <= 0) return 'no';
  return '£${saving.toStringAsFixed(2)}';
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.history, size: 48, color: Colors.grey.shade500),
            const SizedBox(height: 12),
            const Text(
              'No purchases yet',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            const Text(
              'Once you add purchases via the Input tab, your history and cheaper alternatives will appear here.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/// -------------------------
/// Helpers
/// -------------------------
String _asString(dynamic v) {
  if (v == null) return '';
  if (v is String) return v;
  return v.toString();
}

double _asDouble(dynamic v) {
  if (v == null) return 0.0;
  if (v is num) return v.toDouble();
  final s = v.toString().trim();
  if (s.isEmpty) return 0.0;
  return double.tryParse(s) ?? 0.0;
}

DateTime? _asDateTime(dynamic v) {
  if (v == null) return null;
  if (v is DateTime) return v;

  final s = v.toString().trim();

  // 1) Try ISO8601 (e.g., 2026-02-23T20:07:59Z)
  try {
    // Also handle MySQL "YYYY-MM-DD HH:mm:ss" by inserting 'T'
    if (s.contains(' ') && RegExp(r'^\d{4}-\d{2}-\d{2} ').hasMatch(s)) {
      final iso = s.replaceFirst(' ', 'T');
      return DateTime.parse(iso);
    }
    return DateTime.parse(s);
  } catch (_) {
    // 2) Try JavaScript Date string:
    // "Fri Feb 27 2026 02:25:06 GMT+0000 (Coordinated Universal Time)"
    final js = _parseJsDate(s);
    if (js != null) return js;
  }

  // 3) Give up
  return null;
}

DateTime? _parseJsDate(String s) {
  // Expect: Ddd Mon DD YYYY HH:mm:ss GMT+HHMM (...)
  final re = RegExp(
    r'^\w{3}\s+(\w{3})\s+(\d{1,2})\s+(\d{4})\s+'
    r'(\d{2}):(\d{2}):(\d{2})\s+GMT([+\-]\d{4})',
  );
  final m = re.firstMatch(s);
  if (m == null) return null;

  const months = {
    'Jan': 1,
    'Feb': 2,
    'Mar': 3,
    'Apr': 4,
    'May': 5,
    'Jun': 6,
    'Jul': 7,
    'Aug': 8,
    'Sep': 9,
    'Oct': 10,
    'Nov': 11,
    'Dec': 12,
  };

  final monthName = m.group(1)!;
  final month = months[monthName];
  if (month == null) return null;

  final day = int.parse(m.group(2)!);
  final year = int.parse(m.group(3)!);
  final hh = int.parse(m.group(4)!);
  final mm = int.parse(m.group(5)!);
  final ss = int.parse(m.group(6)!);

  final offsetRaw = m.group(7)!; // e.g., +0000, +0100, -0700
  final sign = offsetRaw.startsWith('-') ? -1 : 1;
  final offHours = int.parse(offsetRaw.substring(1, 3));
  final offMins = int.parse(offsetRaw.substring(3, 5));
  final totalOffsetMinutes = sign * (offHours * 60 + offMins);

  // Build as UTC instant: localTime - offset
  final dtUtc = DateTime.utc(year, month, day, hh, mm, ss)
      .subtract(Duration(minutes: totalOffsetMinutes));

  // Return as UTC or local? The simple formatter doesn't show TZ,
  // returning UTC keeps displayed clock equal to GMT time when offset is +0000.
  return dtUtc; // use dtUtc.toLocal() if you prefer device-local times
}

String _formatDateTime(DateTime dt) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
}

String _nameKey(String s) {
  return s
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

String _composeTitle(String itemName, String feature, String quantity) {
  final parts = <String>[];
  if (itemName.isNotEmpty) parts.add(itemName);
  if (feature.isNotEmpty && feature.toLowerCase() != 'null') parts.add(feature);
  final title = parts.join(' — ');
  if (quantity.isNotEmpty) return '$title ($quantity)';
  return title;
}


// -------------------------
// Similar-product suggestion helpers
// -------------------------

/// Normalize product name into a "family" (e.g., "ice cream", "yogurt")
/// and infer flavor tokens (e.g., "mango", "strawberry", "chocolate").
class _ProductFamily {
  final String family;      // e.g., "ice cream"
  final Set<String> flavors; // e.g., {"mango"}
  _ProductFamily(this.family, this.flavors);
}

/// Very small list of flavor-ish words to detect.
/// (Extend as needed; kept small to avoid false positives.)
const Set<String> _kFlavorWords = {
  'vanilla','chocolate','strawberry','mango','banana','honey','mint',
  'caramel','cookie','berry','blueberry','raspberry','lemon','peach',
};

/// Words to remove when extracting "family" (containers, sizes, etc.).
const Set<String> _kStopWords = {
  'with','and','the','of','in','a','an','—','-', 'for',
  // pack/size words (we strip them; size is handled in quantity parsing):
  'ml','l','g','kg','x','pack','tub','cup','cone','bar',
};

/// Quick n-gram based family extractor.
/// Example:
///   name:  "Mango Ice Cream"
///   brand: "Tesco"
///   feature:"500ml"
/// -> family ~ "ice cream", flavors={"mango"}
_ProductFamily _familyFromNameBrandFeature({
  required String name,
  String brand = '',
  String feature = '',
}) {
  String clean(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  final tokens = {
    ...clean(name).split(' '),
    ...clean(feature).split(' '),
  }..removeWhere((t) => t.isEmpty || _kStopWords.contains(t));

  final flavors = tokens.where(_kFlavorWords.contains).toSet();

  // naive heuristic: look for a bigram that sounds like a product family
  // prefer "ice cream", "greek yogurt", "instant noodles", etc.
  String? family;
  final list = tokens.toList();
  for (int i = 0; i < list.length; i++) {
    final t = list[i];
    final next = (i + 1 < list.length) ? list[i + 1] : null;
    final bigram = (next != null) ? '$t $next' : null;

    // common families you likely have
    if (bigram == 'ice cream' ||
        bigram == 'greek yogurt' ||
        bigram == 'instant noodles' ||
        bigram == 'canned soup' ||
        bigram == 'bin bags' ||
        bigram == 'brown bread' ||
        bigram == 'basmati rice') {
      family = bigram!;
      break;
    }
    // fallback: single token families
    if (t == 'yogurt' || t == 'rice' || t == 'noodles' || t == 'bread' || t == 'cheddar') {
      family = t;
    }
  }
  family ??= list.join(' '); // last resort, still stable-ish

  return _ProductFamily(family, flavors);
}

/// Parse "quantity" (e.g., "500ml", "1L", "4x90ml", "1kg", "12 eggs")
/// Return a normalized (value, unit) where unit ∈ {"ml","g","pcs"}.
/// If cannot parse, returns (1, "pcs") to avoid division by zero.
({double value, String unit}) _parseQuantityToUnit(String? quantity) {
  if (quantity == null || quantity.trim().isEmpty) return (value: 1.0, unit: 'pcs');
  final q = quantity.trim().toLowerCase();

  // handle packs like "4x90ml" / "6 x 100 g"
  final packRe = RegExp(r'(\d+)\s*[x×]\s*(\d+(\.\d+)?)\s*(ml|l|g|kg|pcs|pieces|eggs)');
  final mPack = packRe.firstMatch(q);
  if (mPack != null) {
    final count = double.tryParse(mPack.group(1)!) ?? 1.0;
    final each = double.tryParse(mPack.group(2)!) ?? 0.0;
    final u = mPack.group(4)!;
    final normalized = _toBase(each, u);
    return (value: count * normalized.value, unit: normalized.unit);
  }

  // single value like "500ml" | "1l" | "700 g" | "12 eggs"
  final singleRe = RegExp(r'(\d+(\.\d+)?)\s*(ml|l|g|kg|pcs|pieces|eggs)');
  final mSingle = singleRe.firstMatch(q);
  if (mSingle != null) {
    final v = double.tryParse(mSingle.group(1)!) ?? 1.0;
    final u = mSingle.group(3)!;
    return _toBase(v, u);
  }

  // bare number means pieces:
  final pcsRe = RegExp(r'^\s*(\d+)\s*(pcs|pieces|eggs)?\s*$');
  final mPcs = pcsRe.firstMatch(q);
  if (mPcs != null) {
    final v = double.tryParse(mPcs.group(1)!) ?? 1.0;
    return (value: v, unit: 'pcs');
  }

  return (value: 1.0, unit: 'pcs');
}

({double value, String unit}) _toBase(double v, String unit) {
  switch (unit) {
    case 'l':
      return (value: v * 1000.0, unit: 'ml');
    case 'kg':
      return (value: v * 1000.0, unit: 'g');
    case 'ml':
    case 'g':
      return (value: v, unit: unit);
    case 'pcs':
    case 'pieces':
    case 'eggs':
      return (value: v, unit: 'pcs');
    default:
      return (value: v, unit: 'pcs');
  }
}

/// Compute price per unit (ml/g/pcs). If units mismatch, returns +inf.
double _pricePerUnit({
  required double price,
  required String? quantity,
  required String? fallbackQuantity,
}) {
  final a = _parseQuantityToUnit(quantity);
  final b = _parseQuantityToUnit(fallbackQuantity);
  // prefer explicit quantity (from purchase) over catalog
  final q = (quantity != null && quantity.isNotEmpty) ? a : b;
  if (q.value <= 0) return double.infinity;
  return price / q.value;
}