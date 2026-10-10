import 'dart:async';

import 'package:avtar_pos/core/local_store.dart';
import 'package:avtar_pos/features/tables/floor_page.dart';
import 'package:avtar_pos/features/demo/demo_seed.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'pos_usability_test.dart' as fixture;

class ReadCounter implements Database {
  final Database source;
  int queries = 0;
  Completer<void>? gate;
  ReadCounter(this.source);
  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) async {
    queries++;
    final waiting = gate;
    gate = null;
    if (waiting != null) {
      await waiting.future;
    }
    return source.query(
      table,
      distinct: distinct,
      columns: columns,
      where: where,
      whereArgs: whereArgs,
      groupBy: groupBy,
      having: having,
      orderBy: orderBy,
      limit: limit,
      offset: offset,
    );
  }

  @override
  Future<void> close() => source.close();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  test(
    'fresh browser demo seeds valid active drinks and remains idempotent',
    () async {
      final session = await fixture.setup();
      final store = session.local!;
      await seedOfflineDemo(store);
      expect(
        (await store.get('menu_items', 'menu_demo_water_bottle'))!['is_active'],
        true,
      );
      expect(
        (await store.get('menu_items', 'menu_demo_cold_drink'))!['is_active'],
        true,
      );
      final count = (await store.listAll('menu_items')).length;
      await seedOfflineDemo(store);
      expect((await store.listAll('menu_items')).length, count);
      await store.db.close();
      session.dispose();
    },
  );
  test(
    'batch reads handle missing, duplicate, quoted IDs and SQLite limits',
    () async {
      final session = await fixture.setup();
      final store = session.local!;
      for (var i = 0; i < 805; i++) {
        await LocalStore.put(store.db, 'orders', {
          'id': 'order-$i',
          'status': 'open',
        });
        await store.setMeta('kot-$i', '$i');
      }
      await LocalStore.put(store.db, 'orders', {'id': "quoted' OR 1=1 --"});
      final counter = ReadCounter(store.db);
      final batched = LocalStore(counter);
      final orders = await batched.getMany('orders', [
        for (var i = 0; i < 805; i++) 'order-$i',
        'order-0',
        'missing',
        "quoted' OR 1=1 --",
      ]);
      expect(orders.length, 806);
      expect(orders.containsKey('missing'), isFalse);
      expect(orders["quoted' OR 1=1 --"]!['id'], "quoted' OR 1=1 --");
      expect(counter.queries, 3);
      counter.queries = 0;
      final metadata = await batched.metaMany([
        for (var i = 0; i < 805; i++) 'kot-$i',
        'kot-0',
        'missing',
      ]);
      expect(metadata.length, 805);
      expect(metadata['kot-804'], '804');
      expect(counter.queries, 3);
      counter.queries = 0;
      expect(await batched.getMany('orders', []), isEmpty);
      expect(await batched.metaMany([]), isEmpty);
      expect(counter.queries, 0);
      await store.db.close();
      session.dispose();
    },
  );

  testWidgets(
    '60 tables use five reads and burst refreshes retain unchanged cards',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = (await tester.runAsync(fixture.setup))!;
      final store = session.local!;
      await tester.runAsync(() async {
        for (var i = 1; i <= 60; i++) {
          await LocalStore.put(store.db, 'tables', {
            'id': 'table-$i',
            'table_number': i.toString().padLeft(2, '0'),
            'section': 'Hall',
            'capacity': 4,
            'status': 'occupied',
            'current_order_id': 'order-$i',
          });
          await LocalStore.put(store.db, 'orders', {
            'id': 'order-$i',
            'table_id': 'table-$i',
            'order_type': 'dine_in',
            'status': 'open',
            'customer_name': '',
            'items': [
              {
                'menu_item_id': 'tea',
                'item_name': 'Tea',
                'quantity': 1,
                'price_minor': 1000,
              },
            ],
          });
        }
      });
      final counter = ReadCounter(store.db);
      session.local = LocalStore(counter);
      await tester.pumpWidget(MaterialApp(home: FloorPage(session)));
      await fixture.settleDb(tester);
      expect(counter.queries, 5);
      final original = tester.widget(find.byKey(const ValueKey('table-2')));
      counter.queries = 0;
      await tester.runAsync(() async {
        final changed = (await store.get('orders', 'order-1'))!;
        changed['customer_name'] = 'Updated customer';
        await LocalStore.put(store.db, 'orders', changed);
      });
      for (var i = 0; i < 10; i++) {
        session.dataChanged(['orders', 'tables', 'table_bookings']);
      }
      await tester.pump(const Duration(milliseconds: 100));
      await fixture.settleDb(tester);
      expect(counter.queries, 5);
      expect(find.text('Updated customer'), findsOneWidget);
      expect(
        tester.widget(find.byKey(const ValueKey('table-2'))),
        same(original),
      );
      // Changes arriving during a slow read must queue one follow-up, never
      // start concurrent floor loads or leave the latest customer hidden.
      counter.queries = 0;
      final gate = Completer<void>();
      counter.gate = gate;
      session.dataChanged(['orders']);
      await tester.pump(const Duration(milliseconds: 100));
      expect(counter.queries, 1);
      await tester.runAsync(() async {
        final changed = (await store.get('orders', 'order-1'))!;
        changed['customer_name'] = 'Latest customer';
        await LocalStore.put(store.db, 'orders', changed);
      });
      for (var i = 0; i < 10; i++) {
        session.dataChanged(['orders', 'tables']);
      }
      await tester.pump(const Duration(milliseconds: 100));
      expect(counter.queries, 1);
      gate.complete();
      await fixture.settleDb(tester);
      expect(counter.queries, 10);
      expect(find.text('Latest customer'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await fixture.close(tester, session);
    },
  );

  testWidgets(
    'hidden floor does not read on each item save and refreshes once on return',
    (tester) async {
      fixture.mobile(tester);
      final session = (await tester.runAsync(fixture.setup))!;
      final store = session.local!;
      await tester.runAsync(() async {
        await LocalStore.put(store.db, 'tables', {
          'id': 'table',
          'table_number': '01',
          'section': 'Hall',
          'capacity': 4,
          'status': 'empty',
        });
      });
      final counter = ReadCounter(store.db);
      session.local = LocalStore(counter);
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(navigatorKey: navigator, home: FloorPage(session)),
      );
      await fixture.settleDb(tester);
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Order editor')),
        ),
      );
      await tester.pumpAndSettle();
      counter.queries = 0;
      await tester.runAsync(() async {
        await store.draft({
          'id': 'draft',
          'table_id': 'table',
          'order_type': 'dine_in',
          'status': 'open',
          'customer_name': 'Latest guest',
          'items': [
            {'item_name': 'Tea', 'quantity': 10, 'price_minor': 1000},
          ],
        });
      });
      for (var i = 0; i < 10; i++) {
        session.dataChanged(['orders']);
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(counter.queries, 0);
      navigator.currentState!.pop();
      await tester.pump();
      await fixture.settleDb(tester);
      expect(counter.queries, 5);
      expect(find.text('Latest guest'), findsOneWidget);
      expect(find.text('KOT pending: 10'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await fixture.close(tester, session);
    },
  );
}
