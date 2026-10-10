import 'package:avtar_pos/core/local_store.dart';
import 'package:avtar_pos/core/models.dart';
import 'package:avtar_pos/features/orders/data/order_controller.dart';
import 'package:avtar_pos/features/orders/data/order_draft.dart';
import 'package:avtar_pos/features/orders/order_panel.dart';
import 'package:avtar_pos/features/orders/order_workspace_page.dart';
import 'package:avtar_pos/features/tables/floor_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'pos_usability_test.dart' as fixture;

Json table() => {
  'id': 'table',
  'table_number': '01',
  'section': 'Hall',
  'capacity': 4,
  'status': 'empty',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  testWidgets(
    'dining save stays disabled for an empty order; repeated taps confirm once after persistence',
    (tester) async {
      fixture.mobile(tester);
      final session = (await tester.runAsync(fixture.setup))!;
      await tester.runAsync(
        () => LocalStore.put(session.local!.db, 'tables', table()),
      );
      final controller = OrderController(session, newOrder(table: table()));
      var confirmations = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: OrderPanel(
              controller,
              checkout: () {},
              kot: () {},
              details: () {},
              saved: () => confirmations++,
            ),
          ),
        ),
      );
      await fixture.settleDb(tester);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Save & close'),
            )
            .onPressed,
        isNull,
      );
      controller.add({'id': 'tea', 'name': 'Tea', 'price_minor': 1000});
      await tester.runAsync(controller.flush);
      await fixture.settleDb(tester);
      final save = tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Save & close'),
          )
          .onPressed!;
      save();
      save();
      expect(confirmations, 0);
      await fixture.settleDb(tester);
      expect(confirmations, 1);
      final saved = (await tester.runAsync(
        () => session.local!.get('orders', '${controller.order['id']}'),
      ))!;
      expect(saved['status'], 'open');
      expect(number(maps(saved['items']).single['quantity']), 1);
      expect(
        await tester.runAsync(() => session.local!.list('bills')),
        isEmpty,
      );
      expect(
        await tester.runAsync(
          () => session.local!.meta(
            'kot_sent_quantities_v2_${controller.order['id']}',
          ),
        ),
        isNull,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await fixture.close(tester, session);
    },
  );

  testWidgets(
    'save and close returns to floor with feedback without billing or acknowledging KOT',
    (tester) async {
      fixture.mobile(tester);
      final session = (await tester.runAsync(fixture.setup))!;
      await tester.runAsync(() async {
        await LocalStore.put(session.local!.db, 'tables', table());
        await LocalStore.put(session.local!.db, 'menu_items', {
          'id': 'tea',
          'name': 'Tea',
          'category': 'Drinks',
          'price_minor': 1000,
          'is_active': true,
        });
      });
      await tester.pumpWidget(MaterialApp(home: FloorPage(session)));
      await fixture.settleDb(tester);
      await tester.tap(find.text('01'));
      await fixture.settleDb(tester);
      expect(find.text('Table 01'), findsOneWidget);
      await tester.tap(find.text('Tea'));
      await fixture.settleDb(tester);
      await tester.tap(find.byTooltip('Order items'));
      await fixture.settleDb(tester);
      await tester.tap(find.text('Save & close'));
      await fixture.settleDb(tester);
      expect(find.byType(OrderWorkspacePage), findsNothing);
      expect(find.text('Order completion pending'), findsOneWidget);
      expect(
        find.text('Order saved. Table remains open; kitchen KOT is pending.'),
        findsOneWidget,
      );
      expect(
        await tester.runAsync(() => session.local!.list('bills')),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
      await fixture.close(tester, session);
    },
  );
}
