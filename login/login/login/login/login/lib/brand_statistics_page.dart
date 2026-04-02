import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'dart:ui' as ui;
import 'dart:math' as math; // ADDED

// ───────────────────────────────────────────────────────────────────────────────
// Models
// ───────────────────────────────────────────────────────────────────────────────
class PurchaseDetail {
  final double qty;
  final double price;
  final DateTime date;

  const PurchaseDetail({
    required this.qty,
    required this.price,
    required this.date,
  });
}

// ───────────────────────────────────────────────────────────────────────────────
// Small tuple-ish wrappers to keep types tidy
// ───────────────────────────────────────────────────────────────────────────────
class _BarBuildResult {
  final List<BarChartGroupData> groups;
  _BarBuildResult(this.groups);
  operator [](int _) => groups;
}

class _StackSlice {
  final String brand;
  final double from;
  final double to;
  _StackSlice({required this.brand, required this.from, required this.to});
}

// ───────────────────────────────────────────────────────────────────────────────
// Page
// ───────────────────────────────────────────────────────────────────────────────
class BrandStatisticsPage extends StatefulWidget {
  final String userId;
  const BrandStatisticsPage({super.key, required this.userId});

  @override
  State<BrandStatisticsPage> createState() => _BrandStatisticsPageState();
}

class _BrandStatisticsPageState extends State<BrandStatisticsPage> {

  // ── CHART SIZING (NEW): reserve horizontal space per group (bar)
  static const double _barWidth = 28.0;     // width of each stacked bar (per item)
  static const double _groupSpace = 18.0;   // horizontal gap between adjacent bars
  static const double _rightReserved = 12.0;// small right padding for symmetry

  /// Aggregated data for the chart; each map holds:
  /// { "label": category(itemName), "total": double, <brand>: qty(double) }
  List<Map<String, dynamic>> _processedData = [];

  /// Raw transaction details: category(itemName) -> brand -> list of purchases
  final Map<String, Map<String, List<PurchaseDetail>>> _purchasesByCategoryBrand = {};

  /// For mapping stackIndex -> brand for each bar group (category)
  /// e.g. [ ["Nike","Adidas","Zara"], ["Apple","Dell",...] , ...]
  List<List<String>> _brandOrderPerGroup = [];

  bool _isLoading = false;

  /// Optional brand filter (from legend tap)
  String? _selectedBrand;

  // ── NEW: basic API base URL (change if your host differs)
  static const String _baseUrl = 'https://nodejs-production-53a4.up.railway.app'; // CHANGED: match your working host

  // ── NEW: simple status for UI hint (API / Mock)
  String _dataSourceLabel = 'API';

  // ── NEW: Date Range State
  DateTimeRange? _selectedDateRange;

  // ── instance-local brand styles (no globals)
  final Map<String, Color> _brandColors = {};
  final Map<String, String> _brandMarkers = {};
  int _brandColorIndex = 0;

  static const List<Color> _distinctColors = [
    Colors.blue,
    Colors.red,
    Colors.green,
    Colors.orange,
    Colors.purple,
    Colors.cyan,
    Colors.amber,
    Colors.teal,
    Colors.indigo,
    Colors.pink,
    Colors.lime,
    Colors.brown,
    Colors.deepOrange,
    Colors.lightBlue,
    Colors.blueGrey,
    
  ];

  static const List<String> _markerPool = [
    '◆','●','■','▲','★','◆','●','■','▲','✚','✱','✦',
  'A','B','C','D','E','F','G','H','I','J','K','L', 'M', 'N', 'O', 'P', 'Q', 'R', 'S','T', 'U', 'V', 'W', 'X', 'Y', 'Z',
  '1', '2', '3', '4', '5', '6', '7', '8', '9', '0',
  'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z'
  ];

  String _markerForBrand(String b) {
    // deterministic: simple rolling-hash to index
    final idx = (b.codeUnits.fold<int>(0, (a, c) => (a * 31 + c) & 0x7fffffff)) % _markerPool.length;
    return _markerPool[idx];
  }

  // Chart layout metrics used by both painter & touch logic
  final double _leftReserved = 30.0;
  final double _bottomReserved = 48.0; // give labels breathing room
  Size _chartSize = const Size(0, 0);

