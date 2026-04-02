// lib/settings_page.dart
// Simplified: Home/Workplace postcode now picked directly from map (no county/district UI).
// Uses your MapSearchScreen (returns a Place via Navigator.pop(context, place)) and
// mirrors the place-picking approach you use in photo_taking.dart. [1]
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'login_page.dart';
// Map picker (same as in your photo_taking.dart)
import 'map_picker/map_search_screen.dart'; // returns Place on pop [1]
import 'map_picker/place.dart'; // id/name/formattedAddress/lat/lng/postcode [1]

/* ─────────────────────────────── Models (unchanged) ─────────────────────────────── */
class Allergen {
  final String id;
  final String name;
  final String? category;
  Allergen({required this.id, required this.name, this.category});
  factory Allergen.fromDynamic(dynamic e) {
    if (e is String) {
      return Allergen(id: e.toLowerCase().replaceAll(' ', '_'), name: e);
    }
    if (e is Map<String, dynamic>) {
      final id = (e['id'] ?? e['_id'] ?? e['code'] ?? e['name'] ?? '').toString();
      final name = (e['name'] ?? e['label'] ?? e['title'] ?? id).toString();
      final category = (e['category'] ?? e['type'] ?? e['group'])?.toString();
      return Allergen(id: id.isEmpty ? name : id, name: name, category: category);
    }
    final s = e.toString();
    return Allergen(id: s, name: s);
  }
  static List<Allergen> parseResponse(dynamic decoded) {
    final list = (decoded is Map && decoded['items'] is List)
        ? (decoded['items'] as List)
        : (decoded as List? ?? <dynamic>[]);
    return list.map(Allergen.fromDynamic).toList();
  }
}

class ItemRecord {
  final String id;
  final String name;
  final String brand;
  final String quantity;
  final String feature;
  final String productColor;
  final String picWebsite;
  ItemRecord({
    required this.id,
    required this.name,
    required this.brand,
    required this.quantity,
    required this.feature,
    required this.productColor,
    required this.picWebsite,
  });
  factory ItemRecord.fromJson(Map<String, dynamic> m) => ItemRecord(
        id: (m['id'] ?? '').toString(),
        name: (m['name'] ?? '').toString(),
        brand: (m['brand'] ?? '').toString(),
        quantity: (m['quantity'] ?? '').toString(),
        feature: (m['feature'] ?? '').toString(),
        productColor: (m['productColor'] ?? '').toString(),
        picWebsite: (m['picWebsite'] ?? '').toString(),
      );
}


// ▶ Add below ItemRecord (or alongside your other models)
class RegionOption {
  final String id;            // regionID as string
  final String name;          // regionName
  final String flagEmoji;     // from endpoint (or fallback)
  final String utcOffset;     // "+08:00" or "-05:30" etc.

  RegionOption({
    required this.id,
    required this.name,
    required this.flagEmoji,
    required this.utcOffset,
  });
}

// Parse "+08:00" out of an ISO datetime with offset; returns null if not found.
String? _extractOffsetFromDatetime(String? iso) {
  if (iso == null || iso.isEmpty) return null;
  // Look for "+HH:MM" or "-HH:MM" at the end of the string
  final m = RegExp(r'([+-]\d{2}:\d{2}$)').firstMatch(iso.trim());
  return m?.group(1);
}

// When datetime is null, the endpoint may provide offsetHrsVsUtc as a number.
// Convert, e.g. 8   -> "+08:00", -5.5 -> "-05:30", 9.75 -> "+09:45"
String _formatOffsetFromHours(num hours) {
  final sign = hours >= 0 ? '+' : '-';
  final absH = hours.abs();
  final h = absH.floor();
  final minutes = ((absH - h) * 60).round(); // handles .5, .75, etc.
  final hh = h.toString().padLeft(2, '0');
  final mm = minutes.toString().padLeft(2, '0');
  return '$sign$hh:$mm';
}

// Some rows may expose flag as emoji or as URL. Prefer emoji if present.
// If missing, you can compute from countryCode if the endpoint has it.
// Here we fall back to a generic white flag.
String _pickFlagEmoji(Map<String, dynamic> row) {
  final f = (row['countryFlag'] ?? '').toString().trim();
  // If already looks like an emoji (two Regional Indicator Symbols), keep it.
  if (RegExp(r'[\u{1F1E6}-\u{1F1FF}]{2}', unicode: true).hasMatch(f)) {
    return f;
  }
  // Optional: try countryCode -> emoji (only if your endpoint returns 'countryCode').
  final cc = (row['countryCode'] ?? '').toString().toUpperCase();
  if (RegExp(r'^[A-Z]{2}$').hasMatch(cc)) {
    int base = 0x1F1E6; // 'A'
    int a = cc.codeUnitAt(0) - 0x41; // 'A' => 0
    int b = cc.codeUnitAt(1) - 0x41;
    return String.fromCharCode(base + a) + String.fromCharCode(base + b);
  }
  return '🏳️';
}


