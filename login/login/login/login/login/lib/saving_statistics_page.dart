// saving_statistics_page.dart
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:fl_chart/fl_chart.dart';

// ------------------------------------------------------------
// MODEL
// ------------------------------------------------------------
class TimeSeriesSavings {
  final DateTime time;
  final double amount;
  double? applicableSalary; 
  double? targetSaving; 

  // --- CHANGE: Added targetSaving to the constructor parameters ---
  TimeSeriesSavings(
    this.time, 
    this.amount, 
    {this.applicableSalary, this.targetSaving}
  );
}

// --- NEW: Added missing SalaryRecord class ---
class SalaryRecord {
  final DateTime changedAt;
  final double salary;

  SalaryRecord(this.changedAt, this.salary);
}

// ------------------------------------------------------------
// MAIN PAGE
// ------------------------------------------------------------
class SavingStatisticsPage extends StatefulWidget {
  final String userId;
  const SavingStatisticsPage({super.key, required this.userId});

  @override
  State<SavingStatisticsPage> createState() => _SavingStatisticsPageState();
}

class _SavingStatisticsPageState extends State<SavingStatisticsPage> {
  double? _targetSavingGoal; // --- NEW: Global variable to store the target ---
  bool enableWideScroll = false;
  List<TimeSeriesSavings> savingsData = [];
  List<SalaryRecord> salaryHistory = []; // --- NEW: Store all user salary records ---
  bool isLoading = true;

  // fl_chart-specific fields
  List<FlSpot> _spots = [];
  List<FlSpot> _salarySpots = []; // --- NEW: Spots for the dynamic green line ---
  double _minY = 0;
  double _maxY = 1;
  double _yInterval = 1;

  // Tracking touched point for labeling
  int? _touchedIndex;

  double? userSalary; // New: Store the fetched salary
  bool isSalaryLoaded = false; // New: Track if salary fetch finished

  @override
  void initState() {
    super.initState();
    _loadAllData(); // --- CHANGE: Combined loader to ensure data synchronicity ---
    
  }

  Future<void> _loadAllData() async {
    setState(() => isLoading = true);
    await fetchUserSalaryHistory();
    
    // --- NEW: FALLBACK LOGIC ---
    // If no history found, try fetching from the loginTable API
    if (salaryHistory.isEmpty) {
      await fetchFallbackSalary();
    }
    
    await fetchMonthlyAnalytics(); 
    setState(() => isLoading = false);
  }

  // --- NEW: Fallback method to get salary from loginTable ---
  Future<void> fetchFallbackSalary() async {
  final url = "https://nodejs-production-f031.up.railway.app/api/admin/loginTable/${widget.userId}";
  try {
    final response = await http.get(Uri.parse(url));
    if (response.statusCode == 200) {
      final jsonResponse = jsonDecode(response.body);
      
      final double? fallbackSalary = (jsonResponse["monthlySalary"] as num?)?.toDouble();
      // --- NEW: Extract targetMonthlySaving from the JSON ---
      _targetSavingGoal = (jsonResponse["targetMonthlySaving"] as num?)?.toDouble();

      if (fallbackSalary != null) {
        setState(() {
          salaryHistory = [SalaryRecord(DateTime(2000), fallbackSalary)];
        });
      }
    }
  } catch (e) {
    debugPrint("Error fetching fallback salary: $e");
  }
}

