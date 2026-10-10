import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:avtar_pos/core/local_store.dart';
import 'package:avtar_pos/features/banks/upi_qr.dart';
import 'package:avtar_pos/ui/receipt.dart';
import 'package:avtar_pos/core/models.dart';
import 'package:avtar_pos/core/session.dart';
import 'package:avtar_pos/features/billing/checkout_page.dart';
import 'package:avtar_pos/features/orders/data/order_controller.dart';
import 'package:avtar_pos/features/orders/data/order_draft.dart';
import 'package:avtar_pos/features/orders/order_panel.dart';
import 'package:avtar_pos/features/orders/order_workspace_page.dart';
import 'package:avtar_pos/features/tables/floor_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Json order() => {
  ...newOrder(),
  'id': 'order',
  'items': [
    {
      'menu_item_id': 'roti',
      'item_name': 'Roti',
      'price_minor': 10000,
      'quantity': 3,
      '_kot_printed_quantity': 2,
    },
  ],
};

Future<Session> setup() async {
  SharedPreferences.setMockInitialValues({});
  Session.prefs = await SharedPreferences.getInstance();
  final session = Session(
    client: MockClient((_) async => http.Response('{}', 200)),
    demoMode: true,
  )..user = {'id': 1, 'role': 'owner'};
  session.local = await LocalStore.connect(
    databaseFactoryFfi,
    inMemoryDatabasePath,
  );
  await LocalStore.put(session.local!.db, 'settings', {
    'id': 'settings',
    'is_tax_enabled': false,
  });
  return session;
}

