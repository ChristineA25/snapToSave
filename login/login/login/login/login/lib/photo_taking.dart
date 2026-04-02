// -----------------------------------------------------------------------------
// photo_taking.dart — with price insertion, discount condition capture,
// existence checks, and confirmation popup per-row (Part 1/3)
// -----------------------------------------------------------------------------
// - All fields required except Brand (optional).
// - Quantity: integers only.
// - Price: valid GBP (int/decimal) with/without £, max 2 dp.
// - Brand, Item, Source, Shop name: capped at 65,535 characters.
// - Address: chosen from map; field is read-only.
// - NEW (this update):
//   * Before inserting price rows, we search if the price exists (same itemID,
//     shopID, channel, date in GMT). If it exists, we skip insertion.
//   * We show a confirmation popup with all input details, and if Discount is ON,
//     we ask for the discount condition and insert it as discountCond.
//   * If Discount is ON, the value is saved to discountPrice (normalPrice=null);
//     otherwise to normalPrice (discountPrice=null).
//   * Date saved as today's UTC date (YYYY-MM-DD).
//   * shopAdd = Physical shop address from form (null for Online).
//   * Enforce 65,535 max chars for all free text inputs and dialog field.
// - FIX: Manual-input (no photo) loader parity with textless/screenshot extras.
// - FIX: No writes to the items/shops/prices backend before Submit.
//
// NOTE: This is Part 1/3 (imports, state, loaders, detection, ranking).
//       Submit/price-insert logic and dialog callouts appear in Part 2/3 & 3/3.
// -----------------------------------------------------------------------------

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_image_gallery_saver/flutter_image_gallery_saver.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:palette_generator/palette_generator.dart';
import 'package:http/http.dart' as http;

// ML Kit
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';

// Backend services
import 'brand_service.dart';
import 'item_service.dart';
import 'shop_service.dart';
import 'item_submit_service.dart';
import 'item_resolver_service.dart';

// Price service + discount confirmation dialog (NEW)
import 'services/price_service.dart';
import 'widgets/discount_summary_dialog.dart';

// Map picker
import 'map_picker/place.dart';
import 'map_picker/map_search_screen.dart';

// Validation helpers
import 'form_validators.dart';
import 'utils/shop_normalizer.dart' as sn;

import 'services/item_input_service.dart';     // <-- ADD THIS

// ADD with other imports
import 'services/chain_shop_service.dart';

import 'buying_history_page.dart';

import 'package:dropdown_search/dropdown_search.dart';

class CaptureAndRecognizePage extends StatefulWidget {
  const CaptureAndRecognizePage({
    super.key,
    required this.title,
    required this.userId,     // NEW
  });

  final String title;
  final String userId;        // NEW

  @override
  State<CaptureAndRecognizePage> createState() => _CaptureAndRecognizePageState();
}

// Custom user column model
class CustomColumn {
  final String id;
  String name;
  final Map<int, String> values; // rowIndex -> value
  CustomColumn({
    required this.id,
    required this.name,
    Map<int, String>? values,
  }) : values = values ?? {};
}

class _CaptureAndRecognizePageState extends State<CaptureAndRecognizePage> {
  // ---------------------------------------------------------------------------
  // CORE STATE
  // ---------------------------------------------------------------------------
  final ImagePicker _picker = ImagePicker();
  File? _imageFile;
  List<Map<String, dynamic>> _labels = [];
  Database? _db;
  bool _isBusy = false;
  bool _manualMode = false;
  bool _optionsBusy = false;
  bool get _noPhoto => _imageFile == null;

  // ---------------------------------------------------------------------------
  // ML KIT DETECTORS
  // ---------------------------------------------------------------------------
  late final ObjectDetector _objectDetector;
  late final TextRecognizer _textRecognizer;
  late final ImageLabeler _imageLabeler;

  // ---------------------------------------------------------------------------
  // PER-ROW FIELDS
  // ---------------------------------------------------------------------------
  final Map<int, String> _rowPrices = {};
  final Map<int, String> _rowBrands = {};
  final Map<int, String> _rowItems = {};
  final Map<int, String> _rowChannels = {};
  final Map<int, String> _rowSources = {};
  final Map<int, String> _rowItemIds = {}; // resolved product ID
  final Map<int, String> _rowQty = {}; // quantity number (integer/decimal as text)
  final Map<int, String> _rowQtyUnit = {}; // quantity unit
  final Map<int, bool> _rowDiscount = {}; // discount on/off
  final Map<int, String> _rowFeatures = {}; // feature entered by user
  // NEW: Item quantity (count of units) — integer-only, defaults to 1
  final Map<int, String> _rowItemCounts = {};

  // ---- State for category (ADD if missing) ----
  final Map<int, String> _rowCategories = {}; // selected category per row

  List<String> _categoryOptions = [];
  String? _categoryLoadError;

  // ---------------------------------------------------------------------------
  // MAP-PICKED SHOP INFO
  // ---------------------------------------------------------------------------
  final Map<int, String> _rowShopNames = {};
  final Map<int, String> _rowShopAddresses = {};
  final Map<int, double> _rowShopLat = {};
  final Map<int, double> _rowShopLng = {};
  final Map<int, TextEditingController> _shopNameCtrls = {};

  // Custom columns (optional)
  final List<CustomColumn> _customColumns = [];

  // Controllers — one per row for Source (address) field
  final Map<int, TextEditingController> _sourceCtrls = {};

  // Pending shops chosen in Physical/Online that we will persist/ensure on submit.
  final Set<String> _pendingShopsToSave = <String>{};

  // ---------------------------------------------------------------------------
  // DROPDOWN OPTIONS
  // ---------------------------------------------------------------------------
  List<String> _brandOptions = [];
  String? _brandLoadError;

  List<String> _itemOptions = [];
  String? _itemLoadError;

  List<String> _shopOptions = [];
  String? _shopLoadError;

  static const List<String> _channelOptions = [
    'Online',
    'Physical',
  ];

  static const List<String> _qtyUnits = [
    'pcs',
    'kg',
    'g',
    'L',
    'ml',
    'pack',
  ];

  // ---------------------------------------------------------------------------
  // BACKEND ENDPOINTS
  // ---------------------------------------------------------------------------
  static const String _gPlacesApiKey =
      String.fromEnvironment('G_PLACES_API_KEY', defaultValue: '');
  static const String _baseUrl = 'https://nodejs-production-53a4.up.railway.app/';

  final _brandService = BrandService(_baseUrl);
  final _itemService = ItemService(_baseUrl);
  final _shopService = ShopService(_baseUrl);
  final _submitService = ItemSubmitService(_baseUrl);
  final _resolverService = ItemResolverService(_baseUrl);

  // NEW: Price Service
  final _priceService = PriceService(_baseUrl); // uses /api/prices endpoints
  final _itemInputService = ItemInputService(_baseUrl);   // <-- ADD THIS

  // ADD with other services (uses same _baseUrl)  [1](https://uweacuk-my.sharepoint.com/personal/ka4_au_live_uwe_ac_uk/Documents/Microsoft%20Copilot%20Chat%20Files/form_validators.dart)
  final _chainShopService = ChainShopService(_baseUrl);

  // Existing resolver: brand + item
  Uri get _resolverUri => Uri.parse('$_baseUrl' 'api/items/resolve');
  // NEW: item-only resolver (brand optional)
  Uri get _resolverByItemUri => Uri.parse('$_baseUrl/api/item/resolve-by-item');

  // Add near your other backend URIs
  Uri get _shopsAddUri => Uri.parse('$_baseUrl/shops/add');

  // ---------------------------------------------------------------------------
  // IMAGE GEOMETRY & COLOR ANALYSIS
  // ---------------------------------------------------------------------------
  Size? _imagePixelSize;
  final ScrollController _hScrollCtrl = ScrollController();

  Set<String> _photoColorTokens = <String>{};
  Map<String, List<String>> _itemColorsTextless = {};
  Map<String, List<String>> _itemColorsPrices = {};

  // ---------------------------------------------------------------------------
  // CACHES
  // ---------------------------------------------------------------------------
  List<String>? _pricesCache;
  String? _aggOcrCache;
  int _optionsVersion = 0;
  void _invalidateDerivedCaches() {
    _pricesCache = null;
    _aggOcrCache = null;
  }

