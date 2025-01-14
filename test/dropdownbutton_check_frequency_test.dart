import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:four_training/data/globals.dart';
import 'package:four_training/l10n/l10n.dart';
import 'package:four_training/widgets/dropdownbutton_check_frequency.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('Test DropdownButtonCheckFrequency with frequency: daily',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({'checkFrequency': 'daily'});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(ProviderScope(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
        child: const MaterialApp(
            // We need the following to access l10n; Locale is default en_US
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            home: Scaffold(body: DropdownButtonCheckFrequency()))));

    // Verify initial value
    expect(prefs.getString('checkFrequency'), 'daily');
    expect(find.text('daily'), findsOneWidget);
    expect(find.text('weekly'), findsNothing);

    // Click on the button to expand it: Find the other options as well
    await tester.tap(find.byType(DropdownButtonCheckFrequency));
    await tester.pump();
    expect(find.text('never'), findsOneWidget);
    expect(find.text('weekly'), findsOneWidget);

    // Select 'never' and verify correct UI and saving in SharedPreferences
    await tester.tap(find.text('never'));
    await tester.pump();
    expect(find.text('never'), findsOneWidget);
    expect(find.text('daily'), findsNothing);
    expect(prefs.getString('checkFrequency'), 'never');
  });

  testWidgets('Test DropdownButtonCheckFrequency with frequency: monthly',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({'checkFrequency': 'monthly'});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(ProviderScope(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
        child: const MaterialApp(
            // We need the following to access l10n; Locale is default en_US
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            home: Scaffold(body: DropdownButtonCheckFrequency()))));

    // Verify initial value
    expect(prefs.getString('checkFrequency'), 'monthly');
    expect(find.text('monthly'), findsOneWidget);
    expect(find.text('weekly'), findsNothing);

    // Click on the button to expand it: Find the other options as well
    await tester.tap(find.byType(DropdownButtonCheckFrequency));
    await tester.pump();
    expect(find.text('never'), findsOneWidget);
    expect(find.text('weekly'), findsOneWidget);

    // Select 'weekly' and verify correct UI and saving in SharedPreferences
    await tester.tap(find.text('weekly'));
    await tester.pump();
    expect(find.text('weekly'), findsOneWidget);
    expect(find.text('monthly'), findsNothing);
    expect(prefs.getString('checkFrequency'), 'weekly');
  });
}
