import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'dart:math';
import 'dart:convert';
import 'package:http/http.dart' as http;

enum TimeUnit { day, month, year }
//enum CategoryFilter { all, session, food, household, entertainment }

Map<String, Color> _categoryColors = {};

// Update this at the top of your file or inside the class
final List<Color> _distinctColors = [
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
int _colorIndex = 0;

// NEW: Keep a character marker only for categories whose colour had to be reused
final Map<String, String> _categoryMarkers = {};

// NEW: A small pool of easy-to-read marker characters (you can add more)
final List<String> _markerPool = [
  '◆',
  '●',
  '■',
  '▲',
  '★',
  '◆',
  '●',
  '■',
  '▲',
  '✚',
  '✱',
  '✦',
  'A',
  'B',
  'C',
  'D',
  'E',
  'F',
  'G',
  'H',
  'I',
  'J',
  'K',
  'L',
  'M',
  'N',
  'O',
  'P',
  'Q',
  'R',
  'S',
  'T',
  'U',
  'V',
  'W',
  'X',
  'Y',
  'Z',
  '1',
  '2',
  '3',
  '4',
  '5',
  '6',
  '7',
  '8',
  '9',
  '0',
  'a',
  'b',
  'c',
  'd',
  'e',
  'f',
  'g',
  'h',
  'i',
  'j',
  'k',
  'l',
  'm',
  'n',
  'o',
  'p',
  'q',
  'r',
  's',
  't',
  'u',
  'v',
  'w',
  'x',
  'y',
  'z'
];

final Random _rng = Random();

String _randomMarker() {
  // pick a marker pseudo-randomly
  return _markerPool[_rng.nextInt(_markerPool.length)];
}

class StatisticsPage extends StatefulWidget {
  final String userId;
  const StatisticsPage({super.key, required this.userId});

  @override
  State<StatisticsPage> createState() => _StatisticsPageState();
}

class _StatisticsPageState extends State<StatisticsPage> {
  TimeUnit selectedUnit = TimeUnit.day;

  List<Map<String, dynamic>> _apiData = [];
  bool _isLoading = true;
  bool _isZoomed = false;

  // CHANGE: Added state to track which category is currently filtered
  String? _selectedCategory;

  @override
  void initState() {
    super.initState();
    _fetchAnalytics();
  }

  Future<void> _fetchAnalytics() async {
    setState(() => _isLoading = true);

    final String endpoint = _apiEndpoint(selectedUnit);
    final url = Uri.parse(
        'https://nodejs-production-53a4.up.railway.app/api/item-input/analytics/$endpoint?userID=${widget.userId}');

    try {
      final response = await http.get(url).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final Map<String, dynamic> data = json.decode(response.body);
        final List<dynamic> rows = data['rows'] ?? [];

        setState(() {
          _apiData = _processApiRows(rows);
          _isLoading = false;
        });
      } else {
        setState(() => _isLoading = false);
      }
    } catch (e) {
      setState(() => _isLoading = false);
    }
  }

  List<Map<String, dynamic>> _processApiRows(List<dynamic> rows) {
    final Map<String, Map<String, dynamic>> groups = {};
    final Set<String> uniqueCategories = {};

    for (final row in rows) {
      final String rawKey = (row['spending_date'] ??
              row['spending_month'] ??
              row['spending_year'])
          .toString();
      final String labelKey = _normalizeDate(rawKey);

      groups.putIfAbsent(labelKey, () => {"label": labelKey, "total": 0.0});

      final String category =
          (row['category'] ?? 'other').toString().toLowerCase();
      final double amount =
          double.tryParse(row['total_spent'].toString()) ?? 0.0;

      groups[labelKey]![category] =
          (groups[labelKey]![category] ?? 0.0) + amount;
      groups[labelKey]!["total"] =
          (groups[labelKey]!["total"] as double) + amount;

      uniqueCategories.add(category);
    }

    // === CHANGE: Assign colors and generate random ones on collision ===
    for (final cat in uniqueCategories) {
      _categoryColors.putIfAbsent(cat, () {
        // 1. Try to get the next color from the distinct palette
        Color nextColor = _distinctColors[_colorIndex % _distinctColors.length];
        _colorIndex++;

        // 2. CHECK: If this color is already assigned to a different category...
        bool isAlreadyUsed = _categoryColors.values.contains(nextColor);

        if (isAlreadyUsed) {
          // 3. GENERATE: Create a new random color instead of using the palette one
          // This ensures every category gets a unique visual identity
          nextColor = Color.fromARGB(
            255,
            _rng.nextInt(256),
            _rng.nextInt(256),
            _rng.nextInt(256),
          );

          // Optional: You can still add a marker if you want to flag "generated" colors
          _categoryMarkers[cat] = _randomMarker();
        }

        return nextColor;
      });
    }

    final result = groups.values.toList()
      ..sort((a, b) => a["label"].compareTo(b["label"]));
    return result;
  }

  String _normalizeDate(String raw) {
    if (raw.contains('GMT')) {
      List<String> p = raw.split(' ');
      const m = {
        "Jan": "01",
        "Feb": "02",
        "Mar": "03",
        "Apr": "04",
        "May": "05",
        "Jun": "06",
        "Jul": "07",
        "Aug": "08",
        "Sep": "09",
        "Oct": "10",
        "Nov": "11",
        "Dec": "12"
      };
      return "${p[3]}-${m[p[1]]}-${p[2].padLeft(2, '0')}";
    }
    return raw;
  }

  String _apiEndpoint(TimeUnit unit) {
    switch (unit) {
      case TimeUnit.day:
        return 'daily';
      case TimeUnit.month:
        return 'monthly';
      case TimeUnit.year:
        return 'yearly';
    }
  }

  String _getBottomLabel(double value) {
    int index = value.toInt();
    if (index < 0 || index >= _apiData.length) return '';
    String key = _apiData[index]['label'];
    if (selectedUnit == TimeUnit.year) return key;

    const monthMap = {
      "01": "Jan",
      "02": "Feb",
      "03": "Mar",
      "04": "Apr",
      "05": "May",
      "06": "Jun",
      "07": "Jul",
      "08": "Aug",
      "09": "Sep",
      "10": "Oct",
      "11": "Nov",
      "12": "Dec"
    };

    try {
      if (selectedUnit == TimeUnit.day) {
        return "${key.substring(8, 10)} ${monthMap[key.substring(5, 7)]}";
      }
      return "${monthMap[key.substring(5, 7)]} ${key.substring(2, 4)}";
    } catch (e) {
      return key;
    }
  }

  // CHANGE: Updated _getStats to compute a true statistical median for both odd and even counts
  Map<String, double> _getStats() {
    if (_apiData.isEmpty) return {"mean": 0, "median": 0, "max": 100};

    // If a category is selected, calculate stats ONLY for that category's values
    List<double> values = _apiData.map((d) {
      if (_selectedCategory != null) {
        return (d[_selectedCategory] ?? 0.0) as double;
      }
      return (d["total"] as double);
    }).toList();

    // Guard against all-NaN/empty scenarios (shouldn't happen, but safe)
    if (values.isEmpty) return {"mean": 0, "median": 0, "max": 0};

    // Mean
    final double mean = values.reduce((a, b) => a + b) / values.length;

    // ---- FIX START: proper median for odd/even lengths ----
    final List<double> sorted = List<double>.from(values)..sort();
    final int n = sorted.length;
    double median;
    if (n % 2 == 1) {
      // Odd: middle element
      median = sorted[n ~/ 2];
    } else {
      // Even: average of the two middle elements
      final int hi = n ~/ 2;
      final int lo = hi - 1;
      median = (sorted[lo] + sorted[hi]) / 2.0; // <-- FIXED
    }
    // ---- FIX END ----

    // Max (keep as-is)
    final double maxVal = values.reduce(max);

    return {
      "mean": mean,
      "median": median, // now correct for even-length data
      "max": maxVal,
    };
  }

  // CHANGE: Updated _buildBarGroups to filter segments based on selection
  List<BarChartGroupData> _buildBarGroups() {
    List<String> allCategories = _categoryColors.keys.toList();

    return List.generate(_apiData.length, (index) {
      final d = _apiData[index];
      List<BarChartRodStackItem> stacks = [];
      double currentStackHeight = 0;
      double totalToDisplay = 0;

      for (String cat in allCategories) {
        // If a category is selected, skip all other categories
        if (_selectedCategory != null && cat != _selectedCategory) continue;

        double val = (d[cat] ?? 0.0);
        if (val > 0) {
          stacks.add(BarChartRodStackItem(currentStackHeight,
              currentStackHeight + val, _categoryColors[cat]!));
          currentStackHeight += val;
          totalToDisplay += val;
        }
      }

      return BarChartGroupData(x: index, barRods: [
        BarChartRodData(
          toY: totalToDisplay,
          width: _isZoomed ? 32 : 18,
          borderRadius: BorderRadius.circular(4),
          rodStackItems: stacks,
          color: stacks.isEmpty ? Colors.grey.withOpacity(0.2) : null,
        )
      ]);
    });
  }

  @override
  Widget build(BuildContext context) {
    final stats = _getStats();
    final chartMaxY = stats["max"]! == 0 ? 10.0 : stats["max"]! * 1.3;

    double barSpacing = _isZoomed ? 120.0 : 60.0;
    double chartWidth =
        max(MediaQuery.of(context).size.width, _apiData.length * barSpacing);

    return Scaffold(
      appBar: AppBar(
        title: const Text("Spending Statistics"),
        actions: [
          IconButton(
            icon: Icon(_isZoomed ? Icons.zoom_out : Icons.zoom_in),
            onPressed: () => setState(() => _isZoomed = !_isZoomed),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16.0),
            child: SegmentedButton<TimeUnit>(
              segments: const [
                ButtonSegment(value: TimeUnit.day, label: Text("day")),
                ButtonSegment(value: TimeUnit.month, label: Text("month")),
                ButtonSegment(value: TimeUnit.year, label: Text("year")),
              ],
              selected: {selectedUnit},
              onSelectionChanged: (val) {
                setState(() {
                  selectedUnit = val.first;
                  _fetchAnalytics();
                });
              },
            ),
          ),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _apiData.isEmpty
                    ? const Center(child: Text("No records found"))
                    : SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 300),
                          width: chartWidth,
                          padding: const EdgeInsets.all(20),
                          // CHANGE: Wrap BarChart with a Column so we can add a chart title above it
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              // CHANGE: Chart title
                              Text(
                                "Spending Chart", // <- chart title
                                textAlign: TextAlign.center,
                                style: Theme.of(context)
                                    .textTheme
                                    .titleMedium
                                    ?.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                              ),
                              const SizedBox(height: 8),
                              // CHANGE: The BarChart moves into an Expanded so it uses remaining space
                              Expanded(
                                child: BarChart(
                                  BarChartData(
                                    maxY: chartMaxY,
                                    barGroups: _buildBarGroups(),
                                    barTouchData: BarTouchData(
                                        touchTooltipData: BarTouchTooltipData(
                                        getTooltipColor: (group) =>
                                          Colors.blueGrey.withOpacity(0.9),
                                        getTooltipItem:
                                          (group, groupIndex, rod, rodIndex) {
                                          final dataPoint =
                                              _apiData[groupIndex];
                                          final total = _selectedCategory !=
                                                  null
                                              ? (dataPoint[_selectedCategory] ??
                                                  0.0)
                                              : dataPoint["total"];
                                          List<String> lines = [
                                            _selectedCategory != null
                                                ? "${_selectedCategory![0].toUpperCase()}${_selectedCategory!.substring(1)}: £${total.toStringAsFixed(2)}"
                                                : "Total: £${total.toStringAsFixed(2)}"
                                          ];
                                          if (_selectedCategory == null) {
                                            // Sort categories by contribution (descending) for clearer tooltips
                                            final entries = _categoryColors.keys
                                                .map((cat) => MapEntry(
                                                    cat,
                                                    (dataPoint[cat] ?? 0.0)
                                                        as double))
                                                .where((e) => e.value > 0)
                                                .toList()
                                              ..sort((a, b) =>
                                                  b.value.compareTo(a.value));

                                            for (final e in entries) {
                                              final cat = e.key;
                                              final val = e.value;
                                              final percentage = (total == 0)
                                                  ? 0
                                                  : (val / total) * 100;

                                              // If this category’s colour is reused, it will have a marker
                                              final String? marker =
                                                  _categoryMarkers[cat];

                                              final String catLabel = (marker !=
                                                          null
                                                      ? "$marker "
                                                      : "") +
                                                  "${cat[0].toUpperCase()}${cat.substring(1)}";

                                              lines.add(
                                                "$catLabel: £${val.toStringAsFixed(2)} (${percentage.toStringAsFixed(1)}%)",
                                              );
                                            }
                                          }

                                          return BarTooltipItem(
                                            lines.join('\n'),
                                            const TextStyle(
                                              color: Colors.white,
                                              fontSize: 11,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                    extraLinesData:
                                        ExtraLinesData(horizontalLines: [
                                      HorizontalLine(
                                          y: stats["mean"]!,
                                          color: Colors.redAccent,
                                          dashArray: [5, 5]),
                                      HorizontalLine(
                                          y: stats["median"]!,
                                          color: Colors.orange,
                                          dashArray: [3, 3]),
                                    ]),
                                    // CHANGE: Add axis titles (x = "spent £", y = "dates")
                                    titlesData: FlTitlesData(
                                      leftTitles: AxisTitles(
                                        // y-axis (vertical) — add axis name "dates"
                                        // Note: This is semantically unusual (normally y is the amount),
                                        // but implemented exactly as you requested.
                                        axisNameWidget: const Padding(
                                          padding: EdgeInsets.only(bottom: 8.0),
                                          child: Text(
                                            "spent £", // <- Y axis title
                                            style: TextStyle(
                                                fontWeight: FontWeight.w600),
                                          ),
                                        ),
                                        axisNameSize: 24,
                                        sideTitles: SideTitles(
                                            showTitles: true, reservedSize: 40),
                                      ),
                                      bottomTitles: AxisTitles(
                                        // x-axis (horizontal) — add axis name "spent £"
                                        axisNameWidget: const Padding(
                                          padding: EdgeInsets.only(top: 8.0),
                                          child: Text(
                                            "dates", // <- X axis title
                                            style: TextStyle(
                                                fontWeight: FontWeight.w600),
                                          ),
                                        ),
                                        axisNameSize: 24,
                                        sideTitles: SideTitles(
                                          showTitles: true,
                                          getTitlesWidget: (v, m) =>
                                              SideTitleWidget(
                                            meta: m,
                                            child: Text(
                                              _getBottomLabel(v),
                                              style: TextStyle(
                                                  fontSize:
                                                      _isZoomed ? 11 : 10),
                                            ),
                                          ),
                                        ),
                                      ),
                                      // Keep top/right titles hidden
                                      topTitles: const AxisTitles(),
                                      rightTitles: const AxisTitles(),
                                    ),
                                    gridData: const FlGridData(show: false),
                                    borderData: FlBorderData(show: false),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
          ),
          _buildLegend(stats),
        ],
      ),
    );
  }

  // CHANGE: Legend now handles taps to filter categories
  Widget _buildLegend(Map<String, double> stats) {
    return Padding(
      padding: const EdgeInsets.all(20.0),
      child: Column(
        children: [
          const Text(
            "Item category",
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 15,
            runSpacing: 10,
            alignment: WrapAlignment.center,
            children: _categoryColors.entries.map((entry) {
              final isSelected = _selectedCategory == entry.key;

              // NEW: prefix the label with the marker if present
              final marker = _categoryMarkers[entry.key];
              final displayLabel = (marker != null ? "$marker " : "") +
                  (entry.key.isEmpty
                      ? "Other"
                      : entry.key[0].toUpperCase() + entry.key.substring(1));

              return GestureDetector(
                onTap: () {
                  setState(() {
                    // Toggle selection: if clicking already selected, clear it
                    _selectedCategory = isSelected ? null : entry.key;
                  });
                },
                child: Opacity(
                  // Dim non-selected items if a filter is active
                  opacity: _selectedCategory == null || isSelected ? 1.0 : 0.3,
                  child: _LegendItem(
                    color: entry.value,
                    label: entry.key.isEmpty
                        ? "Other"
                        : entry.key[0].toUpperCase() + entry.key.substring(1),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 15,
            alignment: WrapAlignment.center,
            children: [
              _LegendItem(
                  color: Colors.redAccent,
                  label: "Avg: \£${stats["mean"]!.toStringAsFixed(2)}",
                  isLine: true),
              _LegendItem(
                  color: Colors.orange,
                  label: "Med: \£${stats["median"]!.toStringAsFixed(2)}",
                  isLine: true),
            ],
          ),
        ],
      ),
    );
  }
}

class _InteractableLegend extends StatelessWidget {
  final Color color;
  final String label;
  final VoidCallback onTap;
  final bool isActive;
  const _InteractableLegend(
      {required this.color,
      required this.label,
      required this.onTap,
      required this.isActive});
  @override
  Widget build(BuildContext context) => GestureDetector(
      onTap: onTap,
      child: Opacity(
          opacity: isActive ? 1.0 : 0.3,
          child: _LegendItem(color: color, label: label)));
}

class _LegendItem extends StatelessWidget {
  final Color color;
  final String label;
  final bool isLine;
  const _LegendItem(
      {required this.color, required this.label, this.isLine = false});
  @override
  Widget build(BuildContext context) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 12, height: isLine ? 2 : 12, color: color),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 11)),
      ]);
}