  @override
  void initState() {
    super.initState();
    _loadFromApi(); // ← use userId from previous pages (HomePage → StatisticsLandingPage)
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // Data loading (API first; fallback to existing mock)
  // ─────────────────────────────────────────────────────────────────────────────

  // ── UPDATED: Load rows from the API with date parameters
  // CHANGED: _loadFromApi() now passes the selected range into _fetchBrandRows.
  Future<void> _loadFromApi() async {
    setState(() => _isLoading = true);
    try {
      final rows = await _fetchBrandRows(widget.userId, range: _selectedDateRange); // CHANGED
      final processed = _processApiRows(rows);
      setState(() {
        _processedData = processed;
        _isLoading = false;
        _dataSourceLabel = 'API';
      });
    } catch (e) {
      debugPrint('brand_statistics: API failed → $e; loading mock instead.');
      _loadHardcodedData();
      setState(() {
        _dataSourceLabel = 'Mock';
      });
    }
  }


  // ── NEW: Date Picker Function
  Future<void> _selectDateRange() async {
    final DateTimeRange? picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
      initialDateRange: _selectedDateRange,
    );

    if (picked != null && picked != _selectedDateRange) {
      setState(() {
        _selectedDateRange = picked;
      });
      _loadFromApi(); // Reload with new dates
    }
  }

  /// Calls: GET /api/item-input/by-brand?userID=<userId>
  /// Maps server fields → local schema expected by `_processApiRows`.
  /// IMPORTANT: qty ← itemNo (your requirement)

  // CHANGED: method signature to accept the DateTimeRange (optional).
  Future<List<Map<String, dynamic>>> _fetchBrandRows(
    String userId, {
    DateTimeRange? range, // ADDED
  }) async {
    // ADDED: build query parameters
    final qp = <String, String>{ 'userID': userId };
    if (range != null) {
      // Use ISO dates without time for clarity
      qp['start'] = DateFormat('yyyy-MM-dd').format(range.start);
      qp['end']   = DateFormat('yyyy-MM-dd').format(range.end);
    }

    final uri = Uri.parse('$_baseUrl/api/item-input/by-brand')
        .replace(queryParameters: qp); // CHANGED

    debugPrint('brand_statistics: GET $uri'); // unchanged is fine
    final resp = await http.get(uri, headers: const {'Accept': 'application/json'});
    if (resp.statusCode != 200) {
      throw Exception('HTTP ${resp.statusCode}: ${resp.body}');
    }

    final decoded = json.decode(resp.body);
    final rawRows = (decoded is Map && decoded['rows'] is List)
        ? (decoded['rows'] as List)
        : const <dynamic>[];


  final List<Map<String, dynamic>> rows = [];
  for (final r in rawRows) {
    if (r is! Map) continue;
    rows.add({
      
    'category': (r['itemName'] ?? 'Unknown').toString(),
    'brand'   : (r['brand'] ?? 'Unknown').toString(),
    'qty'     : _toDouble(r['itemNo'] ?? 0),    // qty = itemNo (kept)
    'price'   : _toDouble(r['priceValue'] ?? 0),
    'date'    : _normalizeDate(r['createdAt']), // CHANGED: now returns ISO or ''

    });
  }

  // ADDED: local fallback filter if API returned more than needed or ignores dates
  if (range != null) {
    final startLocal = DateTime(range.start.year, range.start.month, range.start.day);
    final endLocal   = DateTime(range.end.year, range.end.month, range.end.day, 23, 59, 59);

    // Compare in UTC for consistency since _normalizeDate returns UTC ISO
    final startUtc = startLocal.toUtc();
    final endUtc   = endLocal.toUtc();

    return rows.where((row) {
      final iso = row['date']?.toString() ?? '';
      final dt = iso.isEmpty ? null : DateTime.tryParse(iso);
      if (dt == null) return false; // CHANGED: drop unparseable dates
      return !dt.isBefore(startUtc) && !dt.isAfter(endUtc);
    }).toList();
  }


  return rows;
}