/* ───────────────────────────────── Widget Root ─────────────────────────────── */
class SettingsPage extends StatefulWidget {
  final String userId;
  final String identifierType; // e.g., 'Email'
  final String identifierValue; // e.g., 'someone@example.com'
  const SettingsPage({
    super.key,
    required this.userId,
    required this.identifierType,
    required this.identifierValue,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  /* ───────────────────────────── Form controllers ───────────────────────────── */
  final _formKey = GlobalKey<FormState>();
  final _salaryCtrl = TextEditingController();
  final _targetSavingCtrl = TextEditingController();

  // Final full postcodes stored here (Home & Work) — now filled from map picker.
  final _postcodeCtrl = TextEditingController();       // HOME postcode
  final _workPostcodeCtrl = TextEditingController();   // WORK postcode

  // NEW: full address (Home & Work) — read-only, populated from map picker.
  final _homeAddressCtrl = TextEditingController();
  final _workAddressCtrl = TextEditingController();

  /* ───────────────────── Input formatters & validators ─────────────────────── */
  final _moneyInputFormatter =
      FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}$'));

  // Simple UK postcode format check; the actual existence is validated online.
  /*
  String? _validatePostcode(String? value) {
    if (value == null || value.trim().isEmpty) return 'Postcode is required';
    final normalized =
        value.toUpperCase().replaceAll(RegExp(r'\s+'), ' ').trim();
    final light =
        RegExp(r'^[A-Z0-9]{1,4}\s?[A-Z0-9]{3}$', caseSensitive: false);
    if (!light.hasMatch(normalized)) return 'Please check postcode format';
    return null;
  }
  */
  
  String? _extractOffsetFromRow(Map<String, dynamic> rowOrTz) {
    String? s;

    // 1) direct +HH:MM or +HHMM
    s = (rowOrTz['utc_offset'] ??
        rowOrTz['utcOffset'] ??
        rowOrTz['offset'] ??
        rowOrTz['abbrev'] ??
        rowOrTz['tzAbbrev'])
        ?.toString()
        .trim();

    if (s != null && s.isNotEmpty) {
      // Normalize "+HHMM" → "+HH:MM"
      final m4 = RegExp(r'^([+-])(\d{2})(\d{2})$').firstMatch(s);
      if (m4 != null) return '${m4[1]}${m4[2]}:${m4[3]}';
      // Already "+HH:MM"?
      final m5 = RegExp(r'^[+-]\d{2}:\d{2}$').firstMatch(s);
      if (m5 != null) return s;
    }

    // 2) minute-based offsets
    final offMin = rowOrTz['offsetMinutes'];
    if (offMin is num) {
      final sign = offMin >= 0 ? '+' : '-';
      final absMin = offMin.abs().round();
      final hh = (absMin ~/ 60).toString().padLeft(2, '0');
      final mm = (absMin % 60).toString().padLeft(2, '0');
      return '$sign$hh:$mm';
    }

    // 3) second-based offsets (raw_offset + dst_offset)
    final rawSec = rowOrTz['raw_offset'];
    final dstSec = rowOrTz['dst_offset'];
    if (rawSec is num || dstSec is num) {
      final total = (rawSec is num ? rawSec : 0) + (dstSec is num ? dstSec : 0);
      final sign = total >= 0 ? '+' : '-';
      final absMin = (total.abs() / 60).round();
      final hh = (absMin ~/ 60).toString().padLeft(2, '0');
      final mm = (absMin % 60).toString().padLeft(2, '0');
      return '$sign$hh:$mm';
    }

    // 4) float hour offset (what you already support)
    final off = rowOrTz['offsetHrsVsUtc'];
    if (off is num) return _formatOffsetFromHours(off);
    if (off is String && off.isNotEmpty) {
      final n = num.tryParse(off);
      if (n != null) return _formatOffsetFromHours(n);
    }

    return null;
  }


  String? _validateMoneyLoose(String? value, {String fieldName = 'Amount'}) {
    if (value == null || value.trim().isEmpty) return '$fieldName is required';
    final parsed = double.tryParse(value.trim());
    if (parsed == null || parsed < 0) return 'Enter a valid amount';
    return null;
  }

  String _slugify(String s) {
    return s
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
  }

  /* ───────────────────────────── Persisted values ───────────────────────────── */
  double? _salary;
  double? _targetSaving;
  String? _postcode;        // HOME postcode
  String? _workPostcode;    // WORK postcode
  String? _homeAddress;     // HOME full address (new)
  String? _workAddress;     // WORK full address (new)
  bool _savingSettings = false;

  // ▼ Region dropdown state
  bool _loadingRegions = false;
  String? _regionsError;
  List<RegionOption> _regions = <RegionOption>[];
  String? _selectedRegionId;

  // ▼ Prefill DisplayTime from loginTable
  String? _pendingIso3FromLoginTable; // holds ISO‑3 until regions arrive
  bool _loadingLoginTable = false;
  String? _loginTableError;


  /* ─────────────────────────── API bases & helpers ─────────────────────────── */
  static const String _kDataApiBase = 'https://nodejs-production-53a4.up.railway.app';
  static const String _kUserApiBase = 'https://nodejs-production-f031.up.railway.app';

  Future<http.Response> _getWithFallback(Uri primary, {Uri? secondary}) async {
    http.Response? last;
    try {
      last = await http.get(primary).timeout(const Duration(seconds: 10));
      if (last.statusCode == 200) return last;
    } catch (_) {}
    if (secondary != null) {
      try {
        last = await http.get(secondary).timeout(const Duration(seconds: 10));
        if (last.statusCode == 200) return last;
      } catch (_) {}
    }
    if (last != null) return last;
    throw Exception('Network error (both endpoints failed)');
  }

  Future<http.Response> _putWithFallback(
    Uri primary, {
    Uri? secondary,
    Map<String, String>? headers,
    Object? body,
  }) async {
    http.Response? last;
    try {
      last = await http
          .put(primary, headers: headers, body: body)
          .timeout(const Duration(seconds: 10));
      if (last.statusCode == 200) return last;
    } catch (_) {}
    if (secondary != null) {
      try {
        last = await http
            .put(secondary, headers: headers, body: body)
            .timeout(const Duration(seconds: 10));
        if (last.statusCode == 200) return last;
      } catch (_) {}
    }
    if (last != null) return last;
    throw Exception('Network error (both endpoints failed)');
  }

  /* ───────────────────────── Allergens / Blacklist state (unchanged) ───────────────────── */
  bool _loadingAllergens = false;
  String? _allergenLoadError;
  final TextEditingController _allergenSearchCtrl = TextEditingController();
  final TextEditingController _customAllergenNameCtrl = TextEditingController();
  final TextEditingController _customAllergenCategoryCtrl =
      TextEditingController();
  bool _loadingUserAllergens = false;
  String? _userAllergenError;
  List<Allergen> _allergens = [];
  List<Allergen> _visibleAllergens = [];
  final Set<String> _selectedAllergenIds = {};
  List<Allergen> get _selectedAllergens =>
      _allergens.where((a) => _selectedAllergenIds.contains(a.id)).toList();

  final TextEditingController _blacklistSearchCtrl = TextEditingController();
  String _blacklistField = 'all';
  Timer? _blacklistDebounce;
  bool _loadingItemSearch = false;
  String? _itemSearchError;
  List<ItemRecord> _itemResults = [];
  final Set<String> _selectedBlacklistIds = {};
  final Map<String, ItemRecord> _itemLookup = {}; // id -> record
  bool _loadingUserBlacklist = false;
  String? _userBlacklistError;

  /* ───────────────────────── Settings load helpers ─────────────────────────── */
  bool _loadingSettings = false;
  String? _settingsLoadError;
  String _asFixed2(double? v) => v == null ? '' : v.toStringAsFixed(2);

  // Unsaved changes snapshot
  Set<String> _savedAllergensSnapshot = {};
  Set<String> _savedBlacklistSnapshot = {};

  bool _setsEqual<T>(Set<T> a, Set<T> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (final x in a) {
      if (!b.contains(x)) return false;
    }
    return true;
  }

  
  // Add inside _SettingsPageState
  void _log(String tag, String msg, [Object? data]) {
    // debugPrint avoids truncation and is IDE-friendly
    final s = data == null ? msg : '$msg | $data';
    debugPrint('[$tag] $s'); // shows in VS Code Debug Console/Terminal
  }


  void _snapshotCurrentAsSaved() {
    _savedAllergensSnapshot = Set<String>.from(_selectedAllergenIds);
    _savedBlacklistSnapshot = Set<String>.from(_selectedBlacklistIds);
    // salary/target/postcodes/addresses already reflected on successful load/save
  }

  bool _hasUnsavedChanges() {
    final currentSalary = _salaryCtrl.text.trim();
    final currentSaving = _targetSavingCtrl.text.trim();
    final currentHome = _postcodeCtrl.text.trim().toUpperCase();
    final currentWork = _workPostcodeCtrl.text.trim().toUpperCase();
    final currentHomeAddr = _homeAddressCtrl.text.trim();
    final currentWorkAddr = _workAddressCtrl.text.trim();

    final lastSalary = _salary == null ? '' : _salary!.toStringAsFixed(2);
    final lastSaving = _targetSaving == null ? '' : _targetSaving!.toStringAsFixed(2);
    final lastHome = (_postcode ?? '').toUpperCase();
    final lastWork = (_workPostcode ?? '').toUpperCase();
    final lastHomeAddr = (_homeAddress ?? '');
    final lastWorkAddr = (_workAddress ?? '');

    final fieldsChanged = (currentSalary != lastSalary) ||
        (currentSaving != lastSaving) ||
        (currentHome != lastHome) ||
        (currentWork != lastWork) ||
        (currentHomeAddr != lastHomeAddr) ||
        (currentWorkAddr != lastWorkAddr);

    final allergensChanged =
        !_setsEqual(_selectedAllergenIds, _savedAllergensSnapshot);
    final blacklistChanged =
        !_setsEqual(_selectedBlacklistIds, _savedBlacklistSnapshot);
    return fieldsChanged || allergensChanged || blacklistChanged;
  }

  Future<String?> _confirmSaveBeforeLeave({required String leavingAction}) {
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Save changes before $leavingAction?'),
        content: const Text(
          'You have unsaved changes. Would you like to save them before you leave?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null), // Cancel
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('discard'), // No
            child: const Text("Don't save"),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop('save'), // Yes
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  /* ─────────────────────── Online postcode existence check ─────────────────── */
  /*
  Future<bool> _checkPostcodeExists(String postcode) async {
    try {
      final uri = Uri.parse('https://postcodes.io/postcodes/${Uri.encodeComponent(postcode)}');
      final resp = await http.get(uri).timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return false;
      final body = json.decode(resp.body) as Map<String, dynamic>;
      return (body['status'] == 200 && body['result'] != null);
    } catch (_) {
      return false;
    }
  }
  */

  /* ───────────────────────── Allergens: load/filter/save (unchanged) ───────────────────── */
  Future<void> _fetchAllergens() async {
    setState(() {
      _loadingAllergens = true;
      _allergenLoadError = null;
    });
    try {
      final resp = await _getWithFallback(
        Uri.parse('$_kDataApiBase/api/allergens'),
        secondary: Uri.parse('$_kUserApiBase/api/allergens'),
      );
      if (resp.statusCode == 200) {
        final decoded = json.decode(resp.body);
        final list = Allergen.parseResponse(decoded);
        setState(() {
          _allergens = list;
          _visibleAllergens = list;
        });
        _reconcileSelectedAllergensWithCatalog();
      } else {
        setState(() {
          _allergenLoadError = 'Failed to load (HTTP ${resp.statusCode})';
        });
      }
    } catch (_) {
      setState(() {
        _allergenLoadError = 'Failed to load allergens';
      });
    } finally {
      if (mounted) setState(() => _loadingAllergens = false);
    }
  }

  Future<void> _prefillDisplayTimeFromLoginTable() async {
    setState(() { _loadingLoginTable = true; _loginTableError = null; });
    const tag = 'LOGIN_TABLE';

    try {
      final uri = Uri.parse(
        'https://nodejs-production-f031.up.railway.app/api/admin/loginTable'
      );
      _log(tag, 'GET', uri);
      final resp = await http.get(uri).timeout(const Duration(seconds: 20));
      _log(tag, 'HTTP status', resp.statusCode);

      if (resp.statusCode != 200) {
        throw Exception('HTTP ${resp.statusCode}');
      }

      final decoded = json.decode(resp.body);
      // Expecting a shape like: {"page":1,"pageSize":...,"total":...,"rows":[ {...}, {...} ]}
      final rows = (decoded is Map && decoded['rows'] is List)
          ? (decoded['rows'] as List)
          : const <dynamic>[];

      Map<String, dynamic>? mine;
      for (final r in rows) {
        if (r is Map) {
          final m = Map<String, dynamic>.from(r);
          // Try common keys seen across your data
          final uid = (m['userID'] ?? m['userId'] ?? m['userno'] ?? m['user_no'] ?? '').toString();
          if (uid == widget.userId) { mine = m; break; }
        }
      }

      if (mine == null) {
        _log(tag, 'No row found for userID', widget.userId);
        return;
      }

      final displayTimeRaw = (mine['displayTime'] ?? '').toString().trim();
      if (displayTimeRaw.isEmpty) {
        _log(tag, 'displayTime empty for user', widget.userId);
        return;
      }

      // e.g., "hkg" -> "HKG" but we need to match the *existing* RegionOption.id
      final target = displayTimeRaw.toLowerCase();

      // If regions are already loaded, apply immediately; else remember and apply later
      final matches = _regions.where((r) => r.id.toLowerCase() == target).toList();
      if (matches.isNotEmpty) {
        setState(() => _selectedRegionId = matches.first.id);
        _log(tag, 'Prefilled selection', _selectedRegionId!);
      } else {
        _pendingIso3FromLoginTable = target; // will apply after regions load
        _log(tag, 'Stored pending ISO3 (will apply after regions load)', target);
      }
    } catch (err, st) {
      _log('LOGIN_TABLE', 'Failed to prefill', err);
      _log('LOGIN_TABLE', 'Stack', st);
      setState(() => _loginTableError = 'Failed to prefill display time');
    } finally {
      if (mounted) setState(() => _loadingLoginTable = false);
    }
  }
  
  Future<void> _loadRegionsWithSites() async {
    setState(() { _loadingRegions = true; _regionsError = null; });
    const tag = 'REGIONS';
    try {
      final uri = Uri.parse(
        'https://nodejs-production-53a4.up.railway.app/phone/regions/with-sites'
      ).replace(queryParameters: {
        'timeoutMs': '20000',
        'concurrency': '48',
        'overallMs': '90000',
      });

      _log(tag, 'GET', uri);
      final resp = await http.get(uri).timeout(const Duration(seconds: 80));
      _log(tag, 'HTTP status', resp.statusCode);

      if (resp.statusCode != 200) {
        _log(tag, 'Non-200 body (first 500 chars)',
            resp.body.substring(0, resp.body.length.clamp(0, 500)));
        throw Exception('HTTP ${resp.statusCode}');
      }

      final decodedAny = json.decode(resp.body);
      if (decodedAny is! Map<String, dynamic>) {
        _log(tag, 'Unexpected top-level JSON type', decodedAny.runtimeType);
        throw Exception('Bad JSON from regions endpoint');
      }
      final decoded = decodedAny as Map<String, dynamic>;
      final rowsRaw = decoded['rows'];
      final rows = (rowsRaw is List) ? rowsRaw : const <dynamic>[];

      _log(tag, 'rows count', rows.length);

      final opts = <RegionOption>[];
      var idx = 0;
      for (final e in rows) {
        idx++;
        if (e is! Map) {
          _log(tag, 'Row $idx not a Map — skipping', e.runtimeType);
          continue;
        }
        final row = Map<String, dynamic>.from(e);
        final id = (row['regionID'] ?? row['id'] ?? '').toString();
        final name = (row['regionName'] ?? row['name'] ?? '').toString();

        // Extract timezone/offset with your existing logic
        Map<String, dynamic>? tz;
        final tzRaw = row['timezone'] ?? row['time'] ?? row['tz'];
        if (tzRaw is Map) {
          tz = Map<String, dynamic>.from(tzRaw);
        } else if (tzRaw is String && tzRaw.trim().isNotEmpty) {
          try { tz = Map<String, dynamic>.from(json.decode(tzRaw)); } catch (_) {}
        }
        
        if (tz == null) {
          tz = Map<String, dynamic>.from(row); // ← look on the row too
        }

        
          final datetime = tz?['datetime']?.toString();
          String? fromDatetime = _extractOffsetFromDatetime(datetime);

        // If ISO ends with 'Z', that explicitly means UTC
        if (fromDatetime == null && datetime != null && datetime.trim().endsWith('Z')) {
          fromDatetime = '+00:00';
        }

        String? fromFields = _extractOffsetFromRow(tz!); // tz points to row if no nested map

        String utcOffset = fromDatetime ?? fromFields ?? '+00:00';

        if (fromDatetime != null) {
          utcOffset = fromDatetime;
        } else {
          final off = tz?['offsetHrsVsUtc'];
          if (off is num) {
            utcOffset = _formatOffsetFromHours(off);
          } else if (off is String && off.isNotEmpty) {
            final n = num.tryParse(off);
            utcOffset = n != null ? _formatOffsetFromHours(n) : '+00:00';
          } else {
            utcOffset = '+00:00';
          }
        }
        final flag = _pickFlagEmoji(row);

        if (id.isEmpty || name.isEmpty) {
          _log(tag, 'Row $idx missing id/name — skipping', row);
          continue;
        }

        opts.add(RegionOption(
          id: id,
          name: name,
          flagEmoji: flag,
          utcOffset: utcOffset,
        ));
      }

      // Sort + set
      opts.sort((a, b) => a.name.compareTo(b.name));
      _log(tag, 'final options', opts.length);
      if (opts.isNotEmpty) {
        _log(tag, 'first option', '${opts.first.id} • ${opts.first.name}');
      }

      setState(() {
        _regions = opts;

        // Keep previous choice if any; ensure the selected id actually exists.
        if (_selectedRegionId != null &&
            !_regions.any((r) => r.id == _selectedRegionId)) {
          _log('REGIONS', 'previous selection no longer valid — clearing', _selectedRegionId);
          _selectedRegionId = null;
        }

        // ▼ NEW: If loginTable gave us a preferred displayTime (ISO‑3), apply it now
        if (_pendingIso3FromLoginTable != null) {
          final m = _regions
              .where((r) => r.id.toLowerCase() == _pendingIso3FromLoginTable)
              .toList();
          if (m.isNotEmpty) {
            _selectedRegionId = m.first.id;
            _log('REGIONS', 'Applied pending ISO3 from loginTable', _selectedRegionId!);
          }
          _pendingIso3FromLoginTable = null; // consume it
        }
      });

    } catch (err, st) {
      _log(tag, 'Failed to load regions', err);
      _log(tag, 'Stack', st);
      setState(() { _regionsError = 'Failed to load regions'; });
    } finally {
      if (mounted) setState(() { _loadingRegions = false; });
    }
  }


  Future<void> _loadUserAllergens() async {
    setState(() {
      _loadingUserAllergens = true;
      _userAllergenError = null;
    });
    try {
      final primary = Uri.parse('$_kUserApiBase/api/user/allergens')
          .replace(queryParameters: {'userID': widget.userId});
      final secondary = Uri.parse('$_kDataApiBase/api/user/allergens')
          .replace(queryParameters: {'userID': widget.userId});
      final resp = await _getWithFallback(primary, secondary: secondary);
      if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
      final decoded = json.decode(resp.body) as Map<String, dynamic>;
      final items =
          (decoded['items'] as List? ?? <dynamic>[]).map((e) => e.toString()).toSet();
      setState(() {
        _selectedAllergenIds
          ..clear()
          ..addAll(items);
      });
      _reconcileSelectedAllergensWithCatalog();
      _snapshotCurrentAsSaved();
    } catch (_) {
      setState(() => _userAllergenError = 'Failed to load user allergens');
    } finally {
      if (mounted) setState(() => _loadingUserAllergens = false);
    }
  }

  void _applyAllergenFilter(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) {
      setState(() => _visibleAllergens = _allergens);
      return;
    }
    setState(() {
      _visibleAllergens = _allergens.where((a) {
        final inName = a.name.toLowerCase().contains(q);
        final inCat = (a.category ?? '').toLowerCase().contains(q);
        return inName || inCat;
      }).toList();
    });
  }

  void _reconcileSelectedAllergensWithCatalog() {
    final catalogIds = _allergens.map((a) => a.id).toSet();
    final missing =
        _selectedAllergenIds.where((id) => !catalogIds.contains(id)).toList();
    if (missing.isEmpty) return;
    final placeholders = missing.map((id) {
      final displayName = id.replaceAll('_', ' ').trim();
      return Allergen(
        id: id,
        name: displayName.isEmpty ? id : displayName,
        category: 'Custom',
      );
    }).toList();
    setState(() {
      _allergens = [..._allergens, ...placeholders];
      _applyAllergenFilter(_allergenSearchCtrl.text);
    });
  }

  static const int _maxCustomAllergenLen = 16382;
  void _addCustomAllergen() {
    final name = _customAllergenNameCtrl.text.trim();
    final categoryRaw = _customAllergenCategoryCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter an allergen name')),
      );
      return;
    }
    if (name.length > _maxCustomAllergenLen) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Allergen name exceeds 65,535 characters')),
      );
      return;
    }
    if (categoryRaw.isNotEmpty && categoryRaw.length > _maxCustomAllergenLen) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Allergen category exceeds 65,535 characters')),
      );
      return;
    }
    final base = _slugify(name);
    var id = base;
    var n = 1;
    while (_allergens.any((a) => a.id == id)) {
      n++;
      id = '${base}_$n';
    }
    final category = categoryRaw.isEmpty ? 'Custom' : categoryRaw;
    final newAllergen = Allergen(id: id, name: name, category: category);
    setState(() {
      _allergens = [..._allergens, newAllergen];
      _applyAllergenFilter(_allergenSearchCtrl.text);
      _selectedAllergenIds.add(newAllergen.id);
    });
    _customAllergenNameCtrl.clear();
    _customAllergenCategoryCtrl.clear();
  }

  Future<void> _saveUserAllergens() async {
    try {
      final primary = Uri.parse('$_kUserApiBase/api/user/allergens');
      final secondary = Uri.parse('$_kDataApiBase/api/user/allergens');
      final resp = await _putWithFallback(
        primary,
        secondary: secondary,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'userID': widget.userId,
          'items': _selectedAllergenIds.toList(),
        }),
      );
      if (resp.statusCode != 200) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saving allergens failed (HTTP ${resp.statusCode})')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Allergens saved')),
        );
      }
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Network error saving allergens')),
      );
    }
  }

  /* ───────────────────────── Blacklist: search/load/save (unchanged) ───────────────────── */
  Future<void> _searchItems() async {
    final q = _blacklistSearchCtrl.text.trim();
    if (q.isEmpty) {
      setState(() {
        _itemResults = [];
        _itemSearchError = null;
      });
      return;
    }
    setState(() {
      _loadingItemSearch = true;
      _itemSearchError = null;
    });
    try {
      final primary = Uri.parse('$_kDataApiBase/api/items/search').replace(
        queryParameters: {
          'q': q,
          'field': _blacklistField,
          'limit': '50',
        },
      );
      final secondary = Uri.parse('$_kUserApiBase/api/items/search').replace(
        queryParameters: {
          'q': q,
          'field': _blacklistField,
          'limit': '50',
        },
      );
      final resp = await _getWithFallback(primary, secondary: secondary);
      if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
      final decoded = json.decode(resp.body) as Map<String, dynamic>;
      final list = (decoded['items'] as List? ?? []).cast<dynamic>();
      final results =
          list.map((e) => ItemRecord.fromJson(Map<String, dynamic>.from(e))).toList();
      setState(() {
        _itemResults = results;
        for (final it in results) {
          _itemLookup[it.id] = it;
        }
      });
    } catch (_) {
      setState(() => _itemSearchError = 'Search failed');
    } finally {
      if (mounted) setState(() => _loadingItemSearch = false);
    }
  }

  void _debouncedItemSearch([String? _]) {
    _blacklistDebounce?.cancel();
    _blacklistDebounce = Timer(const Duration(milliseconds: 300), _searchItems);
  }

  void _toggleBlacklistSelection(String itemId, bool selected) {
    setState(() {
      if (selected) {
        _selectedBlacklistIds.add(itemId);
        final match = _itemResults.firstWhere(
          (e) => e.id == itemId,
          orElse: () => ItemRecord(
            id: itemId,
            name: '',
            brand: '',
            quantity: '',
            feature: '',
            productColor: '',
            picWebsite: '',
          ),
        );
        _itemLookup[itemId] = match;
      } else {
        _selectedBlacklistIds.remove(itemId);
      }
    });
  }

  Future<void> _fetchItemsByIds(List<String> ids) async {
    final toFetch = ids.where((id) {
      final it = _itemLookup[id];
      return it == null ||
          (it.name.isEmpty && it.brand.isEmpty && it.picWebsite.isEmpty);
    }).toList();
    if (toFetch.isEmpty) return;

    const int batchSize = 50;
    for (int i = 0; i < toFetch.length; i += batchSize) {
      final batch =
          toFetch.sublist(i, (i + batchSize < toFetch.length) ? i + batchSize : toFetch.length);
      try {
        final primary = Uri.parse('$_kDataApiBase/api/items/batchByIds');
        final secondary = Uri.parse('$_kUserApiBase/api/items/batchByIds');
        http.Response? resp;
        try {
          resp = await http
              .post(primary, headers: {'Content-Type': 'application/json'}, body: jsonEncode({'ids': batch}))
              .timeout(const Duration(seconds: 12));
          if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
        } catch (_) {
          resp = await http
              .post(secondary, headers: {'Content-Type': 'application/json'}, body: jsonEncode({'ids': batch}))
              .timeout(const Duration(seconds: 12));
          if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
        }
        final decoded = json.decode(resp.body) as Map<String, dynamic>;
        final list = (decoded['items'] as List? ?? <dynamic>[]).cast<dynamic>();
        final records =
            list.map((e) => ItemRecord.fromJson(Map<String, dynamic>.from(e as Map))).toList();
        setState(() {
          for (final it in records) {
            _itemLookup[it.id] = it;
          }
        });
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Some item details could not be loaded')),
          );
        }
      }
    }
  }

  Future<void> _loadUserBlacklist() async {
    setState(() {
      _loadingUserBlacklist = true;
      _userBlacklistError = null;
    });
    try {
      final primary = Uri.parse('$_kUserApiBase/api/user/blacklist')
          .replace(queryParameters: {'userID': widget.userId});
      final secondary = Uri.parse('$_kDataApiBase/api/user/blacklist')
          .replace(queryParameters: {'userID': widget.userId});
      final resp = await _getWithFallback(primary, secondary: secondary);
      if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
      final decoded = json.decode(resp.body) as Map<String, dynamic>;
      final items = (decoded['items'] as List? ?? <dynamic>[])
          .map((e) => e.toString())
          .where((s) => s.isNotEmpty)
          .toSet();
      setState(() {
        _selectedBlacklistIds
          ..clear()
          ..addAll(items);
      });
      await _fetchItemsByIds(_selectedBlacklistIds.toList());
      _snapshotCurrentAsSaved();
    } catch (_) {
      setState(() => _userBlacklistError = 'Failed to load blacklist');
    } finally {
      if (mounted) setState(() => _loadingUserBlacklist = false);
    }
  }

  Future<void> _saveUserBlacklist() async {
    try {
      final primary = Uri.parse('$_kUserApiBase/api/user/blacklist');
      final secondary = Uri.parse('$_kDataApiBase/api/user/blacklist');
      final resp = await _putWithFallback(
        primary,
        secondary: secondary,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'userID': widget.userId,
          'items': _selectedBlacklistIds.toList(),
        }),
      );
      if (resp.statusCode != 200) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saving blacklist failed (HTTP ${resp.statusCode})')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Blacklist saved')),
        );
      }
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Network error saving blacklist')),
      );
    }
  }
  
  Future<void> _saveDisplayTime() async {
    // If the user hasn't picked a region, skip silently (or toast).
    if (_selectedRegionId == null) {
      _log('REGIONS', 'No region selected — skipping displayTime update');
      return;
    }

    // Your screenshot shows lower-case ISO3, e.g., "gbr"
    final iso3Lower = _selectedRegionId!.toLowerCase();

    try {
      // Primary: the endpoint from your screenshot (on f031)
      final primary = Uri.parse('$_kUserApiBase/api/user/displayTime');

      // Optional: try the data base as a fallback if you also deploy there
      final secondary = Uri.parse('$_kDataApiBase/api/user/displayTime');

      final resp = await _putWithFallback(
        primary,
        secondary: secondary,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'userID': widget.userId,
          'displayTime': iso3Lower,
        }),
      );

      if (resp.statusCode != 200) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saving display time failed (HTTP ${resp.statusCode})')),
        );
      } else {
        _log('REGIONS', 'displayTime updated', {'userID': widget.userId, 'displayTime': iso3Lower});
      }
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Network error saving display time')),
      );
    }
  }


  /* ───────────────────────── Settings: load existing ───────────────────────── */
  Future<void> _loadExistingSettings() async {
    setState(() {
      _loadingSettings = true;
      _settingsLoadError = null;
    });
    try {
      final primary = Uri.parse('$_kUserApiBase/api/user/settings')
          .replace(queryParameters: {'userID': widget.userId});
      final secondary = Uri.parse('$_kDataApiBase/api/user/settings')
          .replace(queryParameters: {'userID': widget.userId});
      final resp = await _getWithFallback(primary, secondary: secondary);
      if (resp.statusCode == 200) {
        final m = json.decode(resp.body) as Map<String, dynamic>;
        final ms = (m['monthlySalary'] as num?)?.toDouble();
        final ts = (m['targetMonthlySaving'] as num?)?.toDouble();

        // Prefer new fields; keep legacy fallbacks.
        final homeAddr = (m['homeAdd'] ?? m['homeAddCode'] ?? '').toString();
        final workAddr = (m['workAdd'] ?? m['workAddCode'] ?? '').toString();

        // If API sent separate postcode keys (legacy), use them first;
        // otherwise, try to extract from the address strings.
        String homePc = (m['homeAddCode'] ?? '').toString();
        String workPc = (m['workAddCode'] ?? '').toString();
        final re = RegExp(r'\b([A-Z]{1,2}\d[A-Z\d]?\s*\d[A-Z]{2})\b', caseSensitive: false);

        if (homePc.isEmpty && homeAddr.isNotEmpty) {
          final mh = re.firstMatch(homeAddr.toUpperCase());
          if (mh != null) homePc = mh.group(1)!.toUpperCase();
        }
        if (workPc.isEmpty && workAddr.isNotEmpty) {
          final mw = re.firstMatch(workAddr.toUpperCase());
          if (mw != null) workPc = mw.group(1)!.toUpperCase();
        }

        setState(() {
          _salary = ms;
          _targetSaving = ts;

          _homeAddress = homeAddr.isEmpty ? null : homeAddr;
          _workAddress = workAddr.isEmpty ? null : workAddr;

          _postcode = homePc.isEmpty ? null : homePc.toUpperCase();
          _workPostcode = workPc.isEmpty ? null : workPc.toUpperCase();

          if (_salary != null) _salaryCtrl.text = _asFixed2(_salary);
          if (_targetSaving != null) _targetSavingCtrl.text = _asFixed2(_targetSaving);

          _homeAddressCtrl.text = _homeAddress ?? '';
          _workAddressCtrl.text = _workAddress ?? '';
          _postcodeCtrl.text = _postcode ?? '';
          _workPostcodeCtrl.text = _workPostcode ?? '';
        });

        _snapshotCurrentAsSaved();
      } else if (resp.statusCode == 404) {
        setState(() => _settingsLoadError = null); // no prior settings
        _snapshotCurrentAsSaved();
      } else {
        setState(() => _settingsLoadError = 'Failed to load (HTTP ${resp.statusCode})');
      }
    } catch (_) {
      setState(() => _settingsLoadError = 'Unable to load settings');
    } finally {
      if (mounted) setState(() => _loadingSettings = false);
    }
  }

  /* ───────────────────────────────── Lifecycle ─────────────────────────────── */
  @override
  void initState() {
    super.initState();
    _fetchAllergens();
    _loadExistingSettings();
    _loadUserAllergens();
    _loadUserBlacklist();

    // Load both in parallel; whichever finishes second will reconcile the selection.
    _loadRegionsWithSites();
    _prefillDisplayTimeFromLoginTable();
  }


  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  void dispose() {
    _salaryCtrl.dispose();
    _targetSavingCtrl.dispose();
    _postcodeCtrl.dispose();
    _workPostcodeCtrl.dispose();
    _homeAddressCtrl.dispose();
    _workAddressCtrl.dispose();
    _allergenSearchCtrl.dispose();
    _customAllergenNameCtrl.dispose();
    _customAllergenCategoryCtrl.dispose();
    _blacklistSearchCtrl.dispose();
    _blacklistDebounce?.cancel();
    super.dispose();
  }

  /* ────────────────────────────── Map picking helpers ──────────────────────── */
  // Uses your MapSearchScreen which returns a Place via Navigator.pop(context, place).
  // Prefers Place.postcode; falls back to extracting from formattedAddress if needed. [1]
  Future<void> _pickHomeFromMap() async {
    final Place? p = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const MapSearchScreen()),
    );
    if (p == null) return;

    setState(() {
      // Address
      final addr = (p.formattedAddress).trim();
      if (addr.isNotEmpty) _homeAddressCtrl.text = addr;

      // Postcode from Place.postcode or extract from address text
      final pc = (p.postcode ?? '').trim().toUpperCase();
      if (pc.isNotEmpty) {
        _postcodeCtrl.text = pc;
      } else if (p.formattedAddress.isNotEmpty) {
        final re = RegExp(r'\b([A-Z]{1,2}\d[A-Z\d]?\s*\d[A-Z]{2})\b', caseSensitive: false);
        final m = re.firstMatch(p.formattedAddress.toUpperCase());
        if (m != null) _postcodeCtrl.text = m.group(1)!.toUpperCase();
      }
    });
  }

  Future<void> _pickWorkFromMap() async {
    final Place? p = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const MapSearchScreen()),
    );
    if (p == null) return;

    setState(() {
      // Address
      final addr = (p.formattedAddress).trim();
      if (addr.isNotEmpty) _workAddressCtrl.text = addr;

      // Postcode from Place.postcode or extract from address text
      final pc = (p.postcode ?? '').trim().toUpperCase();
      if (pc.isNotEmpty) {
        _workPostcodeCtrl.text = pc;
      } else if (p.formattedAddress.isNotEmpty) {
        final re = RegExp(r'\b([A-Z]{1,2}\d[A-Z\d]?\s*\d[A-Z]{2})\b', caseSensitive: false);
        final m = re.firstMatch(p.formattedAddress.toUpperCase());
        if (m != null) _workPostcodeCtrl.text = m.group(1)!.toUpperCase();
      }
    });
  }

  /* ─────────────────────────────────── UI ──────────────────────────────────── */
  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).padding.bottom;
    
    final hasSelection = _selectedRegionId != null &&
          _regions.any((r) => r.id == _selectedRegionId);
      _log('REGIONS',
          'build dropdown: sel=$_selectedRegionId, exists=$hasSelection, total=${_regions.length}');

    return WillPopScope(
      
      onWillPop: () async {
        if (!_hasUnsavedChanges()) return true;

        final choice = await _confirmSaveBeforeLeave(leavingAction: "going back");

        if (choice == 'save') {
          await _handleSave();
          return !_hasUnsavedChanges();  // pop only once
        } 
        if (choice == 'discard') {
          return true;                   // let it pop immediately
        }
        return false;                    // cancel
      },

      child: Scaffold(
        appBar: AppBar(
          title: const Text('Settings'),
          
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () async {
              if (!mounted) return;

              if (!_hasUnsavedChanges()) {
                Navigator.of(context).pop();
                return;
              }

              final choice = await _confirmSaveBeforeLeave(leavingAction: "going back");

              if (choice == 'save') {
                await _handleSave();
                if (!mounted) return;
                Navigator.of(context).pop();            // ← only pop once
              } else if (choice == 'discard') {
                Navigator.of(context).pop();            // ← direct pop; no double press
              }
            },
          ),

          actions: [
            IconButton(
              tooltip: 'Log out',
              icon: const Icon(Icons.logout),
              onPressed: () async {
                await _handleLogoutWithOptionalSave();
              },
            ),
          ],
        ),
        body: ListView(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + bottom),
          children: [
            if (_loadingSettings)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: LinearProgressIndicator(),
              ),
            if (_settingsLoadError != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(_settingsLoadError!,
                    style: const TextStyle(color: Colors.red)),
              ),

            /* ─────────────── Account & Login ─────────────── */
            const _SectionHeader(title: 'Account & Login'),
            Card(
              child: ListTileTheme(
                data: const ListTileThemeData(
                  contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                ),
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.badge_outlined),
                      title: const Text('User ID'),
                      subtitle: Text(widget.userId),
                      trailing: IconButton(
                        icon: const Icon(Icons.copy),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: widget.userId));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('User ID copied')),
                          );
                        },
                      ),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.lock_open_outlined),
                      title: const Text('Login method'),
                      subtitle: Text(widget.identifierType),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.account_circle_outlined),
                      title: const Text('Identifier'),
                      subtitle: Text(widget.identifierValue),
                      trailing: IconButton(
                        icon: const Icon(Icons.copy),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: widget.identifierValue));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Identifier copied')),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            /* ─────────────── Unified form ─────────────── */
            Form(
              key: _formKey,
              child: Column(
                children: [
                  /* ── Personal Finance ── */
                  const _SectionHeader(title: 'Personal Finance'),
                  TextFormField(
                    controller: _salaryCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Monthly salary',
                      prefixText: '£',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [_moneyInputFormatter],
                    validator: (v) => _validateMoneyLoose(v, fieldName: 'Salary'),
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _targetSavingCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Target saving',
                      prefixText: '£',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [_moneyInputFormatter],
                    validator: (v) => _validateMoneyLoose(v, fieldName: 'Saving'),
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: 24),

                  /* ── Home Address/Postcode (pick from map) ── */
                  const _SectionHeader(title: 'Home Address'),
                  Align(
                    alignment: Alignment.centerRight,
                    child: OutlinedButton.icon(
                      onPressed: _pickHomeFromMap,
                      icon: const Icon(Icons.map_outlined),
                      label: const Text('Pick from map'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _homeAddressCtrl,
                    readOnly: true,
                    
                    decoration: const InputDecoration(
                      labelText: 'Home Address (auto from map)',
                      hintText: 'Select from map to fill',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.home_outlined),
                    ),
                    
                  ),
                  /*
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _postcodeCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Home Postcode',
                      hintText: 'e.g. BS1 3DX',
                      border: OutlineInputBorder(),
                    ),
                    
                    //validator: _validatePostcode,
                  ),
                  */
                  const SizedBox(height: 24),

                  /* ── Work Address/Postcode (pick from map) ── */
                  const _SectionHeader(title: 'Workplace Address'),
                  Align(
                    alignment: Alignment.centerRight,
                    child: OutlinedButton.icon(
                      onPressed: _pickWorkFromMap,
                      icon: const Icon(Icons.map_outlined),
                      label: const Text('Pick from map'),
                    ),
                  ),
                  
                  const SizedBox(height: 8),
                  TextField(
                    controller: _workAddressCtrl,
                    readOnly: true,
                    decoration: const InputDecoration(
                      labelText: 'Workplace Address (auto from map)',
                      hintText: 'Select from map to fill',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.work_outline),
                    ),
                  ),
  /*
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _workPostcodeCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Workplace Postcode',
                      hintText: 'e.g. BS1 3DX',
                      border: OutlineInputBorder(),
                    ),
                    
                    //validator: _validatePostcode,
                  ),
                  */
                  const SizedBox(height: 32),

                  /* ── Allergens (unchanged) ── */
                  const _SectionHeader(title: 'Allergens'),
                  if (_loadingAllergens) ...[
                    const SizedBox(height: 8),
                    const LinearProgressIndicator(),
                    const SizedBox(height: 8),
                    const Text('Loading allergens...'),
                  ] else if (_allergenLoadError != null) ...[
                    Text(_allergenLoadError!, style: const TextStyle(color: Colors.red)),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: _fetchAllergens,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry'),
                    ),
                  ] else ...[
                    if (_selectedAllergenIds.isNotEmpty) ...[
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: _selectedAllergens
                            .map(
                              (a) => InputChip(
                                label: Text(a.name),
                                avatar: a.category != null
                                    ? CircleAvatar(
                                        child: Text(
                                          a.category!.isNotEmpty
                                              ? a.category![0].toUpperCase()
                                              : '?',
                                        ),
                                      )
                                    : null,
                                onDeleted: () {
                                  setState(() => _selectedAllergenIds.remove(a.id));
                                },
                              ),
                            )
                            .toList(),
                      ),
                      const SizedBox(height: 12),
                    ],
                    TextField(
                      controller: _allergenSearchCtrl,
                      decoration: InputDecoration(
                        labelText: 'Search allergens',
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: _allergenSearchCtrl.text.isEmpty
                            ? null
                            : IconButton(
                                tooltip: 'Clear',
                                icon: const Icon(Icons.clear),
                                onPressed: () {
                                  _allergenSearchCtrl.clear();
                                  _applyAllergenFilter('');
                                },
                              ),
                      ),
                      onChanged: _applyAllergenFilter,
                    ),
                    const SizedBox(height: 12),
                    Card(
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        side: const BorderSide(color: Colors.black12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Add your own allergen',
                                style: Theme.of(context).textTheme.titleSmall),
                            const SizedBox(height: 8),
                            TextField(
                              controller: _customAllergenNameCtrl,
                              decoration: const InputDecoration(
                                labelText: 'Allergen name *',
                                hintText: 'e.g., “Blue cheese”, “Sesame oil”',
                                border: OutlineInputBorder(),
                              ),
                              textInputAction: TextInputAction.next,
                            ),
                            const SizedBox(height: 8),
                            TextField(
                              controller: _customAllergenCategoryCtrl,
                              decoration: const InputDecoration(
                                labelText: 'Category (optional)',
                                hintText: 'e.g., Dairy, Nuts, Seeds',
                                border: OutlineInputBorder(),
                              ),
                              onSubmitted: (_) => _addCustomAllergen(),
                            ),
                            const SizedBox(height: 8),
                            Align(
                              alignment: Alignment.centerRight,
                              child: FilledButton.icon(
                                onPressed: _addCustomAllergen,
                                icon: const Icon(Icons.add),
                                label: const Text('Add allergen'),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.black12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      constraints: const BoxConstraints(maxHeight: 300),
                      child: _visibleAllergens.isEmpty
                          ? const Center(
                              child: Padding(
                                padding: EdgeInsets.all(16),
                                child: Text('No allergens match your search'),
                              ),
                            )
                          : Scrollbar(
                              child: ListView.builder(
                                itemCount: _visibleAllergens.length,
                                itemBuilder: (context, i) {
                                  final a = _visibleAllergens[i];
                                  final selected = _selectedAllergenIds.contains(a.id);
                                  final isCustom =
                                      (a.category ?? '').toLowerCase() == 'custom';
                                  final subtitleText = [
                                    if (a.category != null) a.category!,
                                    if (isCustom) 'Custom',
                                  ].join(' • ');
                                  return CheckboxListTile(
                                    dense: true,
                                    title: Text(a.name),
                                    subtitle:
                                        subtitleText.isEmpty ? null : Text(subtitleText),
                                    value: selected,
                                    onChanged: (val) {
                                      setState(() {
                                        if (val == true) {
                                          _selectedAllergenIds.add(a.id);
                                        } else {
                                          _selectedAllergenIds.remove(a.id);
                                        }
                                      });
                                    },
                                  );
                                },
                              ),
                            ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Selected: ${_selectedAllergenIds.length}',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        TextButton.icon(
                          onPressed: _selectedAllergenIds.isEmpty
                              ? null
                              : () => setState(_selectedAllergenIds.clear),
                          icon: const Icon(Icons.clear_all),
                          label: const Text('Clear all'),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 32),

                  /* ── Blacklist (unchanged) ── */
                  const _SectionHeader(title: 'Blacklist Items'),
                  if (_userBlacklistError != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(_userBlacklistError!,
                          style: const TextStyle(color: Colors.red)),
                    ),
                  if (_itemSearchError != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(_itemSearchError!,
                          style: const TextStyle(color: Colors.red)),
                    ),
                  Row(
                    children: [
                      DropdownButton<String>(
                        value: _blacklistField,
                        items: const [
                          DropdownMenuItem(value: 'all', child: Text('All fields')),
                          DropdownMenuItem(value: 'name', child: Text('Name')),
                          DropdownMenuItem(value: 'brand', child: Text('Brand')),
                          DropdownMenuItem(value: 'quantity', child: Text('Quantity')),
                          DropdownMenuItem(value: 'feature', child: Text('Feature')),
                          DropdownMenuItem(value: 'productcolor', child: Text('Colour')),
                        ],
                        onChanged: (v) {
                          if (v == null) return;
                          setState(() => _blacklistField = v);
                          _debouncedItemSearch();
                        },
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: _blacklistSearchCtrl,
                          decoration: InputDecoration(
                            labelText: 'Search items to blacklist',
                            border: const OutlineInputBorder(),
                            prefixIcon: const Icon(Icons.search),
                            suffixIcon: _blacklistSearchCtrl.text.isEmpty
                                ? null
                                : IconButton(
                                    icon: const Icon(Icons.clear),
                                    onPressed: () {
                                      _blacklistSearchCtrl.clear();
                                      setState(() => _itemResults = []);
                                    },
                                  ),
                          ),
                          onChanged: _debouncedItemSearch,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.black12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    constraints: const BoxConstraints(maxHeight: 300),
                    child: _loadingItemSearch
                        ? const Center(
                            child: Padding(
                              padding: EdgeInsets.all(16),
                              child: CircularProgressIndicator(),
                            ),
                          )
                        : (_itemResults.isEmpty
                            ? const Center(
                                child: Padding(
                                  padding: EdgeInsets.all(16),
                                  child: Text('No results. Try a different query.'),
                                ),
                              )
                            : Scrollbar(
                                child: ListView.builder(
                                  itemCount: _itemResults.length,
                                  itemBuilder: (context, i) {
                                    final it = _itemResults[i];
                                    final selected = _selectedBlacklistIds.contains(it.id);
                                    final subtitle = [
                                      if (it.brand.isNotEmpty) 'Brand: ${it.brand}',
                                      if (it.quantity.isNotEmpty) 'Qty: ${it.quantity}',
                                      if (it.feature.isNotEmpty) 'Feature: ${it.feature}',
                                      if (it.productColor.isNotEmpty)
                                        'Colour: ${it.productColor}',
                                    ].join(' • ');
                                    return CheckboxListTile(
                                      dense: true,
                                      value: selected,
                                      onChanged: (v) =>
                                          _toggleBlacklistSelection(it.id, v == true),
                                      title: Text(it.name.isNotEmpty ? it.name : '(no name)'),
                                      subtitle: subtitle.isEmpty ? null : Text(subtitle),
                                      secondary: it.picWebsite.isNotEmpty
                                          ? ClipOval(
                                              child: Image.network(
                                                it.picWebsite,
                                                width: 40,
                                                height: 40,
                                                fit: BoxFit.cover,
                                                errorBuilder: (_, __, ___) =>
                                                    const Icon(Icons.image_not_supported),
                                              ),
                                            )
                                          : const CircleAvatar(
                                              child: Icon(Icons.image_not_supported)),
                                    );
                                  },
                                ),
                              )),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Selected: ${_selectedBlacklistIds.length}',
                          style: Theme.of(context).textTheme.bodyMedium),
                      TextButton.icon(
                        onPressed: _selectedBlacklistIds.isEmpty
                            ? null
                            : () => setState(() => _selectedBlacklistIds.clear()),
                        icon: const Icon(Icons.clear_all),
                        label: const Text('Clear all'),
                      ),
                    ],
                  ),
                  if (_selectedBlacklistIds.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Card(
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        side: const BorderSide(color: Colors.black12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Selected items (preview)',
                                style: Theme.of(context).textTheme.titleSmall),
                            const SizedBox(height: 8),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxHeight: 260),
                              child: Scrollbar(
                                child: ListView.separated(
                                  itemCount: _selectedBlacklistIds.length,
                                  separatorBuilder: (_, __) => const Divider(height: 1),
                                  itemBuilder: (context, index) {
                                    final ids =
                                        _selectedBlacklistIds.toList()..sort();
                                    final id = ids[index];
                                    final it = _itemLookup[id];
                                    final hasDetails = it != null;
                                    final subtitleLines = <String>[
                                      if (hasDetails && it!.brand.isNotEmpty)
                                        'Brand: ${it.brand}',
                                      if (hasDetails && it!.quantity.isNotEmpty)
                                        'Qty: ${it.quantity}',
                                      if (hasDetails && it!.feature.isNotEmpty)
                                        'Feature: ${it.feature}',
                                      if (hasDetails && it!.productColor.isNotEmpty)
                                        'Colour: ${it.productColor}',
                                      if (!hasDetails)
                                        'Details unavailable yet — run a search to populate.',
                                    ];
                                    Widget leading;
                                    if (hasDetails && it!.picWebsite.isNotEmpty) {
                                      leading = ClipRRect(
                                        borderRadius: BorderRadius.circular(6),
                                        child: Image.network(
                                          it.picWebsite,
                                          width: 48,
                                          height: 48,
                                          fit: BoxFit.cover,
                                          errorBuilder: (_, __, ___) =>
                                              const Icon(Icons.image_not_supported),
                                        ),
                                      );
                                    } else {
                                      leading = const CircleAvatar(
                                        radius: 24,
                                        child: Icon(Icons.image_not_supported),
                                      );
                                    }
                                    return ListTile(
                                      leading: leading,
                                      title: Text(
                                        hasDetails && it!.name.isNotEmpty
                                            ? it.name
                                            : '(name unavailable)',
                                      ),
                                      subtitle: subtitleLines.isEmpty
                                          ? null
                                          : Text(subtitleLines.join(' • ')),
                                    );
                                  },
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 32),

                  // ▼ NEW: Region & Timezone dropdown — placed below Blacklist and above Save
                  const _SectionHeader(title: 'Display Time (wait for 2 minutes for the loading)'),
                  if (_regionsError != null) ...[
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(_regionsError!, style: const TextStyle(color: Colors.red)),
                    ),
                  ] else if (_loadingRegions) ...[
                    const Padding(
                      padding: EdgeInsets.only(bottom: 8),
                      child: LinearProgressIndicator(),
                    ),
                  ] else ...[
                    
                    DropdownButtonFormField<String>(
                        value: hasSelection ? _selectedRegionId : null, // ✅ guard invalid value
                        isExpanded: true,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          labelText: 'Choose your region',
                          hintText: 'Flag • Region • UTC offset',
                        ),
                        items: _regions.map((opt) {
                          final label = '${opt.flagEmoji} ${opt.name} (UTC${opt.utcOffset})';
                          return DropdownMenuItem<String>(
                            value: opt.id,
                            child: Text(label),
                          );
                        }).toList(),
                        
                        onChanged: (v) {
                          // Keep the UI state in sync
                          setState(() => _selectedRegionId = v);

                          // Find the selected RegionOption by id (which is your ISO‑3 code from regionID)
                          final match = _regions.where((r) => r.id == v).toList();
                          if (match.isNotEmpty) {
                            final iso3 = match.first.id.toUpperCase(); // e.g., "AFG"
                            // Prints to VS Code Debug Console/Terminal
                            _log('REGIONS', 'Selected ISO3', iso3);
                            // If you prefer a single-line print without _log:
                            // debugPrint('[REGIONS] Selected ISO3: $iso3 • ${match.first.name}');
                          }
                        },

                      ),

                  ],
                  const SizedBox(height: 32),

                  // ── Save button ── (existing code remains)
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _savingSettings ? null : _handleSave,
                      child: _savingSettings
                          ? const SizedBox(
                              height: 22, width: 22,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Text('Save Settings'),
                    ),
                  ),

                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /* ─────────────────────────────── Save flow ──────────────────────────────── */
  Future<void> _handleSave() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final parsedSalary = double.tryParse(_salaryCtrl.text.trim());
    final parsedSaving = double.tryParse(_targetSavingCtrl.text.trim());
    if (parsedSalary == null || parsedSaving == null) return;

    if (parsedSaving >= parsedSalary) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Target saving must be less than salary')),
      );
      return;
    }

    final homeAddr = _homeAddressCtrl.text.trim();
    final workAddr = _workAddressCtrl.text.trim();
    final home = _postcodeCtrl.text.trim().toUpperCase();
    final work = _workPostcodeCtrl.text.trim().toUpperCase();

    setState(() => _savingSettings = true);

    try {
      final resp = await _putWithFallback(
        Uri.parse('$_kUserApiBase/api/user/settings'),
        secondary: Uri.parse('$_kDataApiBase/api/user/settings'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'userID': widget.userId,
          'monthlySalary': _salaryCtrl.text,
          'targetMonthlySaving': _targetSavingCtrl.text,
          'homeAdd': homeAddr,
          'workAdd': workAddr,
          'homeAddCode': home,
          'workAddCode': work,
        }),
      );

      if (resp.statusCode == 200) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Settings saved')),
        );

        await _saveUserAllergens();
        await _saveUserBlacklist();
        await _saveDisplayTime();

        _snapshotCurrentAsSaved();
      } else {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Save failed (${resp.statusCode})')));
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Network error saving settings')),
      );
    } finally {
      if (mounted) setState(() => _savingSettings = false);
    }
  }


  /* ─────────────────────────────── Logout flow ─────────────────────────────── */
  Future<void> _handleLogoutWithOptionalSave() async {
    if (!_hasUnsavedChanges()) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Log out?'),
          content: const Text('You will return to the login screen.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Log out'),
            ),
          ],
        ),
      );
      if (ok == true && context.mounted) {
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (_) => const LoginPage()),
          (route) => false,
        );
      }
      return;
    }

    final choice =
        await _confirmSaveBeforeLeave(leavingAction: 'logging out');
    if (choice == 'save') {
      await _handleSave();
      if (!mounted) return;
      if (!_hasUnsavedChanges()) {
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (_) => const LoginPage()),
          (route) => false,
        );
      }
    } else if (choice == 'discard') {
      if (context.mounted) {
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (_) => const LoginPage()),
          (route) => false,
        );
      }
    }
  }
}

/* ────────────────────────── Section header widget ─────────────────────────── */
class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
      ),
    );
  }
}