  void _debugShowItemInputPayload(Map<String, dynamic> payload) {
    final pretty = const JsonEncoder.withIndent('  ').convert(payload);
    debugPrint("ITEM-INPUT PAYLOAD:\n$pretty");

    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: SingleChildScrollView(
            child: Text(
              pretty,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ),
      ),
    );
  }


  // Quantity preview cache per row
  final Map<int, List<String>> _rowQtyPreview = {};

  // ---------------------------------------------------------------------------
  // MAP PICKER
  // ---------------------------------------------------------------------------
  Future<Place?> _pickShopFromMap() async {
    return Navigator.push<Place>(
      context,
      MaterialPageRoute(builder: (_) => const MapSearchScreen()),
    );
  }

  // ---------------------------------------------------------------------------
  // LIFECYCLE, DATABASE, DETECTORS, DROPDOWN LOADERS, REFRESHERS
  // ---------------------------------------------------------------------------
  @override
  void initState() {
    super.initState();
    _initDb();
    _initDetectors();
    _ensureDropdownOptionsLoaded();
  }

  @override
  void dispose() {
    _hScrollCtrl.dispose();
    for (final c in _sourceCtrls.values) {
      c.dispose();
    }
    for (final c in _shopNameCtrls.values) {
      c.dispose();
    }
    _objectDetector.close();
    _textRecognizer.close();
    _imageLabeler.close();
    super.dispose();
  }

  // ---------------------------------- DB -------------------------------------
  Future<void> _initDb() async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, 'photobook.db');
    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE photos (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            file_path TEXT NOT NULL,
            taken_at INTEGER NOT NULL,
            labels_json TEXT
          )
        ''');
      },
    );
  }

  Future<void> _insertRow(File file, List<Map<String, dynamic>> labels) async {
    if (_db == null) return;
    await _db!.insert('photos', {
      'file_path': file.path,
      'taken_at': DateTime.now().millisecondsSinceEpoch,
      'labels_json': jsonEncode(labels),
    });
    if (mounted) setState(() {});
  }

  // ------------------------------ DETECTORS -----------------------------------
  void _initDetectors() {
    _objectDetector = ObjectDetector(
      options: ObjectDetectorOptions(
        mode: DetectionMode.single,
        classifyObjects: true,
        multipleObjects: true,
      ),
    );
    _textRecognizer = TextRecognizer();
    _imageLabeler = ImageLabeler(
      options: ImageLabelerOptions(
        confidenceThreshold: 0.30,
      ),
    );
  }

  // ------------------------------ DROPDOWN LOADERS ----------------------------
  Future<void> _loadShopOptions() async {
    if (mounted) setState(() => _shopLoadError = null);
    try {
      final shops = await _shopService.fetchShops();
      if (!mounted) return;
      setState(() {
        _shopOptions = shops;
        _shopLoadError = null;
        _optionsVersion++;
        _invalidateDerivedCaches();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _shopLoadError = 'Failed to load shop options: $e';
        _shopOptions = [];
        _optionsVersion++;
        _invalidateDerivedCaches();
      });
    }
  }
  
  // ------------------------------ CATEGORY DROPDOWN LOADER (UPDATED) --------------------
  Future<void> _loadCategoryOptions() async {
    if (mounted) setState(() => _categoryLoadError = null);

    // Local helper to collect category tokens from an endpoint that returns:
    // { "count": N, "rows": [ { "category": "a, b, c", ... }, ... ] }
    Future<Set<String>> _tokensFromRowsEndpoint(Uri uri) async {
      final out = <String>{};
      final resp = await http.get(uri);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw Exception('HTTP ${resp.statusCode}: ${resp.body}');
      }
      final map = jsonDecode(resp.body) as Map<String, dynamic>;
      final rows = (map['rows'] ?? const []) as List;
      for (final r in rows) {
        final catStr = (r is Map ? (r['category'] ?? '') : '').toString();
        if (catStr.trim().isEmpty) continue;
        for (final raw in catStr.split(',')) {
          final t = raw.trim();
          if (t.isEmpty) continue;
          out.add(t); // keep literal token for nicer display
        }
      }
      return out;
    }

    try {
      // A) Existing source in your codebase: /api/item-input/item-color4/all
      final uriA = Uri.parse('${_baseUrl}api/item-input/item-color4/all');

      // B) New source from your screenshot: /item-input  (adjust to `${_baseUrl}api/item-input`
      //    if your routes are mounted under /api)
      final uriB = Uri.parse('${_baseUrl}item-input');

      // Fetch in parallel
      final results = await Future.wait<Set<String>>([
        _tokensFromRowsEndpoint(uriA),
        _tokensFromRowsEndpoint(uriB),
      ]);

      // Merge: existing choices already present in the UI + fetched tokens
      final merged = <String>{..._categoryOptions, ...results[0], ...results[1]};

      // Sort case-insensitively but keep original token text for display
      final list = merged.toList()
        ..sort((x, y) => x.toLowerCase().compareTo(y.toLowerCase()));

      if (!mounted) return;
      setState(() {
        _categoryOptions = list;
        _categoryLoadError = null;
        _optionsVersion++;
        _invalidateDerivedCaches();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _categoryLoadError = 'Failed to load categories: $e';
        // Keep whatever categories were already available instead of wiping them.
        // If you prefer to reset to [], replace the next line with: _categoryOptions = [];
        _optionsVersion++;
        _invalidateDerivedCaches();
      });
    }
  }

  Future<void> _loadBrandOptions() async {
    if (mounted) setState(() => _brandLoadError = null);
    try {
      final brands = await _brandService.fetchBrands();
      if (!mounted) return;
      setState(() {
        _brandOptions = brands.where((b) => b.trim().isNotEmpty).toList();
        _brandLoadError = null;
        _optionsVersion++;
        _invalidateDerivedCaches();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _brandLoadError = 'Failed to load brand options: $e';
        _brandOptions = [];
        _optionsVersion++;
        _invalidateDerivedCaches();
      });
    }
  }

  Future<void> _loadScreenshotItemOptions() async {
    try {
      final items = await _itemService.fetchScreenshotItems();
      if (!mounted) return;
      setState(() {
        final combined = {..._itemOptions, ...items}.toList();
        _itemOptions = combined.where((i) => i.trim().isNotEmpty).toList()
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      });
    } catch (e) {
      debugPrint("Failed to load screenshot items: $e");
    }
  }

  Future<void> _loadItemOptions({Map<String, String>? filters}) async {
    if (mounted) setState(() => _itemLoadError = null);
    try {
      final items = await _itemService.fetchItems(filters: filters);
      if (!mounted) return;
      setState(() {
        _itemOptions = items.where((i) => i.trim().isNotEmpty).toList();
        _itemLoadError = null;
        _optionsVersion++;
        _invalidateDerivedCaches();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _itemLoadError = 'Failed to load item options: $e';
        _itemOptions = [];
        _optionsVersion++;
        _invalidateDerivedCaches();
      });
    }
  }

  Future<void> _loadTextlessItemExtras() async {
    try {
      final extras = await _itemService.fetchItemsForTextless();
      if (!mounted) return;
      setState(() {
        final combined = {..._itemOptions, ...extras};
        _itemOptions = combined.where((i) => i.trim().isNotEmpty).toList()
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
        _optionsVersion++;
        _invalidateDerivedCaches();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _itemLoadError = 'Failed to load textless extras: $e');
    }
  }

  // NEW: When in manual/no-photo mode we always merge in textless & screenshot extras
  Future<void> _ensureManualItemBoosters() async {
    await Future.wait([
      _loadTextlessItemExtras(),
      _loadScreenshotItemOptions(),
    ]);
  }

  Future<void> _ensureDropdownOptionsLoaded() async {
    if (_optionsBusy || !mounted) return;
    setState(() => _optionsBusy = true);
    try {
      final futures = <Future<void>>[];
      if (_brandOptions.isEmpty) futures.add(_loadBrandOptions());
      if (_itemOptions.isEmpty) {
        futures.add(_loadItemOptions());
      }
      // Always load shop options if empty
      if (_shopOptions.isEmpty) futures.add(_loadShopOptions());
      if (_categoryOptions.isEmpty) futures.add(_loadCategoryOptions()); 
      await Future.wait(futures);

      // IMPORTANT: If there is no photo (manual entry), mirror the "textless" richness
      // so the item dropdown matches textless-photo behavior.
      if (_noPhoto) {
        await _ensureManualItemBoosters();
      }
    } finally {
      if (mounted) setState(() => _optionsBusy = false);
    }
  }

  Future<void> _reloadAllItemOptions() async {
    if (!mounted) return;
    setState(() {
      _itemOptions = [];
      _itemLoadError = null;
      _optionsVersion++;
      _invalidateDerivedCaches();
    });
    await _loadItemOptions();
    await _loadTextlessItemExtras();
    await _loadScreenshotItemOptions();
  }

  Future<void> _refreshAllDropdowns() async {
    if (_optionsBusy || !mounted) return;
    setState(() => _optionsBusy = true);
    try {
      await Future.wait([
        _loadBrandOptions(),
        _reloadAllItemOptions(),
        _loadCategoryOptions(),
      ]);
      // Keep parity for manual/no-photo mode as well
      if (_noPhoto) {
        await _ensureManualItemBoosters();
      }
    } finally {
      if (mounted) setState(() => _optionsBusy = false);
    }
  }

  void _refreshPriceColumn() {
    setState(() {
      _pricesCache = null;
    });
    Future.delayed(const Duration(milliseconds: 200), () {
      if (!mounted) return;
      setState(() {});
    });
  }

  // ------------------------------ IMAGE HELPERS -------------------------------
  Future<void> _loadImagePixelSize(File file) async {
    try {
      final bytes = await file.readAsBytes();
      final completer = Completer<ui.Image>();
      ui.decodeImageFromList(bytes, (img) => completer.complete(img));
      final img = await completer.future;
      if (!mounted) return;
      setState(() {
        _imagePixelSize = Size(img.width.toDouble(), img.height.toDouble());
      });
    } catch (e) {
      debugPrint('Failed to read image pixel size: $e');
    }
  }

  Future<void> _computePhotoColorTokens(File imageFile) async {
    try {
      final pal = await PaletteGenerator.fromImageProvider(
        FileImage(imageFile),
        size: const Size(200, 200),
        maximumColorCount: 16,
      );
      final tokens = <String>{};
      final swatches = <PaletteColor>[
        if (pal.dominantColor != null) pal.dominantColor!,
        if (pal.vibrantColor != null) pal.vibrantColor!,
        if (pal.darkVibrantColor != null) pal.darkVibrantColor!,
        if (pal.lightVibrantColor != null) pal.lightVibrantColor!,
        if (pal.mutedColor != null) pal.mutedColor!,
        if (pal.darkMutedColor != null) pal.darkMutedColor!,
        if (pal.lightMutedColor != null) pal.lightMutedColor!,
        ...pal.colors.map((c) => PaletteColor(c, 1)),
      ];
      for (final s in swatches.take(16)) {
        tokens.add(_nameForColor(s.color));
      }
      if (!mounted) return;
      setState(() => _photoColorTokens = tokens);
    } catch (e) {
      debugPrint('Palette error: $e');
      if (!mounted) return;
      setState(() => _photoColorTokens = <String>{});
    }
  }

  String _nameForColor(Color c) {
    final hsl = HSLColor.fromColor(c);
    final h = hsl.hue;
    final s = hsl.saturation;
    final l = hsl.lightness;
    if (l >= 0.92) return 'white';
    if (l <= 0.08) return 'black';
    if (s <= 0.10) return 'grey';
    if (h < 20) return 'red';
    if (h < 50) return 'orange';
    if (h < 65) return 'yellow';
    if (h < 170) return 'green';
    if (h < 250) return 'blue';
    if (h < 290) return 'purple';
    if (h < 340) return 'pink';
    return 'brown';
  }

  // ------------------------------ CAMERA CAPTURE ------------------------------
  Future<void> _captureFromCamera() async {
    if (_isBusy) return;
    setState(() => _isBusy = true);
    try {
      final XFile? xfile = await _picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 90,
      );
      if (xfile == null) return;
      final file = File(xfile.path);
      if (!mounted) return;
      setState(() {
        _imageFile = file;
        _manualMode = false;
      });
      await _loadImagePixelSize(file);
      try {
        await ImageGallerySaver().saveFile(file.path);
      } catch (_) {}
      await _computePhotoColorTokens(file);
      await _analyzeOnDevice(file);
      await _insertRow(file, _labels);
    } catch (e) {
      debugPrint('Camera error: $e');
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  // ------------------------------ PICK FROM GALLERY ---------------------------
  Future<void> _pickFromGallery() async {
    if (_isBusy) return;
    setState(() => _isBusy = true);
    try {
      final XFile? xfile = await _picker.pickImage(source: ImageSource.gallery);
      if (xfile == null) return;
      final file = File(xfile.path);
      if (!mounted) return;
      setState(() {
        _imageFile = file;
        _manualMode = false;
      });
      await _loadImagePixelSize(file);
      await _computePhotoColorTokens(file);
      await _analyzeOnDevice(file);
      await _insertRow(file, _labels);
    } catch (e) {
      debugPrint('Gallery error: $e');
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  // ------------------------------ ANALYSIS PIPELINE ---------------------------
  Future<void> _analyzeOnDevice(File imageFile) async {
    try {
      final textF = _runTextRecognition(imageFile);
      final objF = _runObjectDetection(imageFile);
      final labF = _runImageLabeling(imageFile);

      final textBlocks = await textF;
      final objects = await objF;
      final labels = await labF;

      if (!mounted) return;
      setState(() {
        _labels = [...textBlocks, ...objects, ...labels];

        // clear row data
        _rowPrices.clear();
        _rowBrands.clear();
        _rowItems.clear();
        _rowChannels.clear();
        _rowItemIds.clear();
        _rowQty.clear();
        _rowQtyUnit.clear();
        _rowDiscount.clear();
        _rowFeatures.clear();
        _rowItemCounts.clear(); // NEW: clear item counts

        // clear shop data
        _rowShopNames.clear();
        _rowShopAddresses.clear();
        _rowShopLat.clear();
        _rowShopLng.clear();


        _pricesCache = null;
        _aggOcrCache = null;
      });

      await _loadColorMapsForMode();
      if (!_hasText()) {
        await _loadItemOptions();
        await _loadTextlessItemExtras();
      } else {
        await _loadItemOptions();
      }
    } catch (e) {
      debugPrint('analyzeOnDevice error: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Shop name normalization (map -> brand root)
  // ---------------------------------------------------------------------------
  /// Lightweight call to Places Text Search returning top display names.
  /// If _gPlacesApiKey is empty or call fails, returns [].
  Future<List<String>> _placesTextSearchDisplayNames(String query) async {
    if (_gPlacesApiKey.isEmpty) return const <String>[];
    try {
      final url = Uri.parse('https://places.googleapis.com/v1/places:searchText');
      final resp = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'X-Goog-Api-Key': _gPlacesApiKey,
          // Minimal mask (displayName) keeps payload small & fast.
          // (displayName is an object -> we read .text below)
          'X-Goog-FieldMask': 'places.displayName',
        },
        body: jsonEncode({'textQuery': query}),
      );
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        final map = jsonDecode(resp.body) as Map<String, dynamic>;
        final List places = (map['places'] ?? []) as List;
        return places
            .map((p) => (((p as Map)['displayName'] ?? {}) as Map)['text'] ?? '')
            .map((s) => s.toString())
            .where((s) => s.isNotEmpty)
            .toList();
      }
    } catch (_) {
      // swallow; we fallback later
    }
    return const <String>[];
  }

  /// Prefix-based similarity. We only need a simple signal to detect a "drop".
  double _prefixMatchScore(String probe, String topName) {
    final q = probe.toLowerCase().trim();
    final t = topName.toLowerCase().trim();
    if (q.isEmpty || t.isEmpty) return 0.0;
    if (t.startsWith(q)) return q.length / t.length; // probe shorter
    if (q.startsWith(t)) return t.length / q.length; // top shorter
    return 0.0;
  }

  /// Try to deduce the brand root using Places Text Search by progressively
  /// trimming the trailing token and stopping when relevance would drop.
  /// Falls back to suffix stripping if API key is absent or results are empty.
  Future<String> _deduceOriginalShopName(String raw) async {
    if (raw.trim().isEmpty) return raw.trim();
    // First pass: cheap suffix-strip (helps even when API is available).
    String current = sn.stripCommonSuffixes(raw);
    String best = current;

    // If we don't have an API key, we're done with the fallback result.
    if (_gPlacesApiKey.isEmpty) return best;

    // Call once with the current string.
    List<String> topNow = await _placesTextSearchDisplayNames(current);
    double prevScore =
        topNow.isNotEmpty ? _prefixMatchScore(current, topNow.first) : 0.0;

    // Iteratively trim the last word while we don't see a big relevance drop.
    final toks = current.split(RegExp(r'\s+'));
    while (toks.length > 1) {
      toks.removeLast();
      final probe = toks.join(' ');
      final names = await _placesTextSearchDisplayNames(probe);
      final score = names.isNotEmpty ? _prefixMatchScore(probe, names.first) : 0.0;
      // If score drops noticeably vs the previous probe, stop and keep the last best.
      if (score + 0.15 < prevScore) {
        break;
      }
      best = probe;
      prevScore = score;
    }
    return best.trim().isEmpty ? raw.trim() : best.trim();
  }

  /// Centralized setter after returning from the map:
  /// - fills _rowShopNames/_rowShopAddresses/_rowShopLat/_rowShopLng
  /// - normalizes the shop name to its brand root
  /// - updates the controllers and prints to the VS Code terminal
  Future<void> _applyPickedPlaceToRow(int index, Place place) async {
    // Raw values from picker
    final rawName = place.name;
    final addr = place.formattedAddress.isNotEmpty
        ? place.formattedAddress
        : (place.postcode != null ? '${place.name}, ${place.postcode}' : place.name);

    // 1) Save raw first (so UI doesn't flicker)
    setState(() {
      _rowShopNames[index] = rawName;
      _rowShopAddresses[index] = addr;
      _rowShopLat[index] = place.lat;
      _rowShopLng[index] = place.lng;
    });

    // 2) Deduce brand root (may use API; otherwise suffix fallback)
    final original = await _deduceOriginalShopName(rawName);

    // 3) Update UI immediately so it feels instant
    setState(() {
      _rowShopNames[index] = original;
    });
    _shopNameCtrls[index]?.text = original;
    _sourceCtrls[index]?.text = _rowShopAddresses[index] ?? '';

    // 4) NEW: Do NOT save now. Mark for save-on-submit only.
    setState(() {
      if (original.trim().isNotEmpty) {
        _pendingShopsToSave.add(original.trim());
      }
    });

    debugPrint('Row ${index + 1}: Picked "$rawName" -> Original brand "$original"');
    print('Row ${index + 1}: Original shop name: $original');
  }

  // ------------------------------ ML TASKS ------------------------------------
  Future<List<Map<String, dynamic>>> _runObjectDetection(File imageFile) async {
    final input = InputImage.fromFile(imageFile);
    final detected = await _objectDetector.processImage(input);
    return detected.map((obj) {
      String title = 'object';
      double? conf;
      if (obj.labels.isNotEmpty) {
        title = obj.labels.first.text;
        conf = obj.labels.first.confidence;
      }
      return {
        'type': 'object',
        'description': title,
        'score': conf,
        'bbox': {
          'left': obj.boundingBox.left,
          'top': obj.boundingBox.top,
          'right': obj.boundingBox.right,
          'bottom': obj.boundingBox.bottom,
        }
      };
    }).toList();
  }

  Future<List<Map<String, dynamic>>> _runTextRecognition(File imageFile) async {
    final input = InputImage.fromFile(imageFile);
    final recognized = await _textRecognizer.processImage(input);
    return recognized.blocks.map((block) {
      return {
        'type': 'text',
        'description': block.text,
        'score': null,
        'bbox': {
          'left': block.boundingBox.left,
          'top': block.boundingBox.top,
          'right': block.boundingBox.right,
          'bottom': block.boundingBox.bottom,
        }
      };
    }).toList();
  }

  Future<List<Map<String, dynamic>>> _runImageLabeling(File imageFile) async {
    final input = InputImage.fromFile(imageFile);
    final labels = await _imageLabeler.processImage(input);
    return labels
        .map((l) => {
              'type': 'label',
              'description': l.label,
              'score': l.confidence,
              'bbox': null,
            })
        .toList();
  }

  // ------------------------------ OCR HELPERS ---------------------------------
  List<Map<String, dynamic>> _textLabelsOnly() =>
      _labels.where((l) => l['type'] == 'text').toList();

  bool _hasText() => _labels.any((l) => (l['type'] ?? '') == 'text');

  String _aggregateOcrText() {
    return _textLabelsOnly()
        .map((m) => (m['description'] ?? '').toString())
        .join(' ');
  }

  String _normalize(String s) {
    final lower = s.toLowerCase();
    final norm = lower
        .replaceAll(RegExp(r"[^\w\s]"), ' ')
        .replaceAll(RegExp(r"\s+"), ' ')
        .trim();
    return norm;
  }

  Set<String> _tokens(String s) => _normalize(s).split(' ').where((e) => e.isNotEmpty).toSet();

  // ------------------------------ PRICE EXTRACTION ----------------------------
  static final RegExp _priceRe = RegExp(
    r'\b(?:[\u00a3\$\€]\s*)?\d{1,3}(?:[.,]\d{3})*(?:[.,]\d{1,2})?\b',
    caseSensitive: false,
  );

  String _normalizePriceMatch(String raw) {
    var t = raw.replaceAll(RegExp(r'\s+'), '');
    final symbolMatch = RegExp(r'^[\u00a3\$\€]').firstMatch(t);
    final symbol = symbolMatch?.group(0) ?? '';
    var number = t.substring(symbol.length);

    if (number.contains(',') && number.contains('.')) {
      // both thousand and decimal separators exist - keep only the last as decimal
      final lastComma = number.lastIndexOf(',');
      final lastDot = number.lastIndexOf('.');
      final dec = math.max(lastComma, lastDot);
      final buf = StringBuffer();
      for (int i = 0; i < number.length; i++) {
        final ch = number[i];
        final isSep = ch == ',' || ch == '.' || ch == ' ';
        if (isSep && i != dec) continue;
        buf.write(ch);
      }
      number = buf.toString().replaceAll(',', '.');
    } else if (number.contains(',')) {
      if (RegExp(r',\d{1,2}$').hasMatch(number)) {
        number = number.replaceAll(',', '.');
      } else {
        number = number.replaceAll(',', '');
      }
    } else if (number.contains('.')) {
      if (!RegExp(r'\.\d{1,2}$').hasMatch(number)) {
        number = number.replaceAll('.', '');
      }
    }
    if (number.endsWith('.')) number = number.substring(0, number.length - 1);

    final v = double.tryParse(number);
    if (v == null || v <= 0 || v > 99999) return '';
    return symbol + number;
  }

  List<String> _extractPricesFromString(String text) {
    final list = LinkedHashSet<String>();
    for (final m in _priceRe.allMatches(text)) {
      final val = _normalizePriceMatch(m.group(0)!);
      if (val.isNotEmpty) list.add(val);
    }
    return list.toList();
  }

  List<String> _extractNumbersFromText() {
    final out = LinkedHashSet<String>();
    for (final block in _textLabelsOnly()) {
      final txt = (block['description'] ?? '').toString();
      for (final price in _extractPricesFromString(txt)) {
        out.add(price);
      }
    }
    return out.toList();
  }

  
  // ------------------------------ RESOLVER FLOW -------------------------------
  Future<Map<String, dynamic>> _resolveAgainstServer({
    required String brand,
    required String item,
    double? qtyValue,
    String? qtyUnit,
  }) async {
    final body = <String, dynamic>{
      'brand': brand,
      'item': item,
    };
    if (qtyValue != null && qtyUnit != null && qtyUnit.trim().isNotEmpty) {
      body['quantity'] = {
        'value': qtyValue,
        'unit': qtyUnit.toLowerCase(),
      };
    }
    final resp = await http.post(
      _resolverUri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      return {
        'exactId': (json['exactId'] as String?) ?? '',
        'candidates': ((json['candidates'] ?? []) as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList(),
      };
    }
    throw Exception('Resolver HTTP ${resp.statusCode}: ${resp.body}');
  }

  /// Checks if the manually entered brand exists in the dropdown list.
  /// If it exists, it returns the exact string from the list to ensure consistency.
  String? _findExistingBrand(String input) {
    final trimmedInput = input.trim().toLowerCase();
    if (trimmedInput.isEmpty) return null;

    try {
      // Find first match regardless of case
      return _brandOptions.firstWhere(
        (existing) => existing.toLowerCase() == trimmedInput,
      );
    } catch (_) {
      return null; // Not found in existing list
    }
  }

  Future<Map<String, dynamic>> _insertOriginalShop(String name) async {
    final resp = await http.post(
      _shopsAddUri,
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'name': name.trim()}),
    );
    if (resp.statusCode == 201 || resp.statusCode == 200) {
      // Response looks like: { "shopName": "...", "shopId": "..." }
      final map = jsonDecode(resp.body) as Map<String, dynamic>;
      return map;
    }
    throw Exception('POST /shops/add failed (${resp.statusCode}): ${resp.body}');
  }

  // ✅ NEW: item-only resolver (brand optional)
  Future<Map<String, dynamic>> _resolveByItemOnly({
    required String item,
    double? qtyValue,
    String? qtyUnit,
  }) async {
    final body = <String, dynamic>{'item': item};
    if (qtyValue != null && (qtyUnit?.trim().isNotEmpty ?? false)) {
      body['quantity'] = {
        'value': qtyValue,
        'unit': qtyUnit!.toLowerCase(),
      };
    }
    final resp = await http.post(
      _resolverByItemUri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      return {
        'exactId': (json['exactId'] as String?) ?? '',
        'candidates': ((json['candidates'] ?? []) as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList(),
      };
    }
    throw Exception('Resolver HTTP ${resp.statusCode}: ${resp.body}');
  }

  // ------------------------------ ROW CONTEXT --------------------------------
  /// Builds a human-readable context line for a row, e.g.:
  /// "Row 2 — Brand: Tesco • Item: basmati rice • Qty: 5kg • Channel: Online • Source: Tesco"
  String _rowContextLine(int index) {
    final brand = (_rowBrands[index] ?? '').trim();
    final item = (_rowItems[index] ?? '').trim();
    final qty = (_rowQty[index] ?? '').trim();
    final unit = (_rowQtyUnit[index] ?? '').trim();
    final chan = (_rowChannels[index] ?? '').trim();
    final src = chan == 'Online'
        ? (_rowSources[index] ?? '').trim()
        : (_rowShopNames[index] ?? '').trim();

    final parts = <String>[
      if (brand.isNotEmpty) 'Brand: $brand',
      if (item.isNotEmpty) 'Item: $item',
      if (qty.isNotEmpty && unit.isNotEmpty) 'Qty: $qty$unit',
      if (chan.isNotEmpty) 'Channel: $chan',
      if (src.isNotEmpty) (chan == 'Online' ? 'Source: $src' : 'Shop: $src'),
    ];
    if (parts.isEmpty) return 'Row ${index + 1}';
    return 'Row ${index + 1} — ${parts.join(' • ')}';
  }

  // For chooser bottom sheet
  static const String _noMatchKey = '__no_match__';

  // ✅ UPDATED: includes rowIndex and displays the row context in the sheet
  Future<Map<String, dynamic>?> _showCandidateChooserSheet({
    required int rowIndex,
    required List<Map<String, dynamic>> candidates,
  }) {
    return showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Row context banner (new)
                Text(
                  _rowContextLine(rowIndex),
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Choose the exact product',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: candidates.length,
                    separatorBuilder: (_, __) =>
                        const Divider(height: 1, thickness: 0.8),
                    itemBuilder: (ctx, i) {
                      final c = candidates[i];
                      final img = (c['picWebsite'] ?? '').toString();
                      final brand = (c['brand'] ?? '').toString();
                      final name = (c['name'] ?? '').toString();
                      final qty = (c['quantity'] ?? '').toString();
                      final feature = (c['feature'] ?? '').toString();
                      final hasQty = qty.isNotEmpty;
                      final hasFeature = feature.isNotEmpty;
                      return ListTile(
                        leading: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: img.isNotEmpty
                              ? Image.network(
                                  img,
                                  width: 52,
                                  height: 52,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) =>
                                      const Icon(Icons.image_not_supported),
                                )
                              : const Icon(Icons.image_not_supported),
                        ),
                        title: Text(
                          '$brand — $name',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (hasQty) Text('qty: $qty'),
                            if (hasFeature) const SizedBox(height: 2),
                            if (hasFeature)
                              SelectableText(
                                feature,
                                style: const TextStyle(height: 1.2),
                              ),
                          ],
                        ),
                        isThreeLine: true,
                        onTap: () => Navigator.pop(ctx, c),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 12),
                TextButton.icon(
                  icon: const Icon(Icons.not_interested_outlined),
                  label: const Text('None of these match my product'),
                  onPressed: () => Navigator.pop(ctx, {_noMatchKey: true}),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, null),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // Try resolve for a single row (supports brand-optional via item-only API)
  Future<void> _tryResolveItemForRow(int index) async {
    final brand = (_rowBrands[index] ?? '').trim();
    final item = (_rowItems[index] ?? '').trim();
    if (item.isEmpty) return;

    final qtyText = (_rowQty[index] ?? '').trim();
    final qtyUnit = (_rowQtyUnit[index] ?? '').trim();
    double? qtyVal;
    if (qtyText.isNotEmpty) {
      qtyVal = double.tryParse(qtyText.replaceAll(',', '.'));
    }
    try {
      Map<String, dynamic> result;
      if (brand.isEmpty) {
        // item-only resolve (read-only)
        result = await _resolverService.resolveItemOnly(
          item: item,
          qtyValue: qtyVal,
          qtyUnit: qtyUnit.isNotEmpty ? qtyUnit : null,
        );
      } else {
        // brand+item resolve (read-only)
        result = await _resolverService.resolveBrandItem(
          brand: brand,
          item: item,
          qtyValue: qtyVal,
          qtyUnit: qtyUnit.isNotEmpty ? qtyUnit : null,
        );
      }

      final exact = (result['exactId'] as String?) ?? '';
      final candidates =
          (result['candidates'] as List).cast<Map<String, dynamic>>();

      if (candidates.isNotEmpty) {
        final picked = await _showCandidateChooserSheet(
          rowIndex: index, // context
          candidates: candidates,
        );
        if (picked != null) {
          if (picked[_noMatchKey] == true) {
            await _promptForFeature(context, index);
            return;
          }
          setState(() {
            _rowItemIds[index] = (picked['id'] ?? '').toString();
            final q = (picked['quantity'] ?? '').toString();
            final m = RegExp(r'^(\d+(?:\.\d+)?)([a-zA-Z]+)$')
                .firstMatch(q.replaceAll(' ', ''));
            if (m != null) {
              _rowQty[index] = m.group(1)!;
              _rowQtyUnit[index] = m.group(2)!.toLowerCase();
            }
            // Optional: fill brand if it was empty
            if (brand.isEmpty) {
              _rowBrands[index] = (picked['brand'] ?? '').toString();
            }
          });
        }
        return;
      }

      if (exact.isNotEmpty) {
        final ok =
            await _confirmUseExactMatch(context, brand: brand, item: item);
        if (ok == true) {
          setState(() => _rowItemIds[index] = exact);
        }
        return;
      }

      // Nothing matched -> Prompt for feature
      await _promptForFeature(context, index);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Resolve failed: $e')),
      );
    }
  }

  // Apply "<number><unit>" into row qty/unit
  void _applyQtyStringToRow(int index, String qty) {
    final m = RegExp(r'^(\d+(?:\.\d+)?)([a-zA-Z]+)$')
        .firstMatch(qty.replaceAll(' ', ''));
    if (m != null) {
      setState(() {
        _rowQty[index] = m.group(1)!;
        _rowQtyUnit[index] = m.group(2)!.toLowerCase();
      });
    }
  }

  // Fetch candidate quantities for chips (supports item-only)
  Future<void> _refreshQtyPreviewForRow(int index) async {
    final brand = (_rowBrands[index] ?? '').trim();
    final item = (_rowItems[index] ?? '').trim();
    if (item.isEmpty) {
      if (mounted) setState(() => _rowQtyPreview.remove(index));
      return;
    }
    try {
      Map<String, dynamic> result;
      if (brand.isEmpty) {
        result = await _resolveByItemOnly(item: item); // read-only
      } else {
        result = await _resolveAgainstServer(brand: brand, item: item); // read-only
      }
      final cands =
          (result['candidates'] as List).cast<Map<String, dynamic>>();
      final preview = <String>[];
      for (final c in cands) {
        final q = (c['quantity'] ?? '').toString().trim();
        if (q.isNotEmpty && !preview.contains(q)) preview.add(q);
      }
      if (mounted) {
        setState(() {
          if (preview.isEmpty) {
            _rowQtyPreview.remove(index);
          } else {
            _rowQtyPreview[index] = preview;
          }
        });
      }
    } catch (_) {
      if (mounted) setState(() => _rowQtyPreview.remove(index));
    }
  }

  // ======================= CUSTOM CATEGORY INPUT =======================
  // Add this near your other "_promptForCustom..." dialogs
  Future<String?> _promptForCustomCategory(BuildContext ctx, int rowIndex) async {
    final controller = TextEditingController(text: _rowCategories[rowIndex] ?? '');
    String? error;

    return showDialog<String>(
      context: ctx,
      builder: (d) => StatefulBuilder(
        builder: (context, setDlg) => AlertDialog(
          title: Text(_rowContextLine(rowIndex)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("Enter custom category", style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              TextField(
                controller: controller,
                maxLength: FormValidators.kMaxTextLength,
                
                
                decoration: InputDecoration(
                      labelText: 'Price (in £)',
                      prefixText: '£',  // 👈 NEW
                      errorText: error,
                    ),


                onSubmitted: (_) {
                  final v = controller.text.trim();
                  String? err;
                  if (v.isEmpty) err = "Required";
                  if (FormValidators.exceedsMaxLength(v)) {
                    err = "Too long (max ${FormValidators.kMaxTextLength})";
                  }
                  if (err != null) {
                    setDlg(() => error = err);
                  } else {
                    Navigator.pop(d, v);
                  }
                },
              )
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d), child: const Text("Cancel")),
            ElevatedButton(
              child: const Text("Save"),
              onPressed: () {
                final v = controller.text.trim();
                if (v.isEmpty) {
                  setDlg(() => error = "Required");
                  return;
                }
                if (FormValidators.exceedsMaxLength(v)) {
                  setDlg(() => error = "Too long (max ${FormValidators.kMaxTextLength})");
                  return;
                }
                Navigator.pop(d, v);
              },
            ),
          ],
        ),
      ),
    );
  }


  Future<String?> _promptForCustomBrand(BuildContext ctx, int rowIndex) async {
    // Pre-fill with whatever the row currently has (brand/source)
    final controller = TextEditingController(text: _rowBrands[rowIndex] ?? '');
    String? error;

    final result = await showDialog<String>(
      context: ctx,
      builder: (d) => StatefulBuilder(
        builder: (context, setDlg) => AlertDialog(
          title: Text(_rowContextLine(rowIndex)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: controller,
                autofocus: true, // so keyboard pops up
                maxLength: FormValidators.kMaxTextLength,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  hintText: 'e.g. Tesco, Amazon, Boots, Ocado',
                  errorText: error,
                ),
                onSubmitted: (_) {
                  final v = controller.text.trim();
                  String? err;
                  if (v.isEmpty) {
                    err = 'Required';
                  } else if (FormValidators.exceedsMaxLength(v)) {
                    err = 'Too long (max ${FormValidators.kMaxTextLength})';
                  }
                  if (err != null) {
                    setDlg(() => error = err);
                  } else {
                    Navigator.pop(d, v);
                  }
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(d),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                final v = controller.text.trim();
                if (v.isEmpty) {
                  setDlg(() => error = 'Required');
                  return;
                }
                if (FormValidators.exceedsMaxLength(v)) {
                  setDlg(
                      () => error = 'Too long (max ${FormValidators.kMaxTextLength})');
                  return;
                }
                Navigator.pop(d, v);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    return result;
  }

  Future<String?> _promptForCustomItem(BuildContext ctx, int rowIndex) async {
    final controller = TextEditingController(text: _rowItems[rowIndex] ?? '');
    String? error;
    final result = await showDialog<String>(
      context: ctx,
      builder: (d) => StatefulBuilder(
        builder: (context, setDlg) => AlertDialog(
          title: Text(_rowContextLine(rowIndex)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Enter item', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              TextField(
                controller: controller,
                maxLength: FormValidators.kMaxTextLength,
                decoration: InputDecoration(
                  hintText: 'e.g. basmati rice',
                  errorText: error,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () {
                final v = controller.text.trim();
                if (v.isEmpty) {
                  setDlg(() => error = 'Required');
                  return;
                }
                if (FormValidators.exceedsMaxLength(v)) {
                  setDlg(
                      () => error = 'Too long (max ${FormValidators.kMaxTextLength})');
                  return;
                }
                Navigator.pop(d, v);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    return result;
  }

  Future<String?> _promptForFeature(BuildContext context, int rowIndex) async {
    final controller = TextEditingController(text: _rowFeatures[rowIndex] ?? '');
    String? error;
    final result = await showDialog<String>(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (context, setDlg) => AlertDialog(
          // Help the dialog reserve space when keyboard is up (M3 tighter layout)
          insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
          // Keep your nice row context banner
          title: Text(_rowContextLine(rowIndex)),
          // Wrap content with a scroll view so the TextField never gets clipped
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Enter product feature',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: controller,
                  autofocus: true,
                  maxLength: FormValidators.kMaxTextLength,
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(
                    hintText: 'e.g. Easy Cook, Golden Sella, Organic',
                    errorText: error,
                  ),
                  onSubmitted: (_) {
                    final v = controller.text.trim();
                    String? err;
                    if (FormValidators.exceedsMaxLength(v)) {
                      err = 'Too long (max ${FormValidators.kMaxTextLength})';
                    }
                    if (err != null) {
                      setDlg(() => error = err);
                    } else {
                      Navigator.pop(d, v);
                    }
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(d),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                final v = controller.text.trim();
                if (FormValidators.exceedsMaxLength(v)) {
                  setDlg(() => error = 'Too long (max ${FormValidators.kMaxTextLength})');
                  return;
                }
                Navigator.pop(d, v);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    // Keep your existing assignment behavior
    if (result != null && result.isNotEmpty && mounted) {
      setState(() => _rowFeatures[rowIndex] = result);
    }
    return result;
  }

  Future<void> _promptForCustomPrice(BuildContext context, int rowIndex) async {
    final controller = TextEditingController(text: _rowPrices[rowIndex] ?? '');
    String? error;
    final result = await showDialog<String>(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (context, setDlg) => AlertDialog(
          title: Text(_rowContextLine(rowIndex)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Enter price', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              TextField(
                controller: controller,
                keyboardType: const TextInputType.numberWithOptions(decimal: true), // Ensures numeric keyboard
                maxLength: FormValidators.kMaxTextLength,
                decoration: InputDecoration(
                  labelText: 'Price (in £)',
                  prefixText: '£ ', // 👈 Add this line to show the pound sign
                  prefixStyle: const TextStyle(fontWeight: FontWeight.bold), // Optional: makes the £ bold
                  hintText: '0.00',
                  errorText: error,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () {
                final v = controller.text.trim();
                final err = FormValidators.validateGbpPrice(v);
                if (err != null) {
                  setDlg(() => error = err);
                  return;
                }
                Navigator.pop(d, v);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (result != null && result.isNotEmpty && mounted) {
      setState(() => _rowPrices[rowIndex] = result);
    }
  }

  Future<bool?> _confirmUseExactMatch(BuildContext ctx,
      {required String brand, required String item}) {
    final display = [brand, item].where((s) => s.trim().isNotEmpty).join(' — ');
    return showDialog<bool>(
      context: ctx,
      builder: (d) => AlertDialog(
        title: Text(_rowContextLine(0)), // shows a header; row num doesn't matter here
        content: Text(
          display.isNotEmpty
              ? 'We found an exact match for:\n$display\n\nUse this product?'
              : 'We found an exact match.\nUse this product?',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('No')),
          ElevatedButton(onPressed: () => Navigator.pop(d, true), child: const Text('Yes')),
        ],
      ),
    );
  }

  // ---------------------------- PHOTO + OVERLAYS ------------------------------
  Widget _buildPhotoWithOverlays() {
    if (_imageFile == null || _imagePixelSize == null) {
      return const SizedBox.shrink();
    }
    final textBlocks =
        _textLabelsOnly().where((t) => t['bbox'] is Map).toList();
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxW = constraints.maxWidth;
        final maxH = constraints.maxHeight;
        final imgW = _imagePixelSize!.width;
        final imgH = _imagePixelSize!.height;
        final scale = math.min(maxW / imgW, maxH / imgH);
        final displayedW = imgW * scale;
        final displayedH = imgH * scale;
        final offsetX = (maxW - displayedW) / 2.0;
        final offsetY = (maxH - displayedH) / 2.0;

        Rect mapRect(Map<String, dynamic> bbox) {
          final left = (bbox['left'] as num).toDouble() * scale + offsetX;
          final top = (bbox['top'] as num).toDouble() * scale + offsetY;
          final right = (bbox['right'] as num).toDouble() * scale + offsetX;
          final bottom = (bbox['bottom'] as num).toDouble() * scale + offsetY;
          return Rect.fromLTRB(left, top, right, bottom);
        }

        final overlayChildren = <Widget>[
          Positioned(
            left: offsetX,
            top: offsetY,
            width: displayedW,
            height: displayedH,
            child: Image.file(_imageFile!, fit: BoxFit.contain),
          ),
          for (final t in textBlocks)
            Builder(
              builder: (ctx) {
                final bb = Map<String, dynamic>.from(t['bbox'] as Map);
                final rect = mapRect(bb);
                return Positioned(
                  left: rect.left,
                  top: rect.top,
                  width: rect.width,
                  height: rect.height,
                  child: GestureDetector(
                    onTap: () => _onTextBlockTapped(t),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.yellow.withOpacity(0.18),
                        border: Border.all(color: Colors.amber, width: 1.5),
                      ),
                    ),
                  ),
                );
              },
            ),
        ];

        return SizedBox(
          width: maxW,
          height: maxH,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: InteractiveViewer(
              clipBehavior: Clip.hardEdge,
              minScale: 1.0,
              maxScale: 4.0,
              child: Stack(children: overlayChildren),
            ),
          ),
        );
      },
    );
  }

  double _computePhotoHeight(BuildContext context) {
    final double oneThird = MediaQuery.of(context).size.height / 3.0;
    const double minH = 160.0;
    if (_imagePixelSize == null) {
      return oneThird < minH ? minH : oneThird;
    }
    final double availableWidth = MediaQuery.of(context).size.width - 24.0;
    final double imgW = _imagePixelSize!.width;
    final double imgH = _imagePixelSize!.height;
    final double fullWidthDisplayedHeight = availableWidth * (imgH / imgW);
    final double desired = math.min(oneThird, fullWidthDisplayedHeight);
    return desired < minH ? minH : desired;
  }

  void _onTextBlockTapped(Map<String, dynamic> blockItem) async {
    final raw = ((blockItem['description'] ?? '')).toString();
    final prices = _extractPricesFromString(raw);
    if (prices.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No number found in this text block.')),
      );
      return;
    }
    String? chosen;
    if (prices.length == 1) {
      chosen = prices.first;
    } else {
      if (!mounted) return;
      chosen = await showModalBottomSheet<String>(
        context: context,
        builder: (ctx) => ListView(
          children: prices
              .map((p) => ListTile(
                    title: Text(p),
                    onTap: () => Navigator.pop(ctx, p),
                  ))
              .toList(),
        ),
      );
    }
    if (chosen == null) return;
    final int rowIndex = _labels.indexOf(blockItem);
    if (rowIndex >= 0 && mounted) {
      setState(() => _rowPrices[rowIndex] = chosen!);
    }
  }

  // ------------------------ SHARED UI HELPERS --------------------------------
  Widget _buildLoadingStub() {
    return const SizedBox(
      height: 40,
      child: Center(
        child: SizedBox(
          height: 20,
          width: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }

  Widget _buildQtyPreviewChips(int index) {
    final list = _rowQtyPreview[index] ?? const <String>[];
    if (list.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6.0),
      child: Wrap(
        spacing: 6,
        runSpacing: -6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Text(
            'Available quantities:',
            style: TextStyle(fontSize: 12, color: Colors.black54),
          ),
          for (final q in list)
            InputChip(
              label: Text(q),
              onPressed: () => _applyQtyStringToRow(index, q),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
        ],
      ),
    );
  }

  Widget _buildEmptyOptionsHint(String what) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Text(
        'No $what options. Tap “Refresh dropdowns” in the top bar.',
        style: const TextStyle(color: Colors.black54),
      ),
    );
  }

  // photo_taking.dart — add near other helpers
  int _clientGeneratedId() {
    // 9‑digit rolling id based on microseconds; good enough for client-side uniqueness
    final n = DateTime.now().microsecondsSinceEpoch % 1000000000;
    return n.toInt();
  }

  // ------------------------- RANKING (OCR + COLOUR) --------------------------
  int _scoreOptionAgainstText(String option, String rowText) {
    if (option.isEmpty || rowText.isEmpty) return 0;
    final optNorm = _normalize(option);
    final rowNorm = _normalize(rowText);
    final rowTokens = _tokens(rowNorm);
    final optTokens = _tokens(optNorm);
    int score = 0;
    for (final t in optTokens) {
      if (rowTokens.contains(t)) score += 3;
    }
    if (optNorm.isNotEmpty && rowNorm.contains(optNorm)) score += 2;
    for (final t in optTokens) {
      final stem = t.length >= 4 ? t.substring(0, 4) : t;
      if (rowNorm.contains(stem)) score += 1;
    }
    return score;
  }

  // Case-insensitive membership helper
  bool _containsIgnoreCase(Iterable<String> list, String probe) {
    final p = probe.trim().toLowerCase();
    return list.any((s) => s.trim().toLowerCase() == p);
  }

  bool _looksLikeReceipt() {
    final text = _aggregateOcrText().toLowerCase();
    final hints = [
      'subtotal',
      'total',
      'tax',
      'vat',
      'visa',
      'mastercard',
      'debit',
      'credit',
      'change'
    ];
    final currency = RegExp(r'(\u00a3|\$|\u20ac)\s*\d');
    int hits = 0;
    for (final h in hints) {
      if (text.contains(h)) hits++;
    }
    final hasMoney = currency.hasMatch(text);
    return hits >= 2 || (hasMoney && hits >= 1);
  }

  Future<void> _loadColorMapsForMode() async {
    try {
      if (!_hasText()) {
        _itemColorsTextless = await _itemService.fetchItemColorsForTextless();
      } else if (_hasText() && !_looksLikeReceipt()) {
        _itemColorsPrices = await _itemService.fetchItemColors(filters: null);
      }
    } catch (e) {
      debugPrint('Color maps load error: $e');
    }
  }

  String _normColor(String s) {
    const alias = {'gray': 'grey', 'violet': 'purple', 'magenta': 'pink'};
    final k = s.toLowerCase().trim();
    return alias[k] ?? k;
  }

  int _scoreColorsWeighted(List<String> dbColors, Set<String> photoColors) {
    if (dbColors.isEmpty || photoColors.isEmpty) return 0;
    int score = 0;
    const maxW = 5;
    for (int i = 0; i < dbColors.length; i++) {
      final token = _normColor(dbColors[i]);
      if (photoColors.contains(token)) {
        final w = (maxW - i);
        score += (w > 1 ? w : 1);
      }
    }
    return score;
  }

  int _scoreColorsUnweighted(List<String> dbColors, Set<String> photoColors) {
    if (dbColors.isEmpty || photoColors.isEmpty) return 0;
    int score = 0;
    for (final c in dbColors) {
      if (photoColors.contains(_normColor(c))) score += 1;
    }
    return score;
  }

  List<String> _rankedBrandsForRow(
    Map<String, dynamic> rowItem,
    List<String> options,
  ) {
    final String rowText =
        rowItem['type'] == 'text' ? ((rowItem['description'] ?? '').toString()) : '';
    final String aggText = _aggregateOcrText();
    final withScores = options.map((s) {
      final rowSc = _scoreOptionAgainstText(s, rowText);
      final aggSc = _scoreOptionAgainstText(s, aggText);
      return MapEntry(s, (rowSc * 2) + aggSc);
    }).toList();
    withScores.sort((a, b) {
      final cmp = b.value.compareTo(a.value);
      if (cmp != 0) return cmp;
      return a.key.toLowerCase().compareTo(b.key.toLowerCase());
    });
    return withScores.map((e) => e.key).toList();
  }

  List<String> _rankedItemsColorAwareForRow(
    Map<String, dynamic> rowItem,
    List<String> options,
  ) {
    final String rowText =
        rowItem['type'] == 'text' ? ((rowItem['description'] ?? '').toString()) : '';
    final String aggText = _aggOcrCache ??= _aggregateOcrText();
    final bool textless = !_hasText();
    final bool goodsNoReceipt = _hasText() && !_looksLikeReceipt();

    int ocrScore(String s) {
      final rowSc = _scoreOptionAgainstText(s, rowText);
      final aggSc = _scoreOptionAgainstText(s, aggText);
      return (rowSc * 2) + aggSc;
    }

    int colorScore(String s) {
      if (textless) {
        final colors = _itemColorsTextless[s] ?? const <String>[];
        return _scoreColorsUnweighted(colors, _photoColorTokens);
      } else if (goodsNoReceipt) {
        final colors = _itemColorsPrices[s] ?? const <String>[];
        return _scoreColorsWeighted(colors, _photoColorTokens);
      }
      return 0;
    }

    final withScores = options.map((s) {
      final cSc = colorScore(s);
      final oSc = ocrScore(s);
      final total = (textless || goodsNoReceipt) ? (cSc * 3 + oSc) : ocrScore(s);
      return MapEntry(s, total);
    }).toList();

    withScores.sort((a, b) {
      final cmp = b.value.compareTo(a.value);
      if (cmp != 0) return cmp;
      return a.key.toLowerCase().compareTo(b.key.toLowerCase());
    });

    return withScores.map((e) => e.key).toList();
  }

  // ------------------------------- ROW LOGIC ----------------------------------
  void _addEmptyRow() async {
    // Always make sure base dropdowns are ready
    await _ensureDropdownOptionsLoaded();
    // If there is no photo, merge in extras so manual matches textless-photo richness
    if (_noPhoto) {
      await _ensureManualItemBoosters();
    }
    setState(() {
      final newIndex = _labels.length;
      _labels.add({
        'type': 'text',
        'description': '',
        'score': null,
        'bbox': null,
      });
      // Default item count = 1
      _rowItemCounts[newIndex] = '1';
    });
  }

  void _deleteRow(int index) {
    if (index < 0 || index >= _labels.length) return;
    setState(() {
      _labels.removeAt(index);
      _reindexAfterDelete(index);
    });
  }

  void _reindexAfterDelete(int removed) {
    void shiftStr(Map<int, String> m) {
      final newMap = <int, String>{};
      m.forEach((k, v) {
        if (k < removed) {
          newMap[k] = v;
        } else if (k > removed) {
          newMap[k - 1] = v;
        }
      });
      m
        ..clear()
        ..addAll(newMap);
    }

    void shiftBool(Map<int, bool> m) {
      final newMap = <int, bool>{};
      m.forEach((k, v) {
        if (k < removed) {
          newMap[k] = v;
        } else if (k > removed) {
          newMap[k - 1] = v;
        }
      });
      m
        ..clear()
        ..addAll(newMap);
    }

    void shiftDouble(Map<int, double> m) {
      final newMap = <int, double>{};
      m.forEach((k, v) {
        if (k < removed) {
          newMap[k] = v;
        } else if (k > removed) {
          newMap[k - 1] = v;
        }
      });
      m
        ..clear()
        ..addAll(newMap);
    }

    void shiftCtrl(Map<int, TextEditingController> m) {
      final newMap = <int, TextEditingController>{};
      m.forEach((k, v) {
        if (k < removed) {
          newMap[k] = v;
        } else if (k > removed) {
          newMap[k - 1] = v;
        } else {
          v.dispose();
        }
      });
      m
        ..clear()
        ..addAll(newMap);
    }

    shiftStr(_rowPrices);
    shiftStr(_rowBrands);
    shiftStr(_rowItems);
    shiftStr(_rowChannels);
    shiftStr(_rowSources);
    shiftStr(_rowItemIds);
    shiftStr(_rowQty);
    shiftStr(_rowQtyUnit);
    shiftBool(_rowDiscount);
    shiftStr(_rowFeatures);

    shiftStr(_rowShopNames);
    shiftStr(_rowShopAddresses);
    shiftDouble(_rowShopLat);
    shiftDouble(_rowShopLng);

    shiftStr(_rowItemCounts); // NEW: keep indices consistent

    for (final col in _customColumns) {
      shiftStr(col.values);
    }
    shiftCtrl(_sourceCtrls);
    shiftCtrl(_shopNameCtrls);
  }

  // ----------------------------- ROW CARD UI ---------------------------------
  Widget _buildRowCard(int index, Map<String, dynamic> rowItem) {
    final String idText = _rowItemIds[index]?.isNotEmpty == true
        ? _rowItemIds[index]!
        : 'Row ${index + 1}';

    // Brand
    final brandField = Builder(builder: (context) {
      if (_brandOptions.isEmpty && _optionsBusy) return _buildLoadingStub();
      if (_brandOptions.isEmpty && !_optionsBusy) {
        return _buildEmptyOptionsHint('brand');
      }

      final ranked = _rankedBrandsForRow(rowItem, _brandOptions);
      final current = _rowBrands[index] ?? '';

      return DropdownSearch<String>(
        selectedItem: current.isNotEmpty ? current : null,

        // Searchable list
        items: (filter, _) {
          final f = filter.toLowerCase();
          return ranked
              .where((b) => b.toLowerCase().contains(f))
              .toList()
            ..insert(0, '__custom__');
        },

        compareFn: (a, b) => a == b,

        itemAsString: (b) => b == '__custom__' ? 'Custom…' : b,

        onChanged: (val) async {
          if (val == null) return;

          if (val == '__custom__') {
            final entered = await _promptForCustomBrand(context, index);
            if (entered != null && entered.trim().isNotEmpty) {
              final vv = entered.trim();

              // reuse existing brand if it already exists
              final existing = _findExistingBrand(vv);
              setState(() => _rowBrands[index] = existing ?? vv);

              // mark for saving later
              _pendingShopsToSave.add(existing ?? vv);
            }
            return;
          }

          setState(() => _rowBrands[index] = val);
          if (val.trim().isNotEmpty) {
            _pendingShopsToSave.add(val.trim());
          }
        },

        popupProps: const PopupProps.menu(
          showSearchBox: true,
          searchFieldProps: TextFieldProps(
            decoration: InputDecoration(
              hintText: 'Search brand...',
            ),
          ),
        ),

        decoratorProps: DropDownDecoratorProps(
          decoration: InputDecoration(
            labelText: 'Brand',
            prefixIcon: const Icon(Icons.store_outlined),
            border: OutlineInputBorder(),
          ),
        ),
      );
    });

    // ---------------- ITEM (Searchable) ----------------
    final itemField = Builder(builder: (context) {
      if (_itemOptions.isEmpty && _optionsBusy) return _buildLoadingStub();
      if (_itemOptions.isEmpty && ! _optionsBusy) {
        return _buildEmptyOptionsHint('item');
      }

      final ranked = _rankedItemsColorAwareForRow(rowItem, _itemOptions);
      final current = _rowItems[index] ?? '';

      return DropdownSearch<String>(
        selectedItem: current.isNotEmpty ? current : null,

        // SEARCHABLE LIST
        items: (filter, _) {
          final f = filter.toLowerCase();
          return [
            '__custom__',
            ...ranked.where((i) => i.toLowerCase().contains(f))
          ];
        },

        itemAsString: (v) => v == '__custom__' ? 'Custom…' : v,

        onChanged: (val) async {
          if (val == null) return;

          if (val == '__custom__') {
            final entered = await _promptForCustomItem(context, index);
            if (entered != null && entered.trim().isNotEmpty) {
              setState(() => _rowItems[index] = entered.trim());
              _refreshQtyPreviewForRow(index);
            }
            return;
          }

          setState(() {
            _rowItems[index] = val;
          });

          _refreshQtyPreviewForRow(index);
        },

        popupProps: const PopupProps.menu(
          showSearchBox: true,
          searchFieldProps: TextFieldProps(
            decoration: InputDecoration(
              hintText: "Search item...",
            ),
          ),
        ),

        decoratorProps: DropDownDecoratorProps(
          decoration: InputDecoration(
            labelText: "Item",
            border: OutlineInputBorder(),
          ),
        ),
      );
    });

  // -------------------- CATEGORY (FIXED: searchable + no duplicates) --------------------
  final categoryField = Builder(builder: (context) {
    if (_categoryOptions.isEmpty && _optionsBusy) return _buildLoadingStub();
    if (_categoryLoadError != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MaterialBanner(
            content: Text(_categoryLoadError!),
            leading: const Icon(Icons.error_outline, color: Colors.red),
            actions: [
              TextButton.icon(
                onPressed: _refreshAllDropdowns,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _buildEmptyOptionsHint('category'),
        ],
      );
    }

    String norm(String s) => s.trim().toLowerCase();

    final currentRaw = _rowCategories[index] ?? "";
    final current = norm(currentRaw);

    final ranked = _categoryOptions.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    return DropdownSearch<String>(
      selectedItem: current.isNotEmpty ? currentRaw : null,

      // SEARCHABLE LIST
      items: (filter, _) {
        final f = filter.toLowerCase();
        final list = ranked.where((c) => c.toLowerCase().contains(f)).toList();
        return [
          "__clear__",
          "__custom__",
          ...list,
        ];
      },

      itemAsString: (v) {
        if (v == "__clear__") return "— None —";
        if (v == "__custom__") return "Custom…";
        return v;
      },

      onChanged: (val) async {
        if (val == null) return;
        if (val == "__clear__") {
          setState(() => _rowCategories[index] = "");
          return;
        }
        if (val == "__custom__") {
          final entered = await _promptForCustomCategory(context, index);
          if (entered != null && entered.trim().isNotEmpty) {
            setState(() => _rowCategories[index] = norm(entered));
          }
          return;
        }

        setState(() => _rowCategories[index] = val);
      },

      popupProps: const PopupProps.menu(
        showSearchBox: true,
        searchFieldProps: TextFieldProps(
          decoration: InputDecoration(hintText: "Search category..."),
        ),
      ),

      decoratorProps: const DropDownDecoratorProps(
        decoration: InputDecoration(
          labelText: "Category",
          border: OutlineInputBorder(),
        ),
      ),
    );
  });



    // ------------------ END CATEGORY (NEW) ------------------

    // Quantity + Unit (size/measure)
    final quantityField = Builder(builder: (context) {
      final qtyText = _rowQty[index] ?? '';
      final unit = _rowQtyUnit[index];
      final qtyError = FormValidators.validateQuantityByUnit(qtyText, unit);
      String? unitError;
      if ((qtyText.trim().isNotEmpty) && (unit == null || unit.isEmpty)) {
        unitError = 'Choose unit';
      }
      if (qtyText.trim().isEmpty) {
        unitError = unit == null || unit.isEmpty ? 'Required' : null;
      }
      return Row(
        children: [
          Expanded(
            flex: 3,
            child: TextFormField(
              initialValue: qtyText,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*$')),
              ],
              onChanged: (v) => setState(() => _rowQty[index] = v.trim()),
              decoration: InputDecoration(
                labelText: 'Quantity',
                hintText: 'e.g. 0.5 or 2.75',
                errorText: qtyError,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: DropdownButtonFormField<String>(
              isExpanded: true,
              value: (unit != null && _qtyUnits.contains(unit)) ? unit : null,
              items: _qtyUnits
                  .map((u) => DropdownMenuItem(value: u, child: Text(u)))
                  .toList(),
              onChanged: (val) => setState(() => _rowQtyUnit[index] = val ?? ''),
              hint: const Text('Unit'),
              decoration: InputDecoration(
                labelText: 'Unit',
                errorText: unitError,
              ),
            ),
          ),
        ],
      );
    });

    // NEW: Item quantity (count of items) — integer only, defaults to 1
    final itemCountField = TextFormField(
      initialValue: (_rowItemCounts[index] ?? '1'),
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      onChanged: (v) => setState(() => _rowItemCounts[index] = v.trim()),
      decoration: const InputDecoration(
        labelText: 'Item quantity',
        hintText: 'e.g. 1, 2, 3',
      ),
    );

    // Price (GBP) with inline error
    final priceField = Builder(builder: (context) {
      final options = _pricesCache ??= _extractNumbersFromText();
      final items = <DropdownMenuItem<String>>[
        ...options.map((o) =>
            DropdownMenuItem(value: o, child: Text(o, overflow: TextOverflow.ellipsis, maxLines: 1))),
        const DropdownMenuItem(value: '__custom__', child: Text('Custom…')),
      ];
      final current = _rowPrices[index] ?? '';
      if (current.isNotEmpty && !items.any((it) => it.value == current)) {
        items.insert(
          0,
          DropdownMenuItem(
            value: current,
            child: Text(current, overflow: TextOverflow.ellipsis, maxLines: 1),
          ),
        );
      }
      final priceError = FormValidators.validateGbpPrice(current);
      return DropdownButtonFormField<String>(
        isExpanded: true,
        value: current.isNotEmpty ? current : null,
        items: items,
        onChanged: (val) async {
          if (val == null) return;
          if (val == '__custom__') {
            await _promptForCustomPrice(context, index);
            if (mounted) setState(() {});
          } else {
            setState(() => _rowPrices[index] = val);
          }
        },
        decoration: InputDecoration(
          labelText:  'Price (in £)',
          errorText: priceError,
        ),
      );
    });

    // Discount switch
    final discountField = SwitchListTile(
      title: const Text('Discount applied?'),
      value: _rowDiscount[index] ?? false,
      onChanged: (v) => setState(() => _rowDiscount[index] = v),
      dense: true,
      contentPadding: EdgeInsets.zero,
    );

    final currentChannel = (_rowChannels[index] ?? '').trim();
    final channelField = DropdownButtonFormField<String>(
      isExpanded: true,
      value: currentChannel.isNotEmpty ? currentChannel : null,
      items: _channelOptions.map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
      onChanged: (val) {
        if (val == null) return;
        setState(() => _rowChannels[index] = val);
      },
      hint: const Text('Choose channel'),
      decoration: const InputDecoration(labelText: 'Channel'),
    );

    final bool isPhysical = (_rowChannels[index] ?? '') == 'Physical';
    final bool isOnline = (_rowChannels[index] ?? '') == 'Online';
    final bool hasPickedShop = (_rowShopAddresses[index]?.isNotEmpty ?? false);

    TextEditingController _ctrlForSource() {
      final existing = _sourceCtrls[index];
      if (existing != null) return existing;
      final c = TextEditingController(text: _rowShopAddresses[index] ?? '');
      _sourceCtrls[index] = c;
      return c;
    }

    TextEditingController _ctrlForShopName() {
      final existing = _shopNameCtrls[index];
      if (existing != null) return existing;
      final c = TextEditingController(text: _rowShopNames[index] ?? '');
      _shopNameCtrls[index] = c;
      return c;
    }

    final String pickedAddr = _rowShopAddresses[index] ?? '';

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header with row badge + ID
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.indigo.shade50,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.indigo.shade200),
                  ),
                  child: Text(
                    'Row ${index + 1}',
                    style: TextStyle(
                      color: Colors.indigo.shade800,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    idText,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                IconButton(
                  tooltip: 'Delete row',
                  onPressed: () => _deleteRow(index),
                  icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                ),
              ],
            ),

            const SizedBox(height: 8),
            brandField,
            const SizedBox(height: 8),
            itemField,

            // <-- Category is placed here
            const SizedBox(height: 8),
            categoryField,

            const SizedBox(height: 8),
            quantityField,
            _buildQtyPreviewChips(index),
            const SizedBox(height: 8),

            // NEW: item count just before price
            itemCountField,
            const SizedBox(height: 8),

            priceField,
            discountField,
            const SizedBox(height: 8),

            channelField,

            if (isPhysical) ...[
              const SizedBox(height: 8),
              if (!hasPickedShop)
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.map_outlined),
                        label: const Text('Find shop on map'),
                        onPressed: () async {
                          final place = await _pickShopFromMap();
                          if (place == null) return;
                          await _applyPickedPlaceToRow(index, place);
                        },
                      ),
                    ),
                  ],
                )
              else ...[
                const SizedBox(height: 8),
                TextFormField(
                  controller: _ctrlForShopName(),
                  onChanged: (v) => setState(() {
                    final vv = FormValidators.clampMaxLength(v.trim());
                    _rowShopNames[index] = vv;
                    if (vv.isNotEmpty) _pendingShopsToSave.add(vv);
                  }),
                  maxLength: FormValidators.kMaxTextLength,
                  minLines: 1,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Shop name',
                    hintText: 'e.g. Tesco Extra (Cabot Circus)',
                    prefixIcon: Icon(Icons.store_outlined),
                  ),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _ctrlForSource(),
                  readOnly: true,
                  enableInteractiveSelection: true,
                  keyboardType: TextInputType.multiline,
                  minLines: 2,
                  maxLines: 5,
                  textAlignVertical: TextAlignVertical.top,
                  decoration: InputDecoration(
                    labelText: 'Shop Address',
                    hintText: 'Address of the shop / source',
                    prefixIcon: const Icon(Icons.place_outlined),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.map_outlined),
                      tooltip: 'Rechoose on map',
                      onPressed: () async {
                        final place = await _pickShopFromMap();
                        if (place == null) return;
                        await _applyPickedPlaceToRow(index, place);
                      },
                    ),
                  ),
                ),
              ],
            ] else if (isOnline) ...[
              const SizedBox(height: 8),
              
              Builder(builder: (context) {
                final roots = sn.collapseToChainRoots(_shopOptions);
                final ranked = _rankedSourcesForRow(rowItem, roots);

                final currentRaw = _rowSources[index] ?? '';
                final current = currentRaw.isNotEmpty ? sn.chainRoot(currentRaw) : '';

                final List<DropdownMenuItem<String>> items = [
                  const DropdownMenuItem(value: '__custom__', child: Text('Custom…')),
                  ...ranked.map(
                    (s) => DropdownMenuItem(
                      value: s,
                      child: Text(s, overflow: TextOverflow.ellipsis, maxLines: 1),
                    ),
                  ),
                ];

                // Ensure currently selected value appears
                if (current.isNotEmpty && !ranked.contains(current)) {
                  items.insert(
                    1,
                    DropdownMenuItem(
                      value: current,
                      child: Text(current, overflow: TextOverflow.ellipsis, maxLines: 1),
                    ),
                  );
                }

                return DropdownSearch<String>(
                  selectedItem: current.isNotEmpty ? current : null,

                  // SEARCHABLE LIST
                  items: (filter, _) {
                    final f = filter.toLowerCase();
                    return [
                      '__custom__',
                      ...ranked.where((s) => s.toLowerCase().contains(f))
                    ];
                  },

                  itemAsString: (v) => v == '__custom__' ? 'Custom…' : v,

                  onChanged: (val) async {
                    if (val == null) return;

                    if (val == '__custom__') {
                      final entered = await _promptForCustomBrand(context, index);
                      if (entered != null && entered.trim().isNotEmpty) {
                        final vv = sn.chainRoot(entered.trim());
                        setState(() => _rowSources[index] = vv);
                        if (vv.isNotEmpty) _pendingShopsToSave.add(vv);
                      }
                      return;
                    }

                    final vv = sn.chainRoot(val);
                    setState(() => _rowSources[index] = vv);
                    if (vv.isNotEmpty) _pendingShopsToSave.add(vv);
                  },

                  popupProps: const PopupProps.menu(
                    showSearchBox: true,
                    searchFieldProps: TextFieldProps(
                      decoration: InputDecoration(
                        hintText: 'Search source…',
                      ),
                    ),
                  ),

                  decoratorProps: const DropDownDecoratorProps(
                    decoration: InputDecoration(
                      labelText: 'Source (online, choose the most relevant one)',
                      prefixIcon: Icon(Icons.public_outlined),
                      border: OutlineInputBorder(),
                    ),
                  ),
                );

              })

            ],

            const SizedBox(height: 8),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _addEmptyRow,
                  icon: const Icon(Icons.add),
                  label: const Text('Add Row'),
                ),
                const SizedBox(width: 8),
                
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ----------------------- DYNAMIC FORM LIST ---------------------------------
  Widget _buildDynamicFormList() {
    if (_labels.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 6.0),
        child: Text(
          'No items yet — take a photo, pick one, or enable Manual Input to add rows.',
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (int i = 0; i < _labels.length; i++) _buildRowCard(i, _labels[i]),
      ],
    );
  }

  // --------------------------- VALIDATION HELPERS -----------------------------
  Future<List<String>> _validateRow(int index) async {
    final errors = <String>[];
    final brand = (_rowBrands[index] ?? '').trim();
    final item = (_rowItems[index] ?? '').trim();
    final qty = (_rowQty[index] ?? '').trim();
    final unit = (_rowQtyUnit[index] ?? '').trim();
    final price = (_rowPrices[index] ?? '').trim();
    final chan = (_rowChannels[index] ?? '').trim();

    // Brand is optional:
    if (item.isEmpty) errors.add('Item is required');
    if (FormValidators.exceedsMaxLength(brand)) {
      errors.add('Brand too long (max ${FormValidators.kMaxTextLength})');
    }
    if (FormValidators.exceedsMaxLength(item)) {
      errors.add('Item too long (max ${FormValidators.kMaxTextLength})');
    }

    final qErr = FormValidators.validateQuantityByUnit(qty, unit);
    if (qErr != null) errors.add('Quantity: $qErr');
    if (unit.isEmpty) errors.add('Quantity unit is required');

    final pErr = FormValidators.validateGbpPrice(price);
    if (pErr != null) errors.add('Price (in £): $pErr');

    if (chan.isEmpty) errors.add('Channel is required');

    if (chan == 'Physical') {
      final shopName = (_rowShopNames[index] ?? '').trim();
      final addr = (_rowShopAddresses[index] ?? '').trim();
      if (shopName.isEmpty) errors.add('Shop name is required');
      if (addr.isEmpty) errors.add('Shop address is required');
      if (FormValidators.exceedsMaxLength(shopName)) {
        errors.add('Shop name too long (max ${FormValidators.kMaxTextLength})');
      }
      if (FormValidators.exceedsMaxLength(addr)) {
        errors.add('Shop address too long (max ${FormValidators.kMaxTextLength})');
      }
    } else if (chan == 'Online') {
      final source = (_rowSources[index] ?? '').trim();
      if (source.isEmpty) errors.add('Source (online) is required');
      if (FormValidators.exceedsMaxLength(source)) {
        errors.add('Source too long (max ${FormValidators.kMaxTextLength})');
      }
    }

    // Note: Item quantity (count) is optional for now; defaults to 1, and is integer-only at input.
    return errors;
  }

  List<String> _rankedSourcesForRow(
    Map<String, dynamic> rowItem,
    List<String> options,
  ) {
    final String rowText =
        rowItem['type'] == 'text' ? ((rowItem['description'] ?? '').toString()) : '';
    final String aggText = _aggregateOcrText();

    final scored = options.map((s) {
      final rowSc = _scoreOptionAgainstText(s, rowText);
      final aggSc = _scoreOptionAgainstText(s, aggText);
      final total = (rowSc * 2) + aggSc;
      return MapEntry(s, total);
    }).toList();

    scored.sort((a, b) {
      final cmp = b.value.compareTo(a.value);
      if (cmp != 0) return cmp;
      return a.key.toLowerCase().compareTo(b.key.toLowerCase());
    });

    return scored.map((e) => e.key).toList();
  }


  // ----------------------------------- BUILD ---------------------------------
  @override
  Widget build(BuildContext context) {

    final bool showFormSection = _manualMode || _labels.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          // History
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'Saved photos',
            onPressed: () async {
              if (_db == null) return;
              final rows = await _db!.query('photos', orderBy: 'taken_at DESC');
              if (!mounted) return;
              showModalBottomSheet(
                context: context,
                builder: (_) => ListView.builder(
                  itemCount: rows.length,
                  itemBuilder: (ctx, i) {
                    final row = rows[i];
                    final path = row['file_path'] as String;
                    final when = DateTime.fromMillisecondsSinceEpoch(
                      row['taken_at'] as int,
                    );
                    final labelsJson = row['labels_json'] as String?;
                    final labels =
                        labelsJson != null ? (jsonDecode(labelsJson) as List) : [];
                    return ListTile(
                      leading: Image.file(
                        File(path),
                        width: 56,
                        height: 56,
                        fit: BoxFit.cover,
                      ),
                      title: Text(p.basename(path)),
                      subtitle: Text('${when.toLocal()} • ${labels.length} items'),
                      onTap: () async {
                        Navigator.pop(context);
                        final f = File(path);
                        if (!mounted) return;
                        setState(() {
                          _imageFile = f;
                          _labels = labels
                              .map((e) => Map<String, dynamic>.from(e))
                              .toList();

                          _rowPrices.clear();
                          _rowBrands.clear();
                          _rowItems.clear();
                          _rowChannels.clear();
                          _rowItemIds.clear();
                          _rowQty.clear();
                          _rowQtyUnit.clear();
                          _rowDiscount.clear();

                          _rowShopNames.clear();
                          _rowShopAddresses.clear();
                          _rowShopLat.clear();
                          _rowShopLng.clear();

                          _rowItemCounts.clear(); // NEW: clear item counts

                          _pricesCache = null;
                          _aggOcrCache = null;
                          _manualMode = false;

                          for (final c in _sourceCtrls.values) {
                            c.dispose();
                          }
                          _sourceCtrls.clear();
                        });
                        await _loadImagePixelSize(f);
                        await _computePhotoColorTokens(f);
                        if (!_hasText()) {
                          await _loadItemOptions();
                          await _loadTextlessItemExtras();
                        } else {
                          await _loadItemOptions();
                        }
                        await _loadColorMapsForMode();
                      },
                    );
                  },
                ),
              );
            },
          ),

          // Submit
          ElevatedButton.icon(
            onPressed: _submitAndResolveAll,
            icon: const Icon(Icons.send, color: Colors.white, size: 18),
            label: const Text('Submit', style: TextStyle(color: Colors.white)),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.teal),
          ),
        ],
      ),

      // Body
      body: Column(
        children: [
          const SizedBox(height: 8),

          // 👇 ADD THIS BLOCK HERE
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Text(
              "User ID: ${widget.userId}",
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          // 👆 ADD THIS BLOCK HERE

          // Top controls
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  ElevatedButton.icon(
                    onPressed: _isBusy ? null : _captureFromCamera,
                    icon: const Icon(Icons.camera_alt),
                    label: const Text('Camera'),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton.icon(
                    onPressed: _isBusy ? null : _pickFromGallery,
                    icon: const Icon(Icons.photo_library),
                    label: const Text('Pick'),
                  ),
                  const SizedBox(width: 16),
                  ElevatedButton.icon(
                    onPressed: _addEmptyRow,
                    icon: const Icon(Icons.add),
                    label: const Text('Add Row'),
                  ),
                  const SizedBox(width: 8),
                  
                ],
              ),
            ),
          ),
          if (_isBusy)
            const Padding(
              padding: EdgeInsets.all(8.0),
              child: LinearProgressIndicator(),
            ),
          const SizedBox(height: 16),

          // Error banners
          if (_brandLoadError != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12.0),
              child: MaterialBanner(
                content: Text(_brandLoadError!),
                leading: const Icon(Icons.error_outline, color: Colors.red),
                actions: [
                  TextButton.icon(
                    onPressed: _refreshAllDropdowns,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry'),
                  )
                ],
              ),
            ),
          if (_itemLoadError != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12.0),
              child: MaterialBanner(
                content: Text(_itemLoadError!),
                leading: const Icon(Icons.error_outline, color: Colors.red),
                actions: [
                  TextButton.icon(
                    onPressed: _refreshAllDropdowns,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry'),
                  )
                ],
              ),
            ),

          // Main content
          Expanded(
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_imageFile != null) ...[
                      SizedBox(
                        height: _computePhotoHeight(context),
                        width: double.infinity,
                        child: _buildPhotoWithOverlays(),
                      ),
                      const SizedBox(height: 12),
                    ],
                    const Text(
                      'Item Input',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    if (showFormSection) _buildDynamicFormList(),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),

      // FABs
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          FloatingActionButton(
            heroTag: 'fab_add_row',
            onPressed: _addEmptyRow,
            tooltip: 'Add Row',
            child: const Icon(Icons.add),
          ),
          const SizedBox(height: 12),
          FloatingActionButton(
            heroTag: 'fab_camera',
            onPressed: _isBusy ? null : _captureFromCamera,
            tooltip: 'Take Photo',
            child: const Icon(Icons.camera_alt),
          ),
        ],
      ),
    );
  }

  // (Continue in Part 3/3: helpers for submit & the full submit flow incl. price insert)
  
  // ---------- Helpers to compose create payload for items (when no exact match)
  ItemCreatePayload? _buildCreatePayloadForRow(int i) {
    final item = (_rowItems[i] ?? '').trim();
    final qty = (_rowQty[i] ?? '').trim();
    final unit = (_rowQtyUnit[i] ?? '').trim();
    if (item.isEmpty || qty.isEmpty || unit.isEmpty) return null;

    final colors =
        _photoColorTokens.isNotEmpty ? _photoColorTokens.join(', ') : null;

    return ItemCreatePayload(
      name: item,
      brand: (_rowBrands[i] ?? '').trim().isEmpty ? null : _rowBrands[i]!.trim(),
      quantity: '$qty$unit',
      feature:
          (_rowFeatures[i] ?? '').trim().isNotEmpty ? _rowFeatures[i]!.trim() : null,
      productColor: colors,
      picWebsite: null, // set later if you have a URL
    );
  }

  // ------------------------------ PRICE HELPERS -------------------------------
  String _stripCurrencySymbol(String s) {
    final t = s.trim();
    if (t.isEmpty) return t;
    return t.replaceFirst(RegExp(r'^[\u00a3\$\€]\s*'), '');
  }

  double? _gbpToDouble(String priceText) {
    final cleaned = _stripCurrencySymbol(priceText).replaceAll(',', '');
    final v = double.tryParse(cleaned);
    if (v == null) return null;
    // Clamp to 2dp for storage consistency
    return double.parse(v.toStringAsFixed(2));
  }

  String _todayGmtDate() {
    final now = DateTime.now().toUtc();
    return '${now.year.toString().padLeft(4, '0')}-'
           '${now.month.toString().padLeft(2, '0')}-'
           '${now.day.toString().padLeft(2, '0')}';
  }

  String _displayablePriceLabel(int rowIdx, double price, bool discountOn) {
    final p = '£${price.toStringAsFixed(2)}';
    return discountOn ? '$p (discount)' : p;
  }

  // REPLACE the old sync helper with this async one
  Future<String> _shopIdForRowAsync(int i) async {
    final isPhysical = ((_rowChannels[i] ?? '') == 'Physical');
    final raw = isPhysical ? (_rowShopNames[i] ?? '').trim()
                          : (_rowSources[i] ?? '').trim();

    // 1) Normalize like the rest of your UI (keeps UX consistent)  [1](https://uweacuk-my.sharepoint.com/personal/ka4_au_live_uwe_ac_uk/Documents/Microsoft%20Copilot%20Chat%20Files/form_validators.dart)
    final root = sn.chainRoot(raw);
    if (root.isEmpty) return raw; // nothing to resolve

    // 2) Ask backend mapping for canonical shopID; fallback to root if missing
    final resolved = await _chainShopService.resolveIdForName(root);
    return (resolved?.trim().isNotEmpty ?? false) ? resolved!.trim() : root;
  }

  String? _shopAddressForRow(int i) {
    // Physical -> we keep the picked address; Online -> null
    if ((_rowChannels[i] ?? '') == 'Physical') {
      final addr = (_rowShopAddresses[i] ?? '').trim();
      return addr.isNotEmpty ? addr : null;
    }
    return null;
  }

  // Build the summary popup before inserting a price row
  Future<DiscountSummaryResult?> _confirmPriceForRow({
    required int rowIndex,
    required String itemId,
    required String shopId,
    required String channel,
    required String dateGmt,
    required double priceValue,
    required bool discountOn,
    required String? shopAdd,
  }) {
    final itemName = (_rowItems[rowIndex] ?? '').trim();
    final brand = (_rowBrands[rowIndex] ?? '').trim();
    final qty = (_rowQty[rowIndex] ?? '').trim();
    final unit = (_rowQtyUnit[rowIndex] ?? '').trim();
    final itemCount = (_rowItemCounts[rowIndex] ?? '1').trim();

    final details = <MapEntry<String, String>>[
      if (brand.isNotEmpty) MapEntry('Brand', brand),
      if (itemName.isNotEmpty) MapEntry('Item', itemName),
      if (qty.isNotEmpty && unit.isNotEmpty) MapEntry('Qty', '$qty$unit'),
      if (itemCount.isNotEmpty) MapEntry('Item quantity', itemCount),
      MapEntry('Item ID', itemId),
      MapEntry('Shop ID', shopId),
      MapEntry('Channel', channel),
      MapEntry('Date (GMT)', dateGmt),
      MapEntry('Price (in £)', _displayablePriceLabel(rowIndex, priceValue, discountOn)),
      if (shopAdd != null && shopAdd.isNotEmpty) MapEntry('Shop address', shopAdd),
    ];

    return showDialog<DiscountSummaryResult>(
      context: context,
      builder: (ctx) => DiscountSummaryDialog(
        rowSummary: _rowContextLine(rowIndex),
        details: details,
        discountOn: discountOn,
        maxLen: FormValidators.kMaxTextLength,
      ),
    );
  }

  /// Helper: PATCH the category for a specific item-input / price row
  Future<void> _updateItemCategory({
    required String priceId,
    required String itemId,
    required String category,
    required String shopName,   // this is your chainShopID
    required String createdAt,  // expected as 'YYYY-MM-DD HH:MM:SS' (UTC)
  }) async {
    try {
      final uri = Uri.parse('${_baseUrl}api/item-input/category');

      final body = jsonEncode({
        "userID": widget.userId,
        "itemID": itemId,
        "priceID": priceId,
        "chainShopID": shopName, // backend expects chainShopID key
        "createdAt": createdAt,
        "category": category,
      });

      final resp = await http.patch(
        uri,
        headers: const {'Content-Type': 'application/json'},
        body: body,
      );

      if (resp.statusCode != 200) {
        debugPrint('Failed to update category (HTTP ${resp.statusCode}): ${resp.body}');
      }
    } catch (e) {
      debugPrint('Error updating category: $e');
    }
  }  

Future<void> _submitAndResolveAll() async {
  if (_isBusy) return;
  setState(() => _isBusy = true);

  bool aborted = false;

  // Local helper to stop cleanly (no writes)
  Future<void> _stopEarly([String? toast]) async {
    if (mounted && (toast?.isNotEmpty ?? false)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(toast!)),
      );
    }
    return;
  }

  // Local helper to generate a reasonably unique client id for the row insert
  int _clientGeneratedId() {
    final n = DateTime.now().microsecondsSinceEpoch % 1000000000;
    return n.toInt();
  }

  try {
    // 1) Validate all rows
    final allErrors = <int, List<String>>{};
    for (int i = 0; i < _labels.length; i++) {
      final errs = await _validateRow(i);
      if (errs.isNotEmpty) allErrors[i] = errs;
    }
    if (allErrors.isNotEmpty) {
      if (!mounted) return;
      final msg = StringBuffer();
      allErrors.forEach((row, errs) {
        msg.writeln(_rowContextLine(row));
        for (final e in errs) {
          msg.writeln(' • $e');
        }
        msg.writeln('');
      });
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Please fix the following'),
          content: SingleChildScrollView(child: Text(msg.toString())),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
          ],
        ),
      );
      return; // no writes
    }

    // 2) Resolve across rows (READ-ONLY) — respects Cancel as abort
    for (int i = 0; i < _labels.length; i++) {
      final brand = (_rowBrands[i] ?? '').trim();
      final item = (_rowItems[i] ?? '').trim();
      final qtyT = (_rowQty[i] ?? '').trim();
      final unit = (_rowQtyUnit[i] ?? '').trim();
      if (item.isEmpty) continue;

      double? qtyVal;
      if (qtyT.isNotEmpty) qtyVal = double.tryParse(qtyT);

      Map<String, dynamic> result;
      if (brand.isEmpty) {
        result = await _resolveByItemOnly(
          item: item,
          qtyValue: qtyVal,
          qtyUnit: unit.isNotEmpty ? unit : null,
        );
      } else {
        result = await _resolveAgainstServer(
          brand: brand,
          item: item,
          qtyValue: qtyVal,
          qtyUnit: unit.isNotEmpty ? unit : null,
        );
      }

      final exact = (result['exactId'] ?? '').toString();
      final cands = (result['candidates'] as List).cast<Map<String, dynamic>>();

      if (cands.isNotEmpty) {
        final picked = await _showCandidateChooserSheet(
          rowIndex: i,
          candidates: cands,
        );
        // Treat Cancel as "abort whole submit"
        if (picked == null) {
          aborted = true;
          await _stopEarly('Submission cancelled — nothing saved.');
          return; // EARLY EXIT: no writes
        }
        if (picked['__no_match__'] == true) {
          final feature = await _promptForFeature(context, i);
          if (feature == null) {
            aborted = true;
            await _stopEarly('Submission cancelled — nothing saved.');
            return; // EARLY EXIT: no writes
          }
          // If they did enter a feature, setter already happens in _promptForFeature
          continue;
        }
        setState(() {
          _rowItemIds[i] = (picked['id'] ?? '').toString();
          final q = (picked['quantity'] ?? '').toString();
          final m = RegExp(r'^(\d+(?:\.\d+)?)([a-zA-Z]+)$').firstMatch(q.replaceAll(' ', ''));
          if (m != null) {
            _rowQty[i] = m.group(1)!;
            _rowQtyUnit[i] = m.group(2)!.toLowerCase();
          }
          if (brand.isEmpty) {
            _rowBrands[i] = (picked['brand'] ?? '').toString();
          }
        });
        continue;
      }

      if (exact.isNotEmpty) {
        final ok = await _confirmUseExactMatch(context, brand: brand, item: item);
        if (ok == true) {
          _rowItemIds[i] = exact;
        } else {
          // user declined exact match; continue read-only stage
        }
        continue;
      }

      // Nothing matched -> ask for feature
      final feature = await _promptForFeature(context, i);
      if (feature == null) {
        aborted = true;
        await _stopEarly('Submission cancelled — nothing saved.');
        return; // EARLY EXIT: no writes
      }
    }

    // If any cancel was detected above (defensive check)
    if (aborted) return;

    // 3) Create items (WRITE)
    final indexedPayloads = <MapEntry<int, ItemCreatePayload>>[];
    for (int i = 0; i < _labels.length; i++) {
      final hasExisting = (_rowItemIds[i]?.isNotEmpty ?? false);
      if (hasExisting) continue;
      final p = _buildCreatePayloadForRow(i);
      if (p != null) indexedPayloads.add(MapEntry(i, p));
    }
    if (indexedPayloads.isNotEmpty) {
      try {
        final createdIds =
            await _submitService.createItems(indexedPayloads.map((e) => e.value).toList());
        for (int k = 0; k < createdIds.length && k < indexedPayloads.length; k++) {
          final rowIndex = indexedPayloads[k].key;
          final newId = (createdIds[k] ?? '').toString();
          if (newId.isNotEmpty) {
            _rowItemIds[rowIndex] = newId;
          }
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Created ${createdIds.length} item(s) on server')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Server create failed: $e')),
          );
        }
      }
    }

    // 4) Persist any new shops (WRITE)
    try {
      final existing = await _shopService.fetchShops(); // List<String>
      final toInsert = <String>{};

      for (int i = 0; i < _labels.length; i++) {
        final chan = (_rowChannels[i] ?? '');
        if (chan == 'Physical') {
          final name = (_rowShopNames[i] ?? '').trim();
          if (name.isNotEmpty && !_containsIgnoreCase(existing, name)) {
            toInsert.add(name);
          }
        } else if (chan == 'Online') {
          final source = (_rowSources[i] ?? '').trim();
          if (source.isNotEmpty && !_containsIgnoreCase(existing, source)) {
            toInsert.add(source);
          }
        }
      }

      for (final s in _pendingShopsToSave) {
        if (s.isNotEmpty && !_containsIgnoreCase(existing, s)) {
          toInsert.add(s);
        }
      }

      for (final s in toInsert) {
        try {
          await _shopService.addShop(s);
        } catch (_) {
          // ignore duplicate/races
        }
      }

      await _loadShopOptions();
      _pendingShopsToSave.clear();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Shop sync skipped: $e')),
        );
      }
    }

    // 5) PRICE INSERTION (WRITE)
    final String gmtDate = _todayGmtDate();
    final List<PriceRow> toCreate = [];
    final List<Map<String, dynamic>> pendingItemInputs = [];

    for (int i = 0; i < _labels.length; i++) {
      final itemId = (_rowItemIds[i] ?? '').trim();
      if (itemId.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Row ${i + 1}: missing item ID, price not inserted.')),
        );
        continue;
      }

      final channel = (_rowChannels[i] ?? '').trim();
      if (channel.isEmpty) continue;

      final shopId = await _shopIdForRowAsync(i);
      if (shopId.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Row ${i + 1}: missing shop/source, price not inserted.')),
        );
        continue;
      }

      final shopAdd = _shopAddressForRow(i);
      final priceText = (_rowPrices[i] ?? '').trim();
      final parsed = _gbpToDouble(priceText);
      if (parsed == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Row ${i + 1}: invalid price, not inserted.')),
        );
        continue;
      }

      final existing = await _priceService.findPrice(
        itemID: itemId,
        shopID: shopId,
        channel: channel,
        date: gmtDate,
      );

      final discountOn = _rowDiscount[i] ?? false;
      final newNormal = discountOn ? null : parsed;
      final newDiscount = discountOn ? parsed : null;
      String? newCond;

      if (discountOn) {
        final confirm = await _confirmPriceForRow(
          rowIndex: i,
          itemId: itemId,
          shopId: shopId,
          channel: channel,
          dateGmt: gmtDate,
          priceValue: parsed,
          discountOn: discountOn,
          shopAdd: shopAdd,
        );
        // Cancel only cancels this row’s price insert
        if (confirm == null || confirm.confirmed == false) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Row ${i + 1}: price insertion cancelled.')),
            );
          }
          continue;
        }
        newCond = (confirm.discountCond?.trim().isNotEmpty ?? false)
            ? confirm.discountCond!.trim()
            : null;
      }

      if (existing != null) {
        final oldNormal =
            existing['normalPrice'] == null ? null : (existing['normalPrice'] as num).toDouble();
        final oldDiscount =
            existing['discountPrice'] == null ? null : (existing['discountPrice'] as num).toDouble();
        final oldCond = existing['discountCond']?.toString();

        final changed =
            oldNormal != newNormal || oldDiscount != newDiscount || (oldCond ?? '') != (newCond ?? '');

        if (changed) {
          await _priceService.updatePrice(
            id: (existing['id'] as num).toInt(),
            normalPrice: newNormal,
            discountPrice: newDiscount,
            discountCond: newCond,
          );
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Row ${i + 1}: existing price updated.')),
            );
          }
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Row ${i + 1}: no changes, skipped.')),
            );
          }
        }
        continue;
      }

      // New row — confirm & add
      final confirm = await _confirmPriceForRow(
        rowIndex: i,
        itemId: itemId,
        shopId: shopId,
        channel: channel,
        dateGmt: gmtDate,
        priceValue: parsed,
        discountOn: discountOn,
        shopAdd: shopAdd,
      );
      if (confirm == null || confirm.confirmed == false) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Row ${i + 1}: price insertion cancelled.')),
          );
        }
        continue;
      }

      final priceId = _clientGeneratedId();
      final row = PriceRow(
        id: priceId,
        itemID: itemId,
        shopID: shopId,
        channel: channel,
        date: gmtDate,
        normalPrice: discountOn ? null : parsed,
        discountPrice: discountOn ? parsed : null,
        discountCond: discountOn
            ? (confirm.discountCond?.trim().isNotEmpty == true
                ? confirm.discountCond!.trim()
                : null)
            : null,
        shopAdd: shopAdd,
      );
      toCreate.add(row);

      int _parseItemCount(String? s) {
        final v = int.tryParse((s ?? '1').trim());
        return (v == null || v <= 0) ? 1 : v;
      }

      String _sizeWithUnit(int row) {
        final qty = (_rowQty[row] ?? '').trim();
        final unit = (_rowQtyUnit[row] ?? '').trim();
        return '$qty$unit';
      }

      final itemCount = _parseItemCount(_rowItemCounts[i]);
      final sizeWithUnit = _sizeWithUnit(i);

      // Add a full payload for itemInput (INCLUDES rowIndex + createdAt)
      final payload = <String, dynamic>{
        'rowIndex': i, // <-- Needed for category lookup
        'createdAt': DateTime.now().toUtc().toString().split('.')[0], // YYYY-MM-DD HH:MM:SS
        'userID': widget.userId,
        'brand': (_rowBrands[i] ?? '').trim().isNotEmpty ? _rowBrands[i]!.trim() : null,
        'itemName': (_rowItems[i] ?? '').trim(),
        'itemNo': itemCount,
        'itemID': itemId,
        'feature': (_rowFeatures[i] ?? '').trim().isNotEmpty ? _rowFeatures[i]!.trim() : null,
        'quantity': sizeWithUnit,
        'priceValue': parsed,
        'priceID': priceId,
        'discountApplied': discountOn ? 1 : 0,
        'channel': channel.toLowerCase(),
        'shop_name': (channel == 'Physical') ? (_rowShopNames[i] ?? '').trim() : (_rowSources[i] ?? '').trim(),
        'shop_address': shopAdd,
        'chainShopID': shopId,
      }..removeWhere((k, v) => v == null);

      pendingItemInputs.add(payload);
      _debugShowItemInputPayload(payload);
    }

    if (toCreate.isNotEmpty) {
      try {
        final created = await _priceService.createBatch(toCreate);

        // For each new price row, create the itemInput, then PATCH its category
        for (final payload in pendingItemInputs) {
          try {
            final newItemInputId = await _itemInputService.create(payload);
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('itemInput saved (id=$newItemInputId)')),
              );
            }

            // === CATEGORY PATCH (NEW) ===
            final int rowIndex = payload['rowIndex'] as int;
            final String? selectedCategory = _rowCategories[rowIndex];
            if (selectedCategory != null && selectedCategory.isNotEmpty) {
              await _updateItemCategory(
                priceId: payload['priceID'].toString(),
                itemId: payload['itemID'],
                category: selectedCategory,
                shopName: payload['chainShopID'], // server expects "chainShopID"
                createdAt: payload['createdAt'],
              );
            }
            // =============================
          } catch (e) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('itemInput insert failed: $e')),
              );
            }
          }
        }

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Inserted $created price row(s).')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Price insert failed: $e')),
          );
        }
      }
    }

    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => BuyingHistoryPage(userId: widget.userId),
      ),
    );
  } catch (e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Submit failed: $e')),
    );
  } finally {
    if (mounted) setState(() => _isBusy = false);
  }
}


}
// (end of file)
// -----------------------------------------------------------------------------