  // Existing function (kept). Now only used as fallback.
  void _loadHardcodedData() {
    // Do not delete per your instruction.
    // Intentionally kept exactly as a fallback dataset for the page to render
    // when the API is not reachable.
    // Each entry represents a *transaction* (one buying instance)
    final List<Map<String, dynamic>> mockRows = [
      // Clothes
      {'category': 'Clothes', 'brand': 'Nike', 'qty': 2, 'price': 120.0, 'date': '2026-01-14'},
      {'category': 'Clothes', 'brand': 'Nike', 'qty': 3, 'price': 180.0, 'date': '2026-02-02'},
      {'category': 'Clothes', 'brand': 'Adidas', 'qty': 1, 'price': 60.0, 'date': '2026-02-05'},
      {'category': 'Clothes', 'brand': 'Adidas', 'qty': 2, 'price': 110.0, 'date': '2026-02-21'},
      {'category': 'Clothes', 'brand': 'Zara', 'qty': 4, 'price': 140.0, 'date': '2026-01-22'},
      {'category': 'Clothes', 'brand': 'Zara', 'qty': 3, 'price': 105.0, 'date': '2026-02-12'},
      {'category': 'Clothes', 'brand': 'H&M', 'qty': 4, 'price': 88.0, 'date': '2026-01-29'},
      {'category': 'Clothes', 'brand': 'Gucci', 'qty': 1, 'price': 900.0, 'date': '2026-01-18'},
      // Computer
      {'category': 'Computer', 'brand': 'Apple', 'qty': 1, 'price': 1299.0, 'date': '2026-02-10'},
      {'category': 'Computer', 'brand': 'Apple', 'qty': 1, 'price': 199.0, 'date': '2026-02-25'},
      {'category': 'Computer', 'brand': 'Dell', 'qty': 2, 'price': 999.0, 'date': '2026-01-25'},
      {'category': 'Computer', 'brand': 'Dell', 'qty': 3, 'price': 450.0, 'date': '2026-02-27'},
      {'category': 'Computer', 'brand': 'Microsoft', 'qty': 1, 'price': 149.0, 'date': '2026-01-09'},
      {'category': 'Computer', 'brand': 'Microsoft', 'qty': 1, 'price': 99.0, 'date': '2026-02-20'},
      {'category': 'Computer', 'brand': 'HP', 'qty': 3, 'price': 780.0, 'date': '2026-01-30'},
      {'category': 'Computer', 'brand': 'Lenovo', 'qty': 4, 'price': 1100.0, 'date': '2026-02-15'},
      // Electronics
      {'category': 'Electronics', 'brand': 'Sony', 'qty': 2, 'price': 400.0, 'date': '2026-01-16'},
      {'category': 'Electronics', 'brand': 'Sony', 'qty': 2, 'price': 300.0, 'date': '2026-02-08'},
      {'category': 'Electronics', 'brand': 'Samsung', 'qty': 6, 'price': 1500.0, 'date': '2026-01-27'},
      {'category': 'Electronics', 'brand': 'Logitech', 'qty': 5, 'price': 250.0, 'date': '2026-02-03'},
      {'category': 'Electronics', 'brand': 'Logitech', 'qty': 3, 'price': 180.0, 'date': '2026-02-18'},
      {'category': 'Electronics', 'brand': 'Bose', 'qty': 2, 'price': 500.0, 'date': '2026-02-22'},
      {'category': 'Electronics', 'brand': 'Sonos', 'qty': 1, 'price': 399.0, 'date': '2026-01-19'},
      // Toys
      {'category': 'Toys', 'brand': 'Lego', 'qty': 6, 'price': 360.0, 'date': '2026-01-05'},
      {'category': 'Toys', 'brand': 'Lego', 'qty': 4, 'price': 240.0, 'date': '2026-02-14'},
      {'category': 'Toys', 'brand': 'Nintendo', 'qty': 5, 'price': 250.0, 'date': '2026-02-11'},
      {'category': 'Toys', 'brand': 'Mattel', 'qty': 3, 'price': 90.0, 'date': '2026-01-23'},
      // Food
      {'category': 'Food', 'brand': 'Nestle', 'qty': 5, 'price': 25.0, 'date': '2026-02-09'},
      {'category': 'Food', 'brand': 'Pepsi', 'qty': 9, 'price': 27.0, 'date': '2026-01-31'},
      {'category': 'Food', 'brand': 'Coke', 'qty': 8, 'price': 24.0, 'date': '2026-02-13'},
    ];

    setState(() {
      _processedData = _processApiRows(mockRows);
      _isLoading = false;
    });
  }