void mobile(WidgetTester tester) {
  tester.view.physicalSize = const Size(320, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> settleDb(WidgetTester tester) async {
  for (var attempt = 0; attempt < 20; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    // Returning to a route can schedule its deferred load after this frame.
    // Build the new loading state before deciding that database work settled.
    await tester.pump();
    if (find.byType(CircularProgressIndicator).evaluate().isEmpty &&
        find.byType(LinearProgressIndicator).evaluate().isEmpty &&
        find.text('Saving on device…').evaluate().isEmpty) {
      await tester.pumpAndSettle();
      return;
    }
  }
}

Future<void> close(WidgetTester tester, Session session) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.runAsync(() => session.local!.db.close());
  session.dispose();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test(
    'restoring a saved customer cart reloads its kitchen acknowledgement',
    () async {
      final session = await setup();
      final controller = OrderController(session, newOrder(channel: 'pos'));
      await session.local!.setMeta(
        'kot_sent_quantities_v2_saved',
        '{"menu:roti":3}',
      );
      controller.startFreshOrder({
        ...order(),
        'id': 'saved',
        'items': [
          {
            'menu_item_id': 'roti',
            'item_name': 'Roti',
            'price_minor': 10000,
            'quantity': 3,
          },
        ],
      });
      await controller.refreshKotState();
      expect(controller.kotPendingQuantity, 0);
      controller.quantity(0, 1);
      await controller.flush();
      expect(controller.kotPendingQuantity, 1);
      controller.dispose();
      await session.local!.db.close();
      session.dispose();
    },
  );

  testWidgets(
    'unsaved dining items appear on floor and in running-table filter before KOT',
    (tester) async {
      mobile(tester);
      final session = (await tester.runAsync(setup))!;
      await tester.runAsync(() async {
        final table = <String, dynamic>{
          'id': 'table',
          'table_number': '01',
          'section': 'Hall',
          'capacity': 4,
          'status': 'empty',
        };
        await LocalStore.put(session.local!.db, 'tables', table);
        final controller = OrderController(session, newOrder(table: table));
        controller.add({'id': 'roti', 'name': 'Roti', 'price_minor': 10000});
        await controller.flush();
        expect(
          await session.local!.get('orders', controller.order['id']),
          isNull,
        );
        controller.dispose();
      });
      await tester.pumpWidget(MaterialApp(home: FloorPage(session)));
      await settleDb(tester);
      expect(find.text('Order completion pending'), findsOneWidget);
      expect(find.text('KOT pending: 1'), findsOneWidget);
      expect(find.text('Items ${money(10000)}'), findsOneWidget);
      await tester.drag(find.byType(ListView).first, const Offset(-220, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Order running'));
      await settleDb(tester);
      expect(find.text('01'), findsOneWidget);
      await tester.drag(find.byType(ListView).first, const Offset(220, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Available'));
      await settleDb(tester);
      expect(find.text('01'), findsNothing);
      expect(tester.takeException(), isNull);
      await close(tester, session);
    },
  );

  testWidgets(
    'saved UPI IDs generate selectable accounts and receipt keeps chosen payee',
    (tester) async {
      mobile(tester);
      final session = (await tester.runAsync(setup))!;
      await tester.runAsync(() async {
        for (final id in ['first', 'second']) {
          await session.mutate('banks', {
            'id': id,
            'account_name': '$id counter',
            'account_number': '$id@bank',
            'bank_name': 'Bank',
            'account_type': 'upi',
            'is_active': true,
            'initial_balance_minor': 0,
            'use_for_card': false,
            'is_default_qr': id == 'first',
          });
        }
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => CheckoutPage(session, order()),
                  ),
                ),
                child: const Text('Open checkout'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open checkout'));
      await tester.pump(const Duration(milliseconds: 300));
      await settleDb(tester);
      await tester.ensureVisible(find.text('UPI'));
      await tester.tap(find.text('UPI'));
      await tester.pumpAndSettle();
      final dropdown = find.widgetWithText(
        DropdownButtonFormField<String>,
        'UPI QR account',
      );
      await tester.ensureVisible(dropdown);
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('second counter').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Complete bill'));
      await settleDb(tester);
      final bills = (await tester.runAsync(
        () => session.local!.listAll('bills'),
      ))!;
      final receipt = bills.single['receipt'] as Json;
      expect(receipt['qr_upi_id'], 'second@bank');
      expect(receipt['qr_bank_account_id'], 'second');
      expect(upiReceiptAmount(receipt), 30000);
      expect(receiptUpiQr(receipt), isNotNull);
      final bank = (await tester.runAsync(
        () => session.local!.get('banks', 'second'),
      ))!;
      expect(bank['qr_image_base64'], isNotEmpty);
      await tester.pumpWidget(
        MaterialApp(home: ReceiptPage(session, bills.single)),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('UPI ID: second@bank'), findsOneWidget);
      expect(find.textContaining('Pay ${money(30000)}'), findsOneWidget);
      final receiptOutput = Platform.environment['UPI_RECEIPT_VERIFY_PNG'];
      if (receiptOutput != null) {
        final qrImage = tester
            .widgetList<Image>(find.byType(Image))
            .firstWhere((widget) => widget.image is MemoryImage);
        await tester.runAsync(
          () => precacheImage(
            qrImage.image,
            tester.element(find.byType(ReceiptPage)),
          ),
        );
        await tester.pumpAndSettle();
        final paper = tester.renderObject<RenderRepaintBoundary>(
          find
              .ancestor(
                of: find.textContaining('UPI ID: second@bank'),
                matching: find.byType(RepaintBoundary),
              )
              .first,
        );
        await tester.runAsync(() async {
          final snapshot = await paper.toImage(pixelRatio: 3);
          final bytes = await snapshot.toByteData(
            format: ui.ImageByteFormat.png,
          );
          await File(receiptOutput).writeAsBytes(bytes!.buffer.asUint8List());
          snapshot.dispose();
        });
      }

      expect(tester.takeException(), isNull);
      await close(tester, session);
    },
  );

  testWidgets(
    'merged tables reopen one shared cart despite an old child draft',
    (tester) async {
      mobile(tester);
      final session = (await tester.runAsync(setup))!;
      await tester.runAsync(() async {
        for (final n in ['01', '02']) {
          await LocalStore.put(session.local!.db, 'tables', {
            'id': 'table$n',
            'table_number': n,
            'capacity': 4,
            'section': 'Hall',
            'status': 'occupied',
            'current_order_id': 'order$n',
          });
          final original = {
            ...order(),
            'id': 'order$n',
            'table_id': 'table$n',
            'table_number': n,
            'order_type': 'dine_in',
          };
          await LocalStore.put(session.local!.db, 'orders', original);
          await session.local!.draft(original);
        }
        await session.mergeDiningTables(
          (await session.local!.readDraft('order01'))!,
          '02',
        );
        // Simulate an old restored child draft without merge metadata.
        await session.local!.draft({
          ...order(),
          'id': 'order02',
          'table_id': 'table02',
          'table_number': '02',
          'order_type': 'dine_in',
        });
      });
      await tester.pumpWidget(MaterialApp(home: FloorPage(session)));
      await settleDb(tester);
      expect(find.text('Merged tables: 01 + 02'), findsNWidgets(2));
      for (final n in ['02', '01']) {
        await tester.tap(find.text(n));
        await settleDb(tester);
        final workspace = tester.widget<OrderWorkspacePage>(
          find.byType(OrderWorkspacePage),
        );
        expect(workspace.order['id'], 'order01');
        expect(
          find.text('Merged tables: 01 + 02 · Shared order'),
          findsOneWidget,
        );
        await tester.tap(find.byTooltip('Order items'));
        await tester.pumpAndSettle();
        final controller = tester
            .widget<OrderPanel>(find.byType(OrderPanel))
            .controller;
        expect(number(controller.items.single['quantity']), n == '02' ? 6 : 7);
        controller.add({'id': 'roti', 'name': 'Roti', 'price_minor': 10000});
        await tester.runAsync(controller.flush);
        await tester.pageBack();
        await settleDb(tester);
        expect(
          find.text('Items ${money(n == '02' ? 70000 : 80000)}'),
          findsNWidgets(2),
        );
        expect(tester.takeException(), isNull);
      }
      await close(tester, session);
    },
  );

  testWidgets(
    'floor shows newest saved draft, customer, time and readable service status',
    (tester) async {
      mobile(tester);
      final session = (await tester.runAsync(setup))!;
      await tester.runAsync(() async {
        final table = {
          'id': 'table',
          'table_number': '01',
          'capacity': 4,
          'section': 'Hall',
          'status': 'bill_pending',
          'current_order_id': 'order',
        };
        await LocalStore.put(session.local!.db, 'tables', table);
        final current = {
          ...order(),
          'table_id': 'table',
          'table_number': '01',
          'order_type': 'dine_in',
          'customer_name': 'Aman',
          'created_at': indiaTimestamp(
            indiaNow().subtract(const Duration(minutes: 30)),
          ),
        };
        await LocalStore.put(session.local!.db, 'orders', {
          ...current,
          'items': [
            {'item_name': 'Roti', 'price_minor': 10000, 'quantity': 1},
          ],
        });
        await session.local!.draft(current);
      });
      await tester.pumpWidget(MaterialApp(home: FloorPage(session)));
      await settleDb(tester);
      expect(find.text('Aman'), findsOneWidget);
      expect(find.text('KOT pending: 1'), findsOneWidget);
      expect(find.text('Items ${money(30000)}'), findsOneWidget);
      expect(find.text('Open 30m'), findsOneWidget);
      expect(find.text('Payment pending'), findsWidgets);
      expect(tester.takeException(), isNull);
      await close(tester, session);
    },
  );

  testWidgets(
    'cart shows pending KOT and confirms only after local draft saves',
    (tester) async {
      mobile(tester);
      final session = (await tester.runAsync(setup))!;
      final controller = OrderController(session, order());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: OrderPanel(
              controller,
              checkout: () {},
              kot: () {},
              details: () {},
            ),
          ),
        ),
      );
      await settleDb(tester);
      expect(find.text('KOT pending: 1 item(s)'), findsOneWidget);
      await tester.tap(find.byTooltip('Increase quantity'));
      await settleDb(tester);
      expect(find.text('KOT pending: 2 item(s)'), findsOneWidget);
      expect(find.text('Saved on device'), findsOneWidget);
      final saved = (await tester.runAsync(
        () => session.local!.readDraft('order'),
      ))!;
      expect(maps(saved['items']).single['quantity'], 4);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await close(tester, session);
    },
  );

  testWidgets('mobile menu exposes KOT and Bill without opening cart first', (
    tester,
  ) async {
    mobile(tester);
    final session = (await tester.runAsync(setup))!;
    await tester.pumpWidget(
      MaterialApp(home: OrderWorkspacePage(session, order())),
    );
    await settleDb(tester);
    expect(find.text('View order'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'KOT'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Bill'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await close(tester, session);
  });

  testWidgets(
    'checkout keeps actions visible and calculates cash change without changing bill',
    (tester) async {
      mobile(tester);
      final session = (await tester.runAsync(setup))!;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => CheckoutPage(session, order()),
                  ),
                ),
                child: const Text('Open checkout'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open checkout'));
      await tester.pump(const Duration(milliseconds: 300));
      await settleDb(tester);
      expect(find.text('Total to pay'), findsOneWidget);
      expect(find.text('Complete bill').hitTestable(), findsOneWidget);
      expect(find.text('Print bill').hitTestable(), findsOneWidget);
      expect(find.text('Discount (%)'), findsNothing);
      final cash = find.widgetWithText(TextField, 'Cash received (₹)');
      await tester.scrollUntilVisible(
        cash,
        150,
        scrollable: find
            .byWidgetPredicate(
              (widget) =>
                  widget is Scrollable &&
                  widget.axisDirection == AxisDirection.down,
            )
            .last,
      );
      await tester.enterText(cash, '500');
      await tester.pumpAndSettle();
      expect(find.text('Change to return: ${money(20000)}'), findsOneWidget);
      await tester.enterText(cash, '250');
      await tester.pumpAndSettle();
      expect(find.text('Cash remaining: ${money(5000)}'), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Complete bill'),
            )
            .onPressed,
        isNull,
      );
      await tester.enterText(cash, '500.01');
      await tester.pumpAndSettle();
      expect(find.text('Change to return: ${money(20001)}'), findsOneWidget);
      await tester.enterText(cash, 'NaN');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Complete bill'),
            )
            .onPressed,
        isNull,
      );
      await tester.enterText(cash, '500');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Complete bill'));
      await settleDb(tester);
      final bills = (await tester.runAsync(
        () => session.local!.listAll('bills'),
      ))!;
      expect(bills.single['total_minor'], 30000);
      final receipt = bills.single['receipt'] as Json;
      expect(maps(receipt['payments']).single['amount_minor'], 30000);
      expect(tester.takeException(), isNull);
      await close(tester, session);
    },
  );
  testWidgets(
    'split payment shows remaining amount and enables card account after entering card tender',
    (tester) async {
      tester.view.physicalSize = const Size(800, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = (await tester.runAsync(setup))!;
      await tester.runAsync(
        () => LocalStore.put(session.local!.db, 'banks', {
          'id': 'bank',
          'account_name': 'Test bank',
          'bank_name': 'Bank',
          'account_type': 'current',
          'is_active': true,
          'use_for_card': true,
        }),
      );
      await tester.pumpWidget(
        MaterialApp(home: CheckoutPage(session, order())),
      );
      await settleDb(tester);
      await tester.tap(find.text('Split payment'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Complete bill'),
            )
            .onPressed,
        isNull,
      );
      final vertical = find
          .byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down,
          )
          .last;
      final cash = find.widgetWithText(TextField, 'CASH amount');
      await tester.scrollUntilVisible(cash, 120, scrollable: vertical);
      await tester.enterText(cash, '100');
      await tester.pumpAndSettle();
      final card = find.widgetWithText(TextField, 'CARD amount');
      await tester.scrollUntilVisible(card, 120, scrollable: vertical);
      await tester.enterText(card, '200');
      await tester.pumpAndSettle();
      expect(find.text('Card settlement account'), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Complete bill'),
            )
            .onPressed,
        isNotNull,
      );
      await tester.enterText(card, '250');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Complete bill'),
            )
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
      await close(tester, session);
    },
  );
}
