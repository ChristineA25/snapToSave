import 'package:flutter/material.dart';
import 'settings_page.dart';
import 'buying_history_page.dart';
import 'statistics_landing_page.dart';

class HomePage extends StatefulWidget {
  final String userId;
  final String identifierType;
  final String identifierValue;

  const HomePage({
    super.key,
    required this.userId,
    required this.identifierType,
    required this.identifierValue,
  });

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _currentIndex = 0;

  Future<void> _openInputForm() async {
    final result = await Navigator.pushNamed(
      context,
      '/input',
      arguments: {'userId': widget.userId},
    );

    if (!mounted) return;

    if (result is Map && result['submitted'] == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('oh u have a n v code snippet. change b to c'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _openSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SettingsPage(
          userId: widget.userId,
          identifierType: widget.identifierType,
          identifierValue: widget.identifierValue,
        ),
      ),
    );
  }

  void _openBuyingHistory() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => BuyingHistoryPage(
          userId: widget.userId,
        ),
      ),
    );
  }

  void _openStatistics() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => StatisticsLandingPage(
          userId: widget.userId,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text("Savings Tracker"),
        backgroundColor: theme.colorScheme.primaryContainer,
        foregroundColor: theme.colorScheme.onPrimaryContainer,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: _openSettings,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 20),
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 24.0, vertical: 10),
            child: Text(
              "Welcome! Your savings journey starts here.💰",
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 20),
          
          // Home Button
          Center(
            child: BirdImageButton(
              filePath: 'assets/homepage.png',
              label: 'Home Dashboard',
              onPressed: () => setState(() => _currentIndex = 0),
            ),
          ),
          const SizedBox(height: 16),

          // Input Button
          Center(
            child: BirdImageButton(
              filePath: 'assets/inputPage.png',
              label: 'Record New Item Bought',
              onPressed: _openInputForm,
            ),
          ),
          const SizedBox(height: 16),

          // Settings Button
          Center(
            child: BirdImageButton(
              filePath: 'assets/setting.png',
              label: 'Account Settings',
              onPressed: _openSettings,
            ),
          ),
          const SizedBox(height: 16),

          // History Button
          Center(
            child: BirdImageButton(
              filePath: 'assets/histNrecommend.png',
              label: 'Buying History',
              onPressed: _openBuyingHistory,
            ),
          ),
          const SizedBox(height: 16),

          // Statistics Button
          Center(
            child: BirdImageButton(
              filePath: 'assets/statistics.png',
              label: 'View Statistics',
              onPressed: _openStatistics,
            ),
          ),
          const SizedBox(height: 40),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        type: BottomNavigationBarType.fixed,
        selectedItemColor: theme.colorScheme.primary,
        unselectedItemColor: Colors.black54,
        onTap: (i) async {
          if (i == 1) {
            await _openInputForm();
            return;
          }
          if (i == 2) {
            _openSettings();
            return;
          }
          if (i == 3) {
            _openBuyingHistory();
            return;
          }
          if (i == 4) {
            _openStatistics();
            return;
          }
          setState(() => _currentIndex = i);
        },
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home), label: "Home"),
          BottomNavigationBarItem(icon: Icon(Icons.edit_note), label: "Record New Item Bought"),
          BottomNavigationBarItem(icon: Icon(Icons.settings), label: "Settings"),
          BottomNavigationBarItem(icon: Icon(Icons.history), label: "Buying History"),
          BottomNavigationBarItem(icon: Icon(Icons.bar_chart), label: "Statistics"),
        ],
      ),
    );
  }
}

/// Styled Image Button component based on main.dart
class BirdImageButton extends StatelessWidget {
  final String filePath;
  final String? label;
  final double relativeWidth;
  final double aspectRatio;
  final double borderRadius;
  final double elevation;
  final VoidCallback? onPressed;

  const BirdImageButton({
    super.key,
    required this.filePath,
    this.label,
    this.relativeWidth = 0.85, // Slightly wider for home screen
    this.aspectRatio = 2.5,    // Slimmer profile for lists
    this.borderRadius = 16,
    this.elevation = 4,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final calculatedWidth = screenWidth * relativeWidth;
    final radius = BorderRadius.circular(borderRadius);

    return SizedBox(
      width: calculatedWidth,
      child: AspectRatio(
        aspectRatio: aspectRatio,
        child: Material(
          elevation: elevation,
          color: Colors.black,
          shape: RoundedRectangleBorder(borderRadius: radius),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.asset(
                  filePath,
                  fit: BoxFit.cover, // Changed to cover for a better button look
                  errorBuilder: (context, error, stackTrace) => Container(
                    color: Colors.grey[800],
                    child: const Icon(Icons.image, color: Colors.white24),
                  ),
                ),
                Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black.withOpacity(0.7),
                      ],
                    ),
                  ),
                ),
                if (label != null)
                  Padding(
                    padding: const EdgeInsets.all(12.0),
                    child: Align(
                      alignment: Alignment.bottomLeft,
                      child: Text(
                        label!,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}