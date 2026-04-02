
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Update this import to match your package name from pubspec.yaml:
// If pubspec.yaml has name: login
import 'package:login/main.dart'; 

void main() {
  testWidgets('app renders without crashing', (WidgetTester tester) async {
    // Pump your actual root widget
    await tester.pumpWidget(const SaveToPlantApp());

    // Quick sanity checks (adjust to your UI)
    expect(find.text('Save to Plant'), findsOneWidget);
    expect(find.text('Log In'), findsOneWidget);
  });
}
