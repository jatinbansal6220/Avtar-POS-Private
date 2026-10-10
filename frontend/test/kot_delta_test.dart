import 'dart:convert';

import 'package:avtar_pos/core/local_store.dart';
import 'package:avtar_pos/core/models.dart';
import 'package:avtar_pos/core/session.dart';
import 'package:avtar_pos/features/orders/data/kot_tracker.dart';
import 'package:avtar_pos/features/orders/data/order_controller.dart';
import 'package:avtar_pos/features/orders/kot_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Json line(String id, int quantity, {int? printed, String notes = ''}) => {
  'menu_item_id': id,
  'item_name': id,
  'quantity': quantity,
  'price_minor': id == 'roti'
      ? 1000
      : id == 'dal'
      ? 5000
      : 3000,
  'notes': notes,
  '_kot_printed_quantity': ?printed,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test(
    'additional KOT contains only extra roti and rice, not consumed dal',
    () {
      final order = {
        'id': 'order',
        'items': [line('roti', 2), line('dal', 1)],
      };
      final first = KotTracker.prepare(order, {});
      expect(first.items.map((row) => row['quantity']), [2, 1]);
      final next = clone(first.acknowledgedOrder);
      final rows = maps(next['items']);
      rows[0]['quantity'] = 3;
      rows.add(line('rice', 1, printed: 0));
      next['items'] = rows;
      final additional = KotTracker.prepare(next, first.sent);
      expect(additional.items.map((row) => row['menu_item_id']), [
        'roti',
        'rice',
      ]);
      expect(additional.items.map((row) => row['quantity']), [1, 1]);
      expect(maps(next['items']).map((row) => row['quantity']), [3, 1, 1]);
      expect(
        KotTracker.prepare(additional.acknowledgedOrder, additional.sent).items,
        isEmpty,
      );
    },
  );

  test('legacy acknowledgement survives server renaming and changed notes', () {
    final sent = KotTracker.readSent({'roti||Old name|': 2});
    final order = {
      'items': [line('roti', 3, notes: 'Less oil')..['item_name'] = 'New name'],
    };
    expect(KotTracker.prepare(order, sent).items.single['quantity'], 1);
  });

  test('legacy budget is shared once across duplicate dish lines', () {
    final order = {
      'items': [line('roti', 2), line('roti', 1, notes: 'Extra butter')],
    };
    final ticket = KotTracker.prepare(order, {'menu:roti': 2});
    expect(ticket.items.single['quantity'], 1);
    expect(ticket.items.single['notes'], 'Extra butter');
  });

  test(
    'new or re-added line never inherits a removed line acknowledgement',
    () {
      final order = {
        'items': [line('roti', 1, printed: 0)],
      };
      expect(
        KotTracker.prepare(order, {'menu:roti': 2}).items.single['quantity'],
        1,
      );
    },
  );

  test('printing another dish never lowers previous printed quantity', () {
    final order = {
      'items': [line('roti', 1, printed: 2), line('rice', 1, printed: 0)],
    };
    final ticket = KotTracker.prepare(order, {'menu:roti': 2});
    expect(ticket.items.single['menu_item_id'], 'rice');
    expect(
      maps(ticket.acknowledgedOrder['items']).first['_kot_printed_quantity'],
      2,
    );
    final next = clone(ticket.acknowledgedOrder);
    next['items'][0]['quantity'] = 2;
    expect(KotTracker.prepare(next, ticket.sent).items, isEmpty);
  });

  test('line markers rebuild a missing acknowledgement map without duplicate print', () {
    final ticket = KotTracker.prepare({
      'items': [line('roti', 2, printed: 2), line('rice', 1, printed: 0)],
    }, {});
    expect(ticket.sent['menu:roti'], 2);
    final synced = clone(ticket.acknowledgedOrder);
    for (final row in synced['items']) {
      row.remove('_kot_printed_quantity');
    }
    expect(KotTracker.prepare(synced, ticket.sent).items, isEmpty);
  });

  test(
    'save/reopen retains delta tracking and final bill retains every dish',
    () async {
      SharedPreferences.setMockInitialValues({});
      Session.prefs = await SharedPreferences.getInstance();
      final session = Session(
        client: MockClient((_) async => http.Response('{}', 200)),
        demoMode: true,
      )..user = {'id': 1, 'role': 'owner', 'name': 'Test Owner'};
      session.local = await LocalStore.connect(
        databaseFactoryFfi,
        inMemoryDatabasePath,
      );
      addTearDown(() async {
        await session.local!.db.close();
        session.dispose();
      });
      await LocalStore.put(session.local!.db, 'tables', {
        'id': 'table-01',
        'table_number': '01',
        'status': 'empty',
      });
      final order = {
        'id': 'order-01',
        'version': 0,
        'status': 'open',
        'order_type': 'dine_in',
        'table_id': 'table-01',
        'table_number': '01',
        'items': [line('roti', 2), line('dal', 1)],
      };
      final first = KotTracker.prepare(order, {});
      await session.local!.saveKotAcknowledgement(
        first.acknowledgedOrder,
        metadata: {
          'kot_sent_quantities_v2_order-01': jsonEncode(first.sent),
          'kot_last_ticket_v1_order-01': jsonEncode(first.items),
        },
      );
      final controller = OrderController(
        session,
        (await session.local!.readDraft('order-01'))!,
      );
      addTearDown(controller.dispose);
      controller.add({'id': 'roti', 'name': 'roti', 'price_minor': 1000});
      controller.add({'id': 'rice', 'name': 'rice', 'price_minor': 3000});
      await controller.save();
      final reopened = (await session.local!.readDraft('order-01'))!;
      final sent = KotTracker.readSent(
        jsonDecode(
          (await session.local!.meta('kot_sent_quantities_v2_order-01'))!,
        ),
      );
      final next = KotTracker.prepare(reopened, sent);
      expect(next.items.map((row) => row['menu_item_id']), ['roti', 'rice']);
      expect(next.items.map((row) => row['quantity']), [1, 1]);
      // Reading/reprinting the saved last ticket must not acknowledge new food.
      final last = maps(
        jsonDecode((await session.local!.meta('kot_last_ticket_v1_order-01'))!),
      );
      expect(last.map((row) => row['menu_item_id']), ['roti', 'dal']);
      expect(KotTracker.prepare(reopened, sent).items.length, 2);
      final bill = await session.enqueueBill(reopened, {
        'payment_method': 'cash',
      });
      expect(maps(bill['receipt']['items']).map((row) => row['quantity']), [
        3,
        1,
        1,
      ]);
      expect(bill['total_minor'], 11000);
    },
  );

  test(
    'failed acknowledgement rolls back metadata and preserves prior order',
    () async {
      final store = await LocalStore.connect(
        databaseFactoryFfi,
        inMemoryDatabasePath,
      );
      addTearDown(store.db.close);
      await store.saveKotAcknowledgement(
        {
          'id': 'order',
          'items': [line('roti', 2)],
        },
        metadata: {'sent': 'old'},
      );
      await expectLater(
        store.saveKotAcknowledgement({'items': []}, metadata: {'sent': 'new'}),
        throwsA(isA<DatabaseException>()),
      );
      expect(await store.meta('sent'), 'old');
      expect(
        maps((await store.readDraft('order'))!['items']).single['quantity'],
        2,
      );
    },
  );

  testWidgets(
    'KOT preview shows additional food and a separate reprint action',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = Session(
        client: MockClient((_) async => http.Response('{}', 200)),
        demoMode: true,
      )..user = {'restaurant_name': 'Test Restaurant'};
      await tester.runAsync(() async {
        session.local = await LocalStore.connect(
          databaseFactoryFfi,
          inMemoryDatabasePath,
        );
        await session.local!.setMeta(
          'kot_sent_quantities_v2_order-01',
          jsonEncode({'menu:roti': 2, 'menu:dal': 1}),
        );
        await session.local!.setMeta(
          'kot_last_ticket_v1_order-01',
          jsonEncode([line('roti', 2), line('dal', 1)]),
        );
      });
      final order = {
        'id': 'order-01',
        'table_number': '01',
        'order_type': 'dine_in',
        'items': [line('roti', 3), line('dal', 1), line('rice', 1, printed: 0)],
      };
      await tester.pumpWidget(MaterialApp(home: KotPage(session, order)));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(find.text('ADDITIONAL KOT'), findsOneWidget);
      expect(find.text('TABLE 01'), findsOneWidget);
      expect(find.text('roti'), findsOneWidget);
      expect(find.text('rice'), findsOneWidget);
      expect(find.text('dal'), findsNothing);
      expect(find.text('1'), findsNWidgets(2));
      expect(find.text('Reprint last KOT'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() => session.local!.db.close());
      session.dispose();
    },
  );
}
