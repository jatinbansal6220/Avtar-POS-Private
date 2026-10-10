import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:avtar_pos/core/local_store.dart';
import 'package:avtar_pos/ui/home_page.dart';
import 'package:avtar_pos/core/models.dart';
import 'package:avtar_pos/features/orders/data/order_controller.dart';
import 'package:avtar_pos/features/analytics/local_reports.dart';
import 'package:avtar_pos/features/analytics/closing_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'pos_usability_test.dart' as fixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  test('undo restores removed draft items without changing customer or KOT acknowledgements', () async {
    final session = await fixture.setup();
    final controller = OrderController(session, fixture.order());
    await controller.refreshKotState();
    controller.quantity(0, -3);
    controller.text('customer_name', 'Aman');
    expect(controller.items, isEmpty);
    controller.undo();
    await controller.flush();
    expect(controller.items.single['quantity'], 3);
    expect(controller.items.single['_kot_printed_quantity'], 2);
    expect(controller.order['customer_name'], 'Aman');
    expect(controller.kotPendingQuantity, 1);
    expect((await session.local!.readDraft('order'))!['customer_name'], 'Aman');
    controller.quantity(0, 1);
    controller.undo();
    await controller.flush();
    expect(controller.items.single['quantity'], 3);
    controller.add({'id': 'rice', 'name': 'Rice', 'price_minor': 10000});
    controller.undo();
    await controller.flush();
    expect(controller.items.length, 1);
    controller.quantity(0, 1);
    await controller.save();
    expect(controller.canUndo, false);
    controller.quantity(0, 1);
    controller.voidItem(0, 'Customer cancelled');
    expect(controller.canUndo, false);
    expect(maps(controller.order['voids']).length, 1);
    await controller.flush();
    controller.dispose();
    await session.local!.db.close();
    session.dispose();
  });
  test('bill search finds snapshot customer, phone, merged table and date with filters', () async {
    final session = await fixture.setup();
    await LocalStore.put(session.local!.db, 'bills', {
      'id': 'bill',
      'bill_number': 'AV-456',
      'receipt': {
        'bill_number': 'AV-456',
        'customer_name': 'Aman Singh',
        'customer_phone': '9876543210',
        'table_number': 'T01',
        'merged_table_numbers': ['T01', 'T02'],
        'generated_at': '2026-10-07T12:00:00+05:30',
        'total_minor': 30000,
      },
    });
    for (final query in ['456', 'aman', '987654', 'T01', 'T02', '2026-10-07']) {
      expect(
        (await session.local!.list('bills', query: query)).single['id'],
        'bill',
      );
    }
    expect(
      await session.local!.list(
        'bills',
        query: '987654',
        filters: {'from': '2026-10-08'},
      ),
      isEmpty,
    );
    expect(await session.local!.list('bills', query: "' OR 1=1 --"), isEmpty);
    await session.local!.db.close();
    session.dispose();
  });
  test(
    'pending totals prefer drafts and count a merged shared cart once',
    () async {
      final session = await fixture.setup();
      final current = {
        ...fixture.order(),
        'id': 'primary',
        'table_id': 'one',
        'table_number': '01',
        'merged_table_ids': ['one', 'two'],
        'merged_table_numbers': ['01', '02'],
      };
      await LocalStore.put(session.local!.db, 'tables', {
        'id': 'one',
        'table_number': '01',
        'current_order_id': 'primary',
      });
      await LocalStore.put(session.local!.db, 'tables', {
        'id': 'two',
        'table_number': '02',
        'current_order_id': 'primary',
      });
      await LocalStore.put(session.local!.db, 'orders', current);
      await session.local!.draft({
        ...current,
        'items': [
          {'quantity': 4, 'price_minor': 10000},
        ],
      });
      await session.local!.draft({
        ...fixture.order(),
        'id': 'oldChild',
        'table_id': 'two',
      });
      await LocalStore.put(session.local!.db, 'orders', {
        ...fixture.order(),
        'id': 'billed',
        'status': 'billed',
      });
      await session.local!.draft({...fixture.order(), 'id': 'billed'});
      final result = await LocalReports(session.local!).openOrderSummary();
      expect(result, {'orders': 1, 'items_subtotal_minor': 40000});
      await session.local!.db.close();
      session.dispose();
    },
  );
  test(
    'day closing allocates mixed tender once and separates unbilled carts',
    () async {
      final session = await fixture.setup();
      final receipt = {
        'bill_number': 'AV-1',
        'generated_at': indiaTimestamp(),
        'total_minor': 60000,
        'payment_method': 'mixed',
        'payments': [
          {'method': 'cash', 'amount_minor': 10000},
          {'method': 'upi', 'amount_minor': 20000},
          {'method': 'card', 'amount_minor': 30000},
        ],
      };
      await LocalStore.put(session.local!.db, 'bills', {
        ...receipt,
        'id': 'bill',
        'receipt': receipt,
      });
      await session.local!.draft(fixture.order());
      final result = await LocalReports(session.local!)
          .dayReport(day(indiaNow()), day(indiaNow()));
      expect((result['summary'] as Json)['revenue_minor'], 60000);
      final totals = {
        for (final row in maps(result['payments']))
          row['method']: row['amount_minor'],
      };
      expect(totals, {'Cash': 10000, 'UPI': 20000, 'Card': 30000});
      expect(result['open_orders_now'], {
        'orders': 1,
        'items_subtotal_minor': 30000,
      });
      await session.local!.db.close();
      session.dispose();
    },
  );
  testWidgets('desktop menu with day closing fits a short window', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = (await tester.runAsync(fixture.setup))!;
    await tester.pumpWidget(MaterialApp(home: HomePage(session)));
    await fixture.settleDb(tester);
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(tester.takeException(), isNull);
    await fixture.close(tester, session);
  });

  testWidgets('day closing keeps owner verification and fits mobile', (
    tester,
  ) async {
    fixture.mobile(tester);
    final session = (await tester.runAsync(fixture.setup))!;
    await tester.runAsync(
      () => LocalStore.put(session.local!.db, 'settings', {
        'id': 'settings',
        'invoice_delete_code_hash': sha256
            .convert(utf8.encode('1234'))
            .toString(),
      }),
    );
    await tester.pumpWidget(MaterialApp(home: ClosingPage(session)));
    await tester.pumpAndSettle();
    expect(find.text('Verify owner code'), findsOneWidget);
    expect(find.text('Final sales'), findsNothing);
    await tester.enterText(find.byType(TextField), '1234');
    await tester.tap(find.text('Open day closing'));
    await fixture.settleDb(tester);
    expect(find.text('Final sales'), findsOneWidget);
    expect(find.text('Open orders now'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await fixture.close(tester, session);
  });
}
