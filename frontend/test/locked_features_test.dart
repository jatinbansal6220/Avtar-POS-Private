import 'package:avtar_pos/features/premium/locked_features_page.dart';
import 'package:avtar_pos/ui/shared.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> reveal(WidgetTester tester, String label) async {
    await tester.scrollUntilVisible(find.text(label), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
  }
  testWidgets('locked card requires notice before opening its separate demo', (tester) async {
    await tester.pumpWidget(MaterialApp(theme: appTheme(), home: const Scaffold(body: LockedFeaturesPage())));
    await tester.pumpAndSettle();
    await reveal(tester, 'Preview Dish-wise profit');
    await tester.tap(find.text('Preview Dish-wise profit'));
    await tester.pumpAndSettle();
    expect(find.text('Contact developer to unlock features'), findsOneWidget);
    expect(find.byType(PremiumFeatureDemoPage), findsNothing);
    await tester.tap(find.text('View demo'));
    await tester.pumpAndSettle();
    expect(tester.widget<PremiumFeatureDemoPage>(find.byType(PremiumFeatureDemoPage)).feature, PremiumFeature.dishProfit);
    expect(find.text('₹130'), findsOneWidget);
    expect(find.text('Preview only. Actual access is locked. Contact developer to allow access.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final feature in PremiumFeature.values) {
    testWidgets('${feature.title} preview fits a small phone', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(theme: appTheme(), home: PremiumFeatureDemoPage(feature: feature)));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await reveal(tester, 'Contact developer');
      await tester.tap(find.text('Contact developer'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('95307-76295'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('upselling changes only the sample ticket and can reset', (tester) async {
    await tester.pumpWidget(MaterialApp(theme: appTheme(), home: const PremiumFeatureDemoPage(feature: PremiumFeature.upselling)));
    await tester.pumpAndSettle();
    await reveal(tester, 'Try combo suggestion');
    await tester.tap(find.text('Try combo suggestion'));
    await tester.pumpAndSettle();
    expect(find.text('₹249'), findsOneWidget);
    expect(find.text('+₹100'), findsOneWidget);
    await tester.tap(find.text('Reset sample ticket'));
    await tester.pumpAndSettle();
    expect(find.text('₹149'), findsOneWidget);
  });

  testWidgets('loyalty sample earns and redeems once then resets', (tester) async {
    await tester.pumpWidget(MaterialApp(theme: appTheme(), home: const PremiumFeatureDemoPage(feature: PremiumFeature.loyalty)));
    await tester.pumpAndSettle();
    await reveal(tester, 'Try earning 50 points');
    await tester.tap(find.text('Try earning 50 points'));
    await tester.pumpAndSettle();
    expect(find.text('170 points'), findsOneWidget);
    await tester.tap(find.text('Try ₹50 reward'));
    await tester.pumpAndSettle();
    expect(find.text('70 points'), findsOneWidget);
    await tester.tap(find.text('Reset demo'));
    await tester.pumpAndSettle();
    expect(find.text('120 points'), findsOneWidget);
  });

  testWidgets('staff demo makes simulated role access explicit', (tester) async {
    await tester.pumpWidget(MaterialApp(theme: appTheme(), home: const PremiumFeatureDemoPage(feature: PremiumFeature.staffLogin)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cashier'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Preview staff sign-in'));
    await tester.pumpAndSettle();
    expect(find.text('DEMO: signed in as Cashier'), findsOneWidget);
    expect(find.text('This is a simulated sign-in. It does not authenticate staff or grant access to the POS.'), findsOneWidget);
  });
}
