import 'dart:convert';

import 'package:avtar_pos/core/local_store.dart';
import 'package:avtar_pos/core/models.dart';
import 'package:avtar_pos/core/session.dart';
import 'package:avtar_pos/features/analytics/local_reports.dart';
import 'package:avtar_pos/features/purchases/data/purchase_math.dart';
import 'package:avtar_pos/features/purchases/purchase_dashboard.dart';
import 'package:avtar_pos/features/purchases/purchase_bill_editor.dart';
import 'package:avtar_pos/features/purchases/purchase_ledger_details.dart';
import 'package:avtar_pos/ui/shared.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Json bill({String status = 'received'}) => {
  'id': 'bill-1',
  'name': 'Invoice T-001',
  'supplier_id': 'supplier-1',
  'supplier_name': 'Fresh Foods',
  'invoice_number': 'T-001',
  'purchase_date': '2026-10-07',
  'due_date': '2026-10-14',
  'status': status,
  'freight_minor': 1000,
  'paid_minor': status == 'received' ? 50000 : 0,
  'payment_mode': 'cash',
  'lines': [
    {
      'id': 'line-1',
      'purchase_item_id': 'tomato',
      'item_name': 'Tomato',
      'unit': 'kg',
      'quantity_milli': 5000,
      'unit_price_minor': 20000,
      'discount_minor': 1000,
      'tax_basis_points': 500,
    },
  ],
};
Json event(String kind, {int amount = 0, int qty = 0}) => {
  'id': Session.uuid.v4(),
  'name': kind,
  'kind': kind,
  'bill_id': 'bill-1',
  'date': '2026-10-07',
  'amount_minor': amount,
  'payment_mode': 'cash',
  'note': 'Test reason',
  'lines': qty == 0
      ? <Json>[]
      : [
          {
            'line_id': 'line-1',
            'purchase_item_id': 'tomato',
            'item_name': 'Tomato',
            'unit': 'kg',
            'quantity_milli': qty,
          },
        ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Session session;
  Future<void> setup({bool demo = true}) async {
    SharedPreferences.setMockInitialValues({});
    Session.prefs = await SharedPreferences.getInstance();
    session = Session(demoMode: demo)..user = {'id': 1, 'role': 'owner'};
    session.local = await LocalStore.connect(
      databaseFactoryFfi,
      inMemoryDatabasePath,
    );
    await LocalStore.put(session.local!.db, 'purchase_suppliers', {
      'id': 'supplier-1',
      'name': 'Fresh Foods',
      'is_active': true,
    });
    await LocalStore.put(session.local!.db, 'purchase_items', {
      'id': 'tomato',
      'name': 'Tomato',
      'category_id': 'veg',
      'category_name': 'Vegetables',
      'is_active': true,
    });
  }

  tearDown(() async {
    await session.local!.db.close();
    session.dispose();
  });
  setUp(() => setup());

  test('integer quantity, discounts, GST and freight have exact totals', () {
    final value = purchaseTotals(bill());
    expect(value['total_minor'], 104950);
    expect(maps(value['lines']).single['total_minor'], 103950);
    expect(purchaseDecimal('1.125', scale: 1000), 1125);
    expect(purchaseDecimal('10.05'), 1005);
    expect(() => purchaseDecimal('NaN'), throwsA(isA<ApiFailure>()));
    expect(() => purchaseDecimal('1.234'), throwsA(isA<ApiFailure>()));
  });
  test(
    'partial payments settle due; returns create refundable supplier credit',
    () {
      final b = purchaseTotals(bill());
      final payments = [event('payment', amount: 54950)];
      expect(purchaseBalance(b, payments)['due_minor'], 0);
      final returned = purchaseEvent(event('return', qty: 1000), [b], payments);
      expect(returned['amount_minor'], 20790);
      expect(
        purchaseBalance(b, [...payments, returned])['credit_minor'],
        20790,
      );
      final refunded = purchaseEvent(
        event('refund', amount: 20790),
        [b],
        [...payments, returned],
      );
      expect(
        purchaseBalance(b, [...payments, returned, refunded])['credit_minor'],
        0,
      );
    },
  );
  test('stock excludes orders and rejects over-return or excess kitchen consumption', () {
    final b = purchaseTotals(bill());
    expect(
      purchaseStock('tomato', 'kg', [
        {...b, 'status': 'ordered'},
      ], []),
      0,
    );
    final used = purchaseEvent(event('usage', qty: 4000), [b], []);
    expect(purchaseStock('tomato', 'kg', [b], [used]), 1000);
    expect(
      () => purchaseEvent(event('return', qty: 2000), [b], [used]),
      throwsA(isA<ApiFailure>()),
    );
    expect(
      () => purchaseEvent(event('waste', qty: 5001), [b], []),
      throwsA(isA<ApiFailure>()),
    );
  });
  test('return rounding in parts cannot create extra supplier credit', () {
    final b = purchaseTotals({
      ...bill(),
      'freight_minor': 0,
      'paid_minor': 0,
      'lines': [
        {
          'id': 'line-1',
          'purchase_item_id': 'tomato',
          'item_name': 'Tomato',
          'unit': 'pcs',
          'quantity_milli': 3000,
          'unit_price_minor': 1,
          'discount_minor': 1,
          'tax_basis_points': 0,
        },
      ],
    });
    final history = <Json>[];
    for (var i = 0; i < 3; i++) {
      final value = event('return', qty: 1000);
      maps(value['lines']);
      history.add(purchaseEvent(value, [b], history));
    }
    expect(history.fold<int>(0, (s, e) => s + number(e['amount_minor'])), 2);
  });
  test(
    'local draft becomes received once and duplicate invoice is blocked',
    () async {
      final draft = await session.savePurchaseBill(bill(status: 'draft'));
      await session.savePurchaseBill({...draft, 'status': 'received'});
      expect(
        () => session.savePurchaseBill({...draft, 'status': 'received'}),
        throwsA(isA<ApiFailure>()),
      );
      expect(
        () => session.savePurchaseBill({...bill(), 'id': 'bill-2'}),
        throwsA(isA<ApiFailure>()),
      );
      expect((await session.local!.listAll('purchase_bills')).length, 1);
    },
  );
  test('overpayment leaves both ledger and local stock unchanged', () async {
    await session.savePurchaseBill(bill());
    await session.recordPurchaseEvent(event('payment', amount: 54950));
    await expectLater(
      session.recordPurchaseEvent(event('payment', amount: 1)),
      throwsA(isA<ApiFailure>()),
    );
    expect((await session.local!.listAll('purchase_events')).length, 1);
    expect(
      purchaseStock(
        'tomato',
        'kg',
        await session.local!.listAll('purchase_bills'),
        await session.local!.listAll('purchase_events'),
      ),
      5000,
    );
  });
  test('invalid calendar dates and disabled purchases cannot save', () async {
    await expectLater(
      session.savePurchaseBill({...bill(), 'purchase_date': '2026-02-31'}),
      throwsA(isA<ApiFailure>()),
    );
    session.controlPolicy = {
      'features': {'purchases': false},
    };
    await expectLater(
      session.savePurchaseBill(bill()),
      throwsA(isA<ApiFailure>()),
    );
    expect(await session.local!.listAll('purchase_bills'), isEmpty);
  });
  test(
    'backdated debit cannot consume stock needed by later ledger entries',
    () {
      final b = purchaseTotals({...bill(), 'purchase_date': '2026-10-09'});
      final opening = {
        ...event('opening', qty: 5000),
        'bill_id': null,
        'date': '2026-10-07',
      };
      final used = {
        ...event('usage', qty: 5000),
        'bill_id': null,
        'date': '2026-10-08',
      };
      final backdated = {
        ...event('waste', qty: 1000),
        'bill_id': null,
        'date': '2026-10-07',
      };
      expect(purchaseStock('tomato', 'kg', [b], [opening, used]), 5000);
      expect(
        () => purchaseEvent(backdated, [b], [opening, used]),
        throwsA(isA<ApiFailure>()),
      );
    },
  );
  test('analytics combines older purchases with posted procurement and subtracts returns', () async {
    await session.savePurchaseBill(bill());
    await session.recordPurchaseEvent(event('return', qty: 1000));
    await LocalStore.put(session.local!.db, 'purchases', {
      'id': 'legacy-1',
      'item_name': 'Oil',
      'quantity': 1,
      'total_minor': 500,
      'purchase_date': '2026-10-07',
    });
    final report = await LocalReports(session.local!)
        .analytics('2026-10-07', '2026-10-07');
    expect(report['purchase']['entries'], 2);
    expect(report['purchase']['spend_minor'], 84660);
  });
  test(
    'offline purchase and payment save atomically with ordered durable uploads',
    () async {
      await session.local!.db.close();
      session.dispose();
      await setup(demo: false);
      session.controlPolicy = {
        'features': {'sync': false},
      };
      await session.savePurchaseBill(bill(status: 'draft'));
      await session.savePurchaseBill({...bill(), 'status': 'received'});
      await session.recordPurchaseEvent(event('payment', amount: 10000));
      final uploads = await session.local!.db.query('outbox', orderBy: 'seq');
      expect(uploads.length, 3);
      expect(uploads.map((r) => r['resource']), [
        'purchase_bills',
        'purchase_bills',
        'purchase_events',
      ]);
      expect(uploads[0]['method'], 'POST');
      expect(uploads[1]['method'], 'PUT');
      expect(uploads.map((r) => r['key']).toSet().length, 3);
      expect(
        jsonDecode(uploads.last['payload'] as String)['amount_minor'],
        10000,
      );
      expect(
        purchaseBalance(
          (await session.local!.listAll('purchase_bills')).single,
          await session.local!.listAll('purchase_events'),
        )['due_minor'],
        44950,
      );
    },
  );
  testWidgets(
    'entry saves draft, receives stock, pays and returns through the screens',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Future<void> settle() async {
        for (var step = 0; step < 15; step++) {
          await tester.pump(const Duration(milliseconds: 100));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
        }
        await tester.pumpAndSettle();
      }

      await tester.pumpWidget(
        MaterialApp(theme: appTheme(), home: PurchaseDashboard(session)),
      );
      await settle();
      await tester.tap(find.text('New purchase'));
      await settle();
      expect(find.byType(PurchaseBillEditor), findsOneWidget);
      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fresh Foods').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add item'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Price per unit (₹)'),
        '20',
      );
      await tester.tap(find.text('Add to purchase'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Pay full amount'));
      await tester.tap(find.text('Pay full amount'));
      await tester.pumpAndSettle();
      final paidField = find.widgetWithText(
        TextFormField,
        'Paid now (on receipt only)',
      );
      expect(
        tester
            .widget<EditableText>(
              find.descendant(
                of: paidField,
                matching: find.byType(EditableText),
              ),
            )
            .controller
            .text,
        '20.00',
      );
      await tester.tap(find.text('Pay later / udhaar'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<EditableText>(
              find.descendant(
                of: paidField,
                matching: find.byType(EditableText),
              ),
            )
            .controller
            .text,
        '0.00',
      );
      await tester.tap(find.text('Save draft'));
      await settle();
      expect(find.byType(PurchaseBillEditor), findsNothing);
      Json saved = {};
      await tester.runAsync(() async {
        saved = (await session.local!.listAll('purchase_bills')).single;
      });
      expect(saved['status'], 'draft');
      expect(saved['total_minor'], 2000);
      await tester.tap(find.text('Fresh Foods').first);
      await settle();
      expect(find.byType(PurchaseBillDetails), findsOneWidget);
      await tester.tap(find.text('Edit / receive purchase'));
      await settle();
      await tester.tap(find.text('Receive & save'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Receive purchase'));
      await settle();
      expect(find.byType(PurchaseBillEditor), findsNothing);
      await tester.tap(find.text('Record payment'));
      await settle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Amount (₹)'),
        '10',
      );
      await tester.tap(find.text('Save entry'));
      await settle();
      await tester.tap(find.text('Return items'));
      await settle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Quantity'),
        '0.5',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Reason (required)'),
        'Damaged stock',
      );
      await tester.tap(find.text('Save entry'));
      await settle();
      await tester.runAsync(() async {
        final values = await session.local!.listAll('purchase_bills'),
            history = await session.local!.listAll('purchase_events');
        expect(values.single['status'], 'received');
        expect(history.length, 2);
        expect(purchaseBalance(values.single, history)['due_minor'], 0);
        expect(purchaseStock('tomato', 'kg', values, history), 500);
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('dashboard stays usable at 320px and supplier/stock tabs open', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() => session.savePurchaseBill(bill()));
    await tester.pumpWidget(
      MaterialApp(theme: appTheme(), home: PurchaseDashboard(session)),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Net purchases · this month'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Suppliers'));
    await tester.tap(find.text('Suppliers'));
    await tester.pumpAndSettle();
    expect(find.text('Fresh Foods'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Material stock'));
    await tester.tap(find.text('Material stock'));
    await tester.pumpAndSettle();
    expect(find.text('5 kg'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
