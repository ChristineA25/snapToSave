
// lib/statistics_landing_page.dart
import 'package:flutter/material.dart';
import 'statistics_page.dart';
import 'saving_statistics_page.dart'; // NEW PAGE
import 'brand_statistics_page.dart'; // NEW: Import for brand statistics

class StatisticsLandingPage extends StatelessWidget {
  final String userId;

  const StatisticsLandingPage({super.key, required this.userId});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Statistics')),
      body: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Existing spending statistics button
          ElevatedButton.icon(
            icon: const Icon(Icons.bar_chart),
            label: const Text(
                'Open spending statistics with item categorised by type & time'),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => StatisticsPage(userId: userId),
                ),
              );
            },
          ),

          const SizedBox(height: 25),

          // NEW: "Open saving statistics" button
          ElevatedButton.icon(
            icon: const Icon(Icons.area_chart),
            label: const Text('Open Saving VS Spending'),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => SavingStatisticsPage(userId: userId),
                ),
              );
            },
          ),

          const SizedBox(height: 25), // NEW: Spacer

          // NEW: "Open to see statistics about item brand" button
          ElevatedButton.icon(
            icon: const Icon(Icons.label_important), // Icon for brands
            label: const Text('Open to see statistics about item brand'), // NEW label
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => BrandStatisticsPage(userId: userId), // NEW navigation
),
              );
            },
          ),
        ],
      ),
    );
  }
}