  /// Convert raw rows (already normalized to keys we expect) into:
  /// 1) aggregated chart data and 2) raw `_purchasesByCategoryBrand`
  List<Map<String, dynamic>> _processApiRows(List<dynamic> rows) {
    final Map<String, Map<String, dynamic>> groups = {};
    final Set<String> uniqueBrands = {};
    _purchasesByCategoryBrand.clear();

    for (final row in rows) {
      final String category = (row['category'] ?? 'Other').toString(); // ← itemName
      final String brand = (row['brand'] ?? 'Other').toString();
      final double qty = _toDouble(row['qty']);
      final double price = _toDouble(row['price']);
      
      final String dateIso = (row['date'] ?? '').toString();     // CHANGED
      final DateTime? date = dateIso.isEmpty ? null : DateTime.tryParse(dateIso);
      if (date == null) continue; // ADDED: skip bad rows; don't fabricate "today"


      // Aggregate for chart
      groups.putIfAbsent(category, () => {"label": category, "total": 0.0});
      groups[category]![brand] = (groups[category]![brand] ?? 0.0) + qty;
      groups[category]!["total"] = (groups[category]!["total"] as double) + qty;
      uniqueBrands.add(brand);

      // Keep raw details
      _purchasesByCategoryBrand.putIfAbsent(category, () => {});
      _purchasesByCategoryBrand[category]!.putIfAbsent(brand, () => <PurchaseDetail>[]);
      _purchasesByCategoryBrand[category]![brand]!.add(
        PurchaseDetail(qty: qty, price: price, date: date),
      );
    }

    // assign colors & markers for new brands
    for (final b in uniqueBrands) {
      _brandColors.putIfAbsent(b, () {
        final color = _distinctColors[_brandColorIndex % _distinctColors.length];
        _brandColorIndex++;
        return color;
      });
      _brandMarkers.putIfAbsent(b, () => _markerForBrand(b));
    }

    return groups.values.toList()..sort((a, b) => a["label"].compareTo(b["label"]));
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // Build
  // ─────────────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final double maxY = _calculateMaxY();

    return Scaffold(
      appBar: AppBar(
        title: const Text("Brand Statistics"),
        actions: [
          // ── NEW: Date Range Filter Button
          IconButton(
            icon: Icon(Icons.date_range, 
              color: _selectedDateRange != null ? Colors.blue : null),
            tooltip: 'Filter by Date',
            onPressed: _selectDateRange,
          ),
          Center(
            child: Padding(
              padding: const EdgeInsets.only(right: 8.0),
              child: Text(
                _dataSourceLabel,
                style: TextStyle(
                  fontSize: 12,
                  color: _dataSourceLabel == 'API' ? Colors.green.shade700 : Colors.orange.shade700,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _loadFromApi,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (_selectedDateRange != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8.0),
                    child: Text(
                      "Showing: ${DateFormat('yyyy-MM-dd').format(_selectedDateRange!.start)} to ${DateFormat('yyyy-MM-dd').format(_selectedDateRange!.end)}",
                      style: const TextStyle(fontSize: 12, color: Colors.blueGrey, fontWeight: FontWeight.bold),
                    ),
                  ),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16.0),
                  child: Text(
                    "X-Axis: Item Name \nY-Axis: Units Bought (qty = itemNo)",
                    textAlign: TextAlign.center,
                    style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blueGrey),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 20, 20, 10),
                    child: LayoutBuilder(

                      builder: (context, constraints) {
                        // ─────────────────────────────────────────────────────────────
                        // 1) Build data structures (unchanged)
                        // ─────────────────────────────────────────────────────────────
                        final built = _buildBarGroups();                     
                        final barGroups = built.$1.groups;
                        _brandOrderPerGroup = built.$2;

                        // Precompute stack maps for the custom marker painter (unchanged)
                        final stackMaps = <List<_StackSlice>>[];
                        
                        // ADDED: List to store the current visible totals for Math calculations
                        final List<double> visibleTotals = [];

                        for (var gi = 0; gi < _processedData.length; gi++) {
                          final d = _processedData[gi];
                          double acc = 0;
                          final slices = <_StackSlice>[];
                          final brands = _sortedBrands();
                          for (final b in brands) {
                            if (_selectedBrand != null && b != _selectedBrand) continue;
                            final double v = (d[b] ?? 0.0);
                            if (v > 0) {
                              slices.add(_StackSlice(brand: b, from: acc, to: acc + v));
                              acc += v;
                            }
                          }
                          stackMaps.add(slices);
                          // ADDED: Capture the total height of this specific bar after filtering
                          visibleTotals.add(acc);
                        }

                        // ── NEW: Statistical Calculations ──
                        // ── UPDATED: Statistical Calculations ──
                        double averageValue = 0;
                        double medianValue = 0;

                        // CHANGE: Build a filtered list that removes zeros ONLY when a brand is selected.
                        //         If no brand is selected, keep behavior as before (use all bars).
                        final List<double> totalsForStats = (_selectedBrand == null)
                            ? List<double>.from(visibleTotals)            // no filter → include all
                            : visibleTotals.where((v) => v > 0).toList(); // brand filter → exclude zeros

                        if (totalsForStats.isNotEmpty) {
                          // Mean
                          averageValue =
                              totalsForStats.reduce((a, b) => a + b) / totalsForStats.length;

                          // Median (correct for odd/even)
                          final List<double> sorted = List<double>.from(totalsForStats)..sort();
                          final int n = sorted.length;

                          if (n == 1) {
                            medianValue = sorted[0];
                          } else if (n.isOdd) {
                            medianValue = sorted[n ~/ 2];
                          } else {
                            final int hi = n ~/ 2, lo = hi - 1;
                            medianValue = (sorted[lo] + sorted[hi]) / 2.0;
                          }
                        } else {
                          // CHANGE: If everything filtered out, keep 0 to avoid NaN lines.
                          averageValue = 0;
                          medianValue = 0;
                        }

                        // ADDED: One unified maxY used by both the BarChart and the CustomPainter
                        final double renderMaxY = math.max(maxY, averageValue + 5);

                        // ─────────────────────────────────────────────────────────────
                        // 2) NEW — Reserve horizontal space for each bar (key change)
                        // ─────────────────────────────────────────────────────────────
                        final int groupCount = _processedData.length;
                        final double contentWidth = _leftReserved
                            + (groupCount * _barWidth)                              
                            + ((groupCount > 1 ? groupCount - 1 : 0) * _groupSpace) 
                            + _rightReserved;

                        final bool needsHScroll = contentWidth > constraints.maxWidth;
                        final double canvasWidth = needsHScroll ? contentWidth : constraints.maxWidth;

                        _chartSize = Size(canvasWidth, constraints.maxHeight);

                        
                        // ─────────────────────────────────────────────────────────────
                        // 3) Build the actual chart on a fixed-width canvas
                        // ─────────────────────────────────────────────────────────────

                        Widget chartCanvas = SizedBox(
                          width: canvasWidth,
                          child: Stack(
                            children: [
                              BarChart(
                                BarChartData(
                                  // CHANGED: Use unified renderMaxY so Avg/Median never get clipped
                                  maxY: renderMaxY,

                                  barGroups: barGroups,
                                  alignment: BarChartAlignment.spaceBetween,
                                  groupsSpace: _groupSpace,

                                  extraLinesData: ExtraLinesData(
                                    // ADDED: Ensure Avg/Median lines draw on top of bars & markers
                                    extraLinesOnTop: true,
                                    horizontalLines: [
                                      // ─────────────── AVERAGE LINE ───────────────
                                      HorizontalLine(
                                        y: averageValue,
                                        color: Colors.red.withOpacity(0.9),
                                        strokeWidth: 3,
                                        dashArray: [5, 5],
                                        label: HorizontalLineLabel(
                                          show: true,
                                          // CHANGED: Move to left to avoid clipping on right edge
                                          alignment: Alignment.topLeft,
                                          style: const TextStyle(
                                            color: Colors.red,
                                            fontWeight: FontWeight.bold,
                                            fontSize: 10,
                                            backgroundColor: Colors.white70,
                                          ),
                                          labelResolver: (line) => 'Avg: ${line.y.toStringAsFixed(1)}',
                                        ),
                                      ),

                                      // ─────────────── MEDIAN LINE ───────────────
                                      HorizontalLine(
                                        y: medianValue,
                                        color: Colors.yellow.shade700,
                                        strokeWidth: 3,
                                        label: HorizontalLineLabel(
                                          show: true,
                                          alignment: Alignment.topRight,
                                          style: TextStyle(
                                            color: Colors.yellow.shade900,
                                            fontWeight: FontWeight.bold,
                                            fontSize: 10,
                                            backgroundColor: Colors.white70,
                                          ),
                                          labelResolver: (line) => 'Med: ${line.y.toStringAsFixed(1)}',
                                        ),
                                      ),
                                    ],
                                  ),

                                  gridData: const FlGridData(show: true, drawVerticalLine: false),
                                  borderData: FlBorderData(show: false),

                                  titlesData: FlTitlesData(
                                    leftTitles: AxisTitles(
                                      sideTitles: SideTitles(
                                        showTitles: true,
                                        reservedSize: _leftReserved,
                                      ),
                                    ),
                                    bottomTitles: AxisTitles(
                                      sideTitles: SideTitles(
                                        showTitles: true,
                                        reservedSize: _bottomReserved,
                                        getTitlesWidget: (v, m) {
                                          final i = v.toInt();
                                          if (i < 0 || i >= _processedData.length) {
                                            return const SizedBox.shrink();
                                          }
                                          final label = _processedData[i]['label'].toString();
                                          return Padding(
                                            padding: const EdgeInsets.only(top: 8.0),
                                            child: Transform.rotate(
                                              angle: -0.5,
                                              child: Text(
                                                label,
                                                textAlign: TextAlign.center,
                                                style: const TextStyle(
                                                  fontSize: 10,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                    topTitles: const AxisTitles(),
                                    rightTitles: const AxisTitles(),
                                  ),

                                  barTouchData: BarTouchData(
                                    enabled: true,
                                    handleBuiltInTouches: true,
                                    touchCallback: (event, response) {
                                      if (!event.isInterestedForInteractions || response?.spot == null) return;
                                      final spot = response!.spot!;
                                      final groupIndex = spot.touchedBarGroupIndex;
                                      final rodData = spot.touchedRodData;

                                      final pos = event.localPosition;
                                      if (pos == null) return;

                                      final chartHeight = (_chartSize.height - _bottomReserved).clamp(1.0, double.infinity);
                                      final normalized = (1 - (pos.dy / chartHeight)).clamp(0.0, 1.0);
                                      final valueY = normalized * renderMaxY;

                                      final stacks = rodData.rodStackItems;
                                      if (stacks.isEmpty) return;

                                      int resolvedStackIndex = stacks.length - 1;
                                      for (int i = 0; i < stacks.length; i++) {
                                        final s = stacks[i];
                                        if (valueY >= s.fromY && valueY <= s.toY) {
                                          resolvedStackIndex = i;
                                          break;
                                        }
                                      }

                                      if (groupIndex >= 0 &&
                                          groupIndex < _brandOrderPerGroup.length &&
                                          resolvedStackIndex >= 0 &&
                                          resolvedStackIndex < _brandOrderPerGroup[groupIndex].length) {
                                        final category = _processedData[groupIndex]['label'].toString();
                                        final brand = _brandOrderPerGroup[groupIndex][resolvedStackIndex];
                                        showBrandDetailsBottomSheet(
                                          context: context,
                                          category: category,
                                          brand: brand,
                                        );
                                      }
                                    },
                                  ),
                                ),
                              ),

                              // Overlay painter for stack markers
                              IgnorePointer(
                                child: CustomPaint(
                                  size: Size(canvasWidth, constraints.maxHeight),
                                  painter: BarMarkerPainter(
                                    processedData: _processedData,
                                    brandColors: _brandColors,
                                    brandMarkers: _brandMarkers,
                                    selectedBrand: _selectedBrand,
                                    // CHANGED: sync painter with unified maxY
                                    maxY: renderMaxY,
                                    leftReserved: _leftReserved,
                                    bottomReserved: _bottomReserved,
                                    groupCount: _processedData.length,
                                    stackMaps: stackMaps,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );


                        if (needsHScroll) {
                          return SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            physics: const BouncingScrollPhysics(),
                            child: chartCanvas,
                          );
                        } else {
                          return chartCanvas; 
                        }
                      },
                    )
                  ),
                ),
                _buildScrollableLegend(),
              ],
            ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // Chart helpers
  // ─────────────────────────────────────────────────────────────────────────────
  /// Returns Tuple of (_BarBuildResult, List<List<String>> brandOrderPerGroup)
  (_BarBuildResult item1, List<List<String>> item2) _buildBarGroups() {
    final List<String> allBrands = _sortedBrands(); // stable order
    final List<BarChartGroupData> groups = [];
    final List<List<String>> brandOrderPerGroup = [];

    // A responsive width would be nice; keep simple here:
    //const double barWidth = 32;

    for (int index = 0; index < _processedData.length; index++) {
      final d = _processedData[index];
      final List<BarChartRodStackItem> stacks = [];
      final List<String> orderForThisGroup = [];
      double currentStackHeight = 0;

      for (final b in allBrands) {
        if (_selectedBrand != null && b != _selectedBrand) continue;
        final double val = (d[b] ?? 0.0);
        if (val > 0) {
          stacks.add(BarChartRodStackItem(
            currentStackHeight,
            currentStackHeight + val,
            _brandColors[b]!,
          ));
          orderForThisGroup.add(b);
          currentStackHeight += val;
        }
      }
      brandOrderPerGroup.add(orderForThisGroup);

      groups.add(
        BarChartGroupData(
          x: index,
          barRods: [
            BarChartRodData(
              toY: currentStackHeight,
              width: _barWidth,
              rodStackItems: stacks,
              borderRadius: BorderRadius.circular(4),
            ),
          ],
        ),
      );
    }
    return (_BarBuildResult(groups), brandOrderPerGroup);
  }

  List<String> _sortedBrands() {
    final list = _brandColors.keys.toList()..sort();
    return list;
  }

  double _calculateMaxY() {
    double max = 0;
    for (final d in _processedData) {
      double currentTotal = 0;
      for (final b in _brandColors.keys) {
        // FIX: Use logical OR to include either all brands (no filter)
        //      or only the selected brand (when filtered).
        if (_selectedBrand == null || b == _selectedBrand) { // CHANGED
          currentTotal += (d[b] ?? 0.0);
        }
      }
      if (currentTotal > max) max = currentTotal;
    }
    // (kept) some headroom so the lines render clearly
    return max + 10; // unchanged
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // Legend & details bottom sheet
  // ─────────────────────────────────────────────────────────────────────────────
  Widget _buildScrollableLegend() {
    return Container(
      constraints: const BoxConstraints(maxHeight: 220),
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: Colors.grey.withOpacity(0.05),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          const Text("Brands & Markers", style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          Expanded(
            child: SingleChildScrollView(
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: _brandColors.entries.map((entry) {
                  final isSelected = _selectedBrand == entry.key;
                  final marker = _brandMarkers[entry.key];
                  return Semantics(
                    label: 'Filter brand ${entry.key}',
                    button: true,
                    selected: isSelected,
                    child: GestureDetector(
                      onTap: () => setState(() => _selectedBrand = isSelected ? null : entry.key),
                      child: AnimatedOpacity(
                        duration: const Duration(milliseconds: 200),
                        opacity: _selectedBrand == null || isSelected ? 1.0 : 0.3,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: entry.value.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: entry.value, width: isSelected ? 2 : 1),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                marker ?? '',
                                style: TextStyle(fontSize: 14, color: entry.value, fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(width: 6),
                              Text(entry.key, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void showBrandDetailsBottomSheet({
    required BuildContext context,
    required String category,
    required String brand,
  }) {
    final details = _purchasesByCategoryBrand[category]?[brand] ?? const <PurchaseDetail>[];
    final totalUnits = details.fold<double>(0, (sum, p) => sum + p.qty);
    final count = details.length;
    final color = _brandColors[brand] ?? Colors.black;
    final marker = _brandMarkers[brand] ?? '';

    // Build "Dates by unit" list: each date repeats qty times → matches total units
    final List<String> unitDates = [];
    for (final p in details) {
      final dateStr = p.date.toIso8601String().split('T').first;
      final times = p.qty.toInt(); // assuming integer "units"
      for (int i = 0; i < times; i++) {
        unitDates.add(dateStr);
      }
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Header
                Row(
                  children: [
                    Container(
                      width: 12, height: 12,
                      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      "$marker $brand — $category",
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    _statChip(label: "Total units", value: _fmtNum(totalUnits)),
                    const SizedBox(width: 8),
                    _statChip(label: "Times purchased", value: "$count"),
                  ],
                ),
                const SizedBox(height: 12),
                const Divider(height: 1),

                // Transactions
                Flexible(
                  child: details.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.all(24),
                          child: Text("No transactions recorded."),
                        )
                      : ListView.separated(
                          shrinkWrap: true,
                          itemCount: details.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (context, i) {
                            final p = details[i];
                            final dateStr = p.date.toIso8601String().split('T').first;
                            return ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Text("Qty: ${_fmtNum(p.qty)} • £${_fmtNum(p.price)}"),
                              subtitle: Text("Date: $dateStr"),
                            );
                          },
                        ),
                ),

                // Dates by unit (new): the count of chips equals total units
                if (unitDates.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      "Dates (by unit):",
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: Colors.grey.shade800,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 160),
                    child: SingleChildScrollView(
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: unitDates
                            .map((d) => Chip(
                                  label: Text(d),
                                  backgroundColor: Colors.grey.shade100,
                                  side: BorderSide(color: Colors.grey.shade300),
                                ))
                            .toList(),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      "Shown ${unitDates.length} dates to match $brand units.",
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _statChip({required String label, required String value}) {
    return Chip(
      labelPadding: const EdgeInsets.symmetric(horizontal: 8),
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text("$label: ", style: const TextStyle(fontWeight: FontWeight.w600)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
        ],
      ),
      backgroundColor: Colors.grey.shade100,
      side: BorderSide(color: Colors.grey.shade300),
    );
  }

  String _fmtNum(num n) {
    // Simple, no intl dependency
    if (n is int || n == n.roundToDouble()) return n.toStringAsFixed(0);
    return n.toStringAsFixed(2);
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // Utilities
  // ─────────────────────────────────────────────────────────────────────────────
  double _toDouble(dynamic v) {
    if (v == null) return 0.0;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0.0;
  }

  
// CHANGED: replace previous _normalizeDate with a robust parser that keeps the real API date
/// Normalizes various date strings to full ISO-8601 (UTC) like "2026-03-01T07:49:10.000Z".
/// Supports:
///   • ISO-8601 strings (kept as-is, normalized to UTC)
///   • "Sun Mar 01 2026 07:49:10 GMT+0000 (Coordinated Universal Time)" (server format)
///   • "yyyy-MM-dd" (treated as local midnight → UTC)
  String _normalizeDate(dynamic raw) {
    if (raw == null) return ''; // CHANGED: no "today" fallback; return empty to signal failure

    final s = raw.toString().trim();
    if (s.isEmpty) return '';

    // 1) Try strict ISO-8601
    final iso = DateTime.tryParse(s);
    if (iso != null) {
      return iso.toUtc().toIso8601String(); // CHANGED: normalize to UTC ISO
    }

    // 2) Handle server format:
    //    "Sun Mar 01 2026 07:49:10 GMT+0000 (Coordinated Universal Time)"
    //    Strategy:
    //       - Drop trailing parenthetical: " (Coordinated Universal Time)"
    //       - Parse prefix with a regex, then build DateTime with timezone offset
    final cleaned = s.replaceAll(RegExp(r'\s*\(.*\)$'), ''); // ADDED
    // cleaned now looks like: "Sun Mar 01 2026 07:49:10 GMT+0000"

    final re = RegExp(
      r'^[A-Za-z]{3}\s+([A-Za-z]{3})\s+(\d{1,2})\s+(\d{4})\s+(\d{2}):(\d{2}):(\d{2})\s+GMT([+\-]\d{4})$',
    ); // ADDED
    final m = re.firstMatch(cleaned);
    if (m != null) {
      final monthStr = m.group(1)!;
      final day = int.parse(m.group(2)!);
      final year = int.parse(m.group(3)!);
      final hh = int.parse(m.group(4)!);
      final mm = int.parse(m.group(5)!);
      final ss = int.parse(m.group(6)!);
      final tz = m.group(7)!; // e.g., +0000, +0530, -0400

      const months = {
        'Jan': 1, 'Feb': 2, 'Mar': 3, 'Apr': 4, 'May': 5, 'Jun': 6,
        'Jul': 7, 'Aug': 8, 'Sep': 9, 'Oct': 10, 'Nov': 11, 'Dec': 12,
      };
      final month = months[monthStr] ?? 1;

      // Build a naive UTC and then shift by the inverse of the offset
      // Example: "GMT+0530" means local = UTC + 5:30 → UTC = local - 5:30
      final sign = tz.startsWith('-') ? -1 : 1;
      final tzNum = int.parse(tz.substring(1)); // e.g. 530, 400, 0
      final tzHours = tzNum ~/ 100;
      final tzMins = tzNum % 100;
      final offset = Duration(hours: sign * tzHours, minutes: sign * tzMins);

      // Interpret the clock values as if they were in that GMT offset zone, then convert to UTC.
      final local = DateTime.utc(year, month, day, hh, mm, ss);
      final utc = local.subtract(offset);

      return utc.toIso8601String(); // ADDED
    }

    // 3) Handle plain yyyy-MM-dd
    final short = RegExp(r'^\d{4}-\d{2}-\d{2}$');
    if (short.hasMatch(s)) {
      final parts = s.split('-').map(int.parse).toList();
      final utc = DateTime.utc(parts[0], parts[1], parts[2]);
      return utc.toIso8601String();
    }

    // As a last resort, do not fabricate "today"; return empty to signal "unknown"
    return '';
  }

}

// ───────────────────────────────────────────────────────────────────────────────
// Painter that draws text markers onto the chart stacks (aligned & contrast-safe)
// ───────────────────────────────────────────────────────────────────────────────
class BarMarkerPainter extends CustomPainter {
  final List<Map<String, dynamic>> processedData;
  final Map<String, Color> brandColors;
  final Map<String, String> brandMarkers;
  final String? selectedBrand;
  final double maxY;
  final double leftReserved;
  final double bottomReserved;
  final int groupCount;

  /// For each group, ordered slices with [from, to] (same as rodStackItems)
  final List<List<_StackSlice>> stackMaps;

  BarMarkerPainter({
    required this.processedData,
    required this.brandColors,
    required this.brandMarkers,
    required this.selectedBrand,
    required this.maxY,
    required this.leftReserved,
    required this.bottomReserved,
    required this.groupCount,
    required this.stackMaps,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final double chartWidth = size.width - leftReserved;
    final double chartHeight = size.height - bottomReserved;
    if (groupCount == 0) return;
    final double groupWidth = chartWidth / groupCount;

    for (int i = 0; i < groupCount; i++) {
      if (i >= stackMaps.length) continue;
      final double centerX = leftReserved + (i * groupWidth) + (groupWidth / 2);
      for (final s in stackMaps[i]) {
        final double mid = (s.from + s.to) / 2.0;
        final double pixelY = (1 - (mid / maxY)) * chartHeight;
        final marker = brandMarkers[s.brand] ?? '?';
        final fill = brandColors[s.brand] ?? Colors.black;
        final fg = _bestOnColor(fill);
        _drawText(canvas, marker, Offset(centerX, pixelY), fg);
      }
    }
  }

  Color _bestOnColor(Color c) {
    // YIQ luma to choose black/white for legibility
    final luma = (c.red * 299 + c.green * 587 + c.blue * 114) / 1000;
    return luma >= 128 ? Colors.black : Colors.white;
  }

  void _drawText(Canvas canvas, String text, Offset center, Color color) {
    final textPainter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: color, fontSize: 14, fontWeight: FontWeight.bold),
      ),
      // CHANGED: Use lowercase 'ltr' instead of 'LTR'
      textDirection: ui.TextDirection.ltr, 
    )..layout();
    
    // Centers the text marker precisely within the bar segment
    textPainter.paint(
      canvas, 
      center - Offset(textPainter.width / 2, textPainter.height / 2),
    );
  }


  @override
  bool shouldRepaint(covariant BarMarkerPainter oldDelegate) =>
      oldDelegate.selectedBrand != selectedBrand ||
      oldDelegate.processedData != processedData ||
      oldDelegate.maxY != maxY ||
      oldDelegate.leftReserved != leftReserved ||
      oldDelegate.bottomReserved != bottomReserved ||
      oldDelegate.groupCount != groupCount ||
      !identical(oldDelegate.stackMaps, stackMaps);
}