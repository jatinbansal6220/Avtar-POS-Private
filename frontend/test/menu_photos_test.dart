import 'dart:convert';
import 'dart:io';

import 'package:avtar_pos/core/local_store.dart';
import 'package:avtar_pos/core/models.dart';
import 'package:avtar_pos/core/session.dart';
import 'package:avtar_pos/features/menu/dish_photo.dart';
import 'package:avtar_pos/features/menu/menu_panel.dart';
import 'package:avtar_pos/ui/shared.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test('all built-in menu names resolve a shared portion photo', () {
    final menu = jsonDecode(
      File('assets/data/avtar_cooks_menu.json').readAsStringSync(),
    ) as List;
    final assets = <String>{};
    for (final item in menu) {
      final path = generatedDishImage(item['name'] as String);
      expect(path, isNotNull, reason: item['name'] as String);
      assets.add(path!);
    }
    expect(assets.length, 81);
    expect(
      generatedDishImage('Shahi Paneer (Half)'),
      generatedDishImage('Shahi Paneer (Full)'),
    );
    expect(
      generatedDishImage('  FRENCH FRIES  '),
      generatedDishImage('French Fries'),
    );
    expect(generatedDishImage('Chef Special New Dish'), isNull);
  });

  test('packaged thumbnails exist and stay small', () {
    for (final slug in generatedDishSlugs) {
      final image = File('assets/images/menu_generated/$slug.webp');
      expect(image.existsSync(), isTrue, reason: slug);
      expect(image.lengthSync(), lessThan(100000), reason: slug);
    }
  });

  testWidgets(
    'photo cards keep item IDs, prices and add callbacks on a small screen',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      Session.prefs = await SharedPreferences.getInstance();
      final session = Session(demoMode: true)
        ..user = {'id': 1, 'role': 'owner'};
      await tester.runAsync(() async {
        session.local = await LocalStore.connect(
          databaseFactoryFfi,
          inMemoryDatabasePath,
        );
        await LocalStore.put(session.local!.db, 'menu_items', {
          'id': 'original-fries-id',
          'name': 'French Fries',
          'category': 'Starters',
          'price_minor': 10000,
          'is_active': true,
          'is_veg': true,
        });
      });
      Json? added;
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(),
          home: Scaffold(
            body: MenuPanel(
              session,
              onAdd: (item, combo) {
                added = item;
                calls++;
                expect(combo, false);
              },
            ),
          ),
        ),
      );
      for (
        var attempt = 0;
        attempt < 20 && find.text('French Fries').evaluate().isEmpty;
        attempt++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(find.byType(DishPhoto), findsOneWidget);
      await tester.tap(find.text('French Fries'));
      expect(calls, 1);
      expect(added!['id'], 'original-fries-id');
      expect(added!['price_minor'], 10000);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() => session.local!.db.close());
      session.dispose();
    },
  );
}