  Future<void> fetchUserSalaryHistory() async {
    final url = "https://nodejs-production-f031.up.railway.app/api/admin/salaryHist";
    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final jsonResponse = jsonDecode(response.body);
        final List<dynamic> rows = jsonResponse["rows"];

        // --- CHANGE: Filter and sort all records for this user by date ---
        final userRecords = rows
            .where((row) => row["userID"] == widget.userId)
            .map((row) => SalaryRecord(
                DateTime.parse(row["changedAt"]), 
                (row["salary"] as num).toDouble()))
            .toList();
        
        // Sort oldest to newest to help find "most recent" salary easily
        userRecords.sort((a, b) => a.changedAt.compareTo(b.changedAt));
        
        setState(() {
          salaryHistory = userRecords;
        });
      }
    } catch (e) {
      debugPrint("Error fetching salary history: $e");
    }
  }

  // --- CHANGE: Modified to handle missing salary or spending independently ---
  Future<void> fetchMonthlyAnalytics() async {
    final url = "https://nodejs-production-53a4.up.railway.app/api/item-input/analytics/monthly?userID=${widget.userId}";
    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final jsonResponse = jsonDecode(response.body);
        final rows = jsonResponse["rows"] as List<dynamic>;
        final Map<String, double> monthlyTotals = {};
        
        for (var row in rows) {
          final String month = row["spending_month"];
          final double spent = (row["total_spent"] as num).toDouble();
          monthlyTotals[month] = (monthlyTotals[month] ?? 0) + spent;
        }

        final parsed = monthlyTotals.entries.map((e) {
          final parts = e.key.split("-");
          final spendingDate = DateTime(int.parse(parts[0]), int.parse(parts[1]));
          
          double? foundSalary;
          try {
            // Look for salary active at this date
            foundSalary = salaryHistory
                .lastWhere((rec) => rec.changedAt.isBefore(spendingDate.add(const Duration(days: 31))))
                .salary;
          } catch (_) {
            // If no specific history, use the first available or null
            if (salaryHistory.isNotEmpty) foundSalary = salaryHistory.first.salary;
          }

          // Locate this inside fetchMonthlyAnalytics
          return TimeSeriesSavings(
            spendingDate, 
            e.value, 
            applicableSalary: foundSalary,
            // targetSaving is optional, so we can leave it out here or add it
          );
        }).toList()
          ..sort((a, b) => a.time.compareTo(b.time));

        setState(() {
          savingsData = parsed;
        });
        _recomputeChartData();
      }
    } catch (e) {
      // --- NEW: If spending fetch fails, we still want to show the salary line ---
      debugPrint("Error fetching analytics: $e");
      _recomputeChartData(); // Call this anyway to try and render salaryHistory
    }
  }

  Future<void> fetchUserSalary() async {
    final url = "https://nodejs-production-f031.up.railway.app/api/admin/salaryHist";
    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final jsonResponse = jsonDecode(response.body);
        final List<dynamic> rows = jsonResponse["rows"];

        // Find the specific user in the history list
        final userRecord = rows.firstWhere(
          (row) => row["userID"] == widget.userId,
          orElse: () => null,
        );

        setState(() {
          if (userRecord != null) {
            userSalary = (userRecord["salary"] as num).toDouble();
          }
          isSalaryLoaded = true;
        });
        _recomputeChartData(); // Recompute to ensure maxY accounts for salary height
      }
    } catch (e) {
      debugPrint("Error fetching salary: $e");
      setState(() => isSalaryLoaded = true);
    }
  }
  
  void _recomputeChartData() {
  final List<FlSpot> spendingSpots = <FlSpot>[];
  final List<FlSpot> salarySpots = <FlSpot>[];
  // --- NEW: Temporary list to sync savingsData with the chart indices ---
  final List<TimeSeriesSavings> syncedSavingsData = [];

  final allMonths = <DateTime>{
    ...savingsData.map((d) => d.time),
    ...salaryHistory.map((s) => DateTime(s.changedAt.year, s.changedAt.month)),
  }.toList()..sort();

  double currentMax = 0;

  for (int i = 0; i < allMonths.length; i++) {
    final currentMonth = allMonths[i];

    final spendingMatch = savingsData.where((d) => 
      d.time.year == currentMonth.year && d.time.month == currentMonth.month).firstOrNull;
    
    // --- CHANGE: Track spending amount for the spot ---
    double spentAmount = 0;
    if (spendingMatch != null) {
      spentAmount = spendingMatch.amount;
      if (spentAmount > 0) {
        spendingSpots.add(FlSpot(i.toDouble(), spentAmount));
        currentMax = max(currentMax, spentAmount);
      }
    }

    double? foundSalary;
    try {
      foundSalary = salaryHistory
          .lastWhere((rec) => rec.changedAt.isBefore(currentMonth.add(const Duration(days: 31))))
          .salary;
    } catch (_) {
      if (salaryHistory.isNotEmpty) foundSalary = salaryHistory.first.salary;
    }

    if (foundSalary != null && foundSalary > 0) {
      salarySpots.add(FlSpot(i.toDouble(), foundSalary));
      currentMax = max(currentMax, foundSalary);
    }

    // --- NEW: Populate synced list so index 'i' always exists in savingsData ---
    // Locate this inside the for-loop in _recomputeChartData
    syncedSavingsData.add(TimeSeriesSavings(
      currentMonth, 
      spentAmount, 
      applicableSalary: foundSalary, // Must be named
      targetSaving: _targetSavingGoal, // Must be named
    ));
  }

  if (currentMax == 0) currentMax = 100;
  double calculatedInterval = (currentMax / 5);
  if (calculatedInterval < 1) calculatedInterval = 1;

  setState(() {
    _spots = spendingSpots;
    _salarySpots = salarySpots; 
    // --- NEW: Update savingsData to match the chart's X-axis indices ---
    savingsData = syncedSavingsData; 
    _minY = 0;
    _maxY = currentMax * 1.2;
    _yInterval = calculatedInterval;
  });
}


  String _formatMonthYear(DateTime dt) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${months[dt.month - 1]} ${dt.year}';
  }

  // --- NEW: Helper method to build legend items ---
  Widget _buildLegendItem(String label, Color color) {
    return Row(
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
        ),
      ],
    );
  }

  // ------------------------------------------------------------
  // THE CHART WIDGET
  // ------------------------------------------------------------
  Widget _buildChartContent(double chartWidth, double chartHeight) {
    return Container(
      width: chartWidth,
      height: chartHeight,
      padding: const EdgeInsets.fromLTRB(10, 20, 30, 10),
      child: LineChart(
        LineChartData(
          // --- CHANGE: maxX now dynamically finds the furthest point between both datasets ---
          minX: 0,
          maxX: max(
            _spots.isNotEmpty ? _spots.last.x : 0, 
            _salarySpots.isNotEmpty ? _salarySpots.last.x : 0
          ),
          minY: _minY,
          maxY: _maxY,
          extraLinesData: ExtraLinesData(
            verticalLines: List.generate(
              // --- CHANGE: Generate grid lines based on the longest available data ---
              max(_spots.length, _salarySpots.length), 
              (i) => VerticalLine(
                x: i.toDouble(),
                color: Colors.grey.withOpacity(0.3),
                strokeWidth: 1,
                dashArray: [5, 5],
              ),
            ),
          ),
          gridData: FlGridData(
            show: true,
            horizontalInterval: _yInterval,
            getDrawingHorizontalLine: (v) =>
                FlLine(color: Colors.grey.withOpacity(0.1), strokeWidth: 1),
          ),
          titlesData: FlTitlesData(
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 60,
                interval: _yInterval,
                getTitlesWidget: (value, meta) => SideTitleWidget(
                  meta: meta,
                  child: Text('£${value.toStringAsFixed(0)}',
                      style: const TextStyle(fontSize: 9)),
                ),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                interval: 1,
                getTitlesWidget: (value, meta) {
                  final index = value.toInt();
                  // --- CHANGE: Ensure labels show if data exists in either list ---
                  if (index < 0 || index >= max(_spots.length, _salarySpots.length)) {
                    return const SizedBox.shrink();
                  }
                  return SideTitleWidget(
                    meta: meta,
                    child: Text(_formatMonthYear(savingsData[index].time),
                        style: const TextStyle(fontSize: 9)),
                  );
                },
              ),
            ),
          ),
          lineTouchData: LineTouchData(
            touchCallback: (event, touchResponse) {
              if (!event.isInterestedForInteractions || touchResponse == null || touchResponse.lineBarSpots == null) return;
              setState(() => _touchedIndex = touchResponse.lineBarSpots!.first.spotIndex);
            },
            handleBuiltInTouches: true,
            touchTooltipData: LineTouchTooltipData(
              getTooltipColor: (spot) => Colors.indigo.withOpacity(0.9),
              maxContentWidth: 200,
              // Inside _buildChartContent -> LineTouchTooltipData -> getTooltipItems
              getTooltipItems: (List<LineBarSpot> touchedBarSpots) {
                final index = touchedBarSpots.first.spotIndex;
                final data = savingsData[index];
                final spending = data.amount;
                final salary = data.applicableSalary;
                final target = data.targetSaving; // --- NEW: Get target ---

                return [
                  LineTooltipItem(
                    'Spent: £${spending.toStringAsFixed(2)}\n',
                    const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11),
                    children: [
                      if (salary != null) ...[
                        TextSpan(
                          text: 'Salary: £${salary.toStringAsFixed(2)}\n',
                          style: const TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold),
                        ),
                        const TextSpan(text: '----------------\n', style: TextStyle(color: Colors.white54)),
                        
                        // --- NEW: Target Savings Logic ---
                        if (target != null) ...[
                          TextSpan(
                            text: 'Target Saving: £${target.toStringAsFixed(2)}\n',
                            style: const TextStyle(color: Colors.lightBlueAccent, fontSize: 11),
                          ),
                          TextSpan(
                            text: (salary - spending) >= target
                                ? '✅ Goal Reached!'
                                : '❌ Goal Missed (Short: £${(target - (salary - spending)).toStringAsFixed(2)})',
                            style: TextStyle(
                              color: (salary - spending) >= target ? Colors.greenAccent : Colors.orangeAccent,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ]
                      ]
                    ],
                  ),
                ];
              },
            ),
          ),
          lineBarsData: [
            // --- CHANGE: Both lines now check their own lists independently ---
            if (_salarySpots.isNotEmpty)
              LineChartBarData(
                spots: _salarySpots,
                isCurved: false,
                barWidth: 3,
                color: Colors.green,
                dotData: const FlDotData(show: true),
                belowBarData: BarAreaData(show: true, color: Colors.green.withOpacity(0.05)),
              ),
            if (_spots.isNotEmpty)
              LineChartBarData(
                spots: _spots,
                isCurved: true,
                barWidth: 3,
                color: Colors.indigo,
                // --- CHANGE: Added belowBarData to color the area under the blue line ---
                belowBarData: BarAreaData(
                  show: true, 
                  color: Colors.indigo.withOpacity(0.1), // Light blue fill
                ),
                dotData: FlDotData(
                  show: true,
                  getDotPainter: (spot, percent, barData, index) => FlDotCirclePainter(
                    radius: _touchedIndex == index ? 6 : 3,
                    color: _touchedIndex == index ? Colors.orange : Colors.indigo,
                    strokeWidth: 2,
                    strokeColor: Colors.white,
                  ),
                ),
              ),
          ],
        )
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    double chartWidth = enableWideScroll 
        ? max(600, savingsData.length * 80.0) 
        : MediaQuery.of(context).size.width - 40;
    
    double chartHeight = 500.0; // Reduced height for better visibility, still scrollable if needed

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(title: const Text('Salary VS Spending Analytics'), backgroundColor: Colors.white, foregroundColor: Colors.black, elevation: 0),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (salaryHistory.isEmpty)
                  _buildWarningBox("Salary history not found. Update in Settings."),
                
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Text(
                    'Spending vs Salary History',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.indigo),
                  ),
                ),
                // NEW: Instructional Text
                const Text(
                  'Tap onto the dot(s) to see details',
                  style: TextStyle(fontSize: 12, color: Colors.grey, fontStyle: FontStyle.italic),
                ),
                const SizedBox(height: 10),
                // NEW: Legend Row
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _buildLegendItem("Monthly Salary", Colors.green),
                    const SizedBox(width: 20),
                    _buildLegendItem("Monthly Spending", Colors.indigo),
                  ],
                ),
                Expanded(
                  child: Scrollbar(
                    thumbVisibility: true,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.vertical,
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Column(
                          children: [
                            _buildChartContent(chartWidth, chartHeight),
                            if (_touchedIndex != null) _buildDetailCard(),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                _buildScrollToggle(),
              ],
            ),
    );
  }

  Widget _buildWarningBox(String text) {
    return Container(
      width: double.infinity, margin: const EdgeInsets.all(10), padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(color: Colors.red.shade50, borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.red.shade200)),
      child: Text(text, textAlign: TextAlign.center, style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
    );
  }

  Widget _buildDetailCard() {
  final data = savingsData[_touchedIndex!];
  final diff = (data.applicableSalary ?? 0) - data.amount;
  final target = data.targetSaving ?? 0;
  final goalReached = diff >= target;

  return Container(
    padding: const EdgeInsets.all(10), 
    margin: const EdgeInsets.symmetric(vertical: 20),
    decoration: BoxDecoration(
      color: goalReached ? Colors.green.shade50 : Colors.orange.shade50, 
      borderRadius: BorderRadius.circular(8)
    ),
    child: Text(
      "Date: ${_formatMonthYear(data.time)}\n"
      "Spent: £${data.amount.toStringAsFixed(2)} | Salary: £${data.applicableSalary?.toStringAsFixed(2) ?? 'N/A'}\n"
      "Saved: £${diff.toStringAsFixed(2)} | Target: £${target.toStringAsFixed(2)}\n"
      "${goalReached ? "✅ Goal Achieved" : "❌ Below Target"}",
      style: TextStyle(
        fontWeight: FontWeight.bold, 
        color: goalReached ? Colors.green.shade900 : Colors.deepOrange
      ),
    ),
  );
}

  Widget _buildScrollToggle() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: ElevatedButton.icon(
        onPressed: () => setState(() => enableWideScroll = !enableWideScroll),
        icon: Icon(enableWideScroll ? Icons.unfold_less : Icons.unfold_more),
        label: Text(enableWideScroll ? "Disable Wide View" : "Enable Wide View"),
      ),
    );
  }
}
