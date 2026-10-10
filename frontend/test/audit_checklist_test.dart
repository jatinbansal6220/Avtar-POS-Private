import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:avtar_pos/core/local_store.dart';
import 'package:avtar_pos/core/session.dart';
import 'package:avtar_pos/features/demo/demo_seed.dart';
import 'package:avtar_pos/features/orders/data/order_draft.dart';
import 'package:avtar_pos/features/orders/data/order_controller.dart';

// Audit-only regression checks; no production behavior is changed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Session session;
  Future<void> settled() async {
    await Future<void>.delayed(const Duration(milliseconds: 30));
    while (session.syncing) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }

  setUp(() async {
    session = Session()..user = {'id': 1, 'role': 'owner'};
    session.local = await LocalStore.connect(
      databaseFactoryFfi,
      inMemoryDatabasePath,
    );
    await session.local!.setMeta('cursor', '0');
    await LocalStore.put(session.local!.db, 'tables', {
      'id': 'audit-table',
      'table_number': 'AUDIT',
      'status': 'empty',
    });
  });
  tearDown(() async {
    await settled();
    session.dispose();
    await session.local!.db.close();
  });
  test('offline demo seed provides populated tables, staff, invoices and analytics', () async {
    await seedOfflineDemo(session.local!);
    final tables = await session.local!.list('tables');
    final menu = await session.local!.list('menu_items');
    final staff = await session.local!.list('staff');
    final bills = await session.local!.list('bills');
    final report = await session.request(
      'GET',
      'analytics?from=2000-01-01&to=2099-01-01',
    );
    expect(
      tables
          .where((row) => (row['table_number'] as String).startsWith('T'))
          .toList(),
      hasLength(12),
    );
    expect(tables.where((row) => row['status'] == 'occupied'), isNotEmpty);
    expect(tables.where((row) => row['status'] == 'bill_pending'), isNotEmpty);
    expect(menu.length, greaterThanOrEqualTo(20));
    expect(staff.length, greaterThanOrEqualTo(4));
    expect(bills.length, greaterThanOrEqualTo(6));
    expect(report['summary']['bills'], greaterThan(0));
    expect(report['top_week'], isNotNull);
  });
  test('fresh database saves table order and marks occupied', () async {
    final order = newOrder(
      table: {'id': 'audit-table', 'table_number': 'AUDIT'},
    );
    await session.enqueueOrder(order);
    await settled();
    expect(
      (await session.local!.get('tables', 'audit-table'))!['status'],
      'occupied',
    );
    expect(order['order_type'], 'dine_in');
  });
  test(
    'manager clearing a final voided item releases its table atomically',
    () async {
      final order =
          newOrder(table: {'id': 'audit-table', 'table_number': 'AUDIT'})
            ..['items'] = [
              {
                'item_name': 'Cancelled item',
                'quantity': 1,
                'price_minor': 10000,
              },
            ];
      await session.enqueueOrder(order);
      final controller = OrderController(session, order);
      controller.voidItem(0, 'Guest changed their mind');
      await controller.clearEmptyDiningTable();

      final table = await session.local!.get('tables', 'audit-table');
      final savedOrder = await session.local!.get('orders', order['id']);
      expect(table!['status'], 'empty');
      expect(table['current_order_id'], isNull);
      expect(savedOrder!['status'], 'cancelled');
      expect(await session.local!.readDraft(order['id']), isNull);
      controller.dispose();
    },
  );
  test(
    'bill pending is a table status transition, not a normal order save',
    () async {
      final order =
          newOrder(table: {'id': 'audit-table', 'table_number': 'AUDIT'})
            ..['items'] = [
              {
                'item_name': 'Pending item',
                'quantity': 1,
                'price_minor': 10000,
              },
            ];
      final controller = OrderController(session, order);
      await controller.markBillPending();
      final table = await session.local!.get('tables', 'audit-table');
      expect(table!['status'], 'bill_pending');
      expect(table['current_order_id'], order['id']);
      controller.dispose();
    },
  );
  test(
    'Save Order changes a dining table locally in under one second',
    () async {
      // The upload worker must never be on this path: a cashier needs instant
      // floor feedback even while the API is slow or unavailable.
      final order =
          newOrder(table: {'id': 'audit-table', 'table_number': 'AUDIT'})
            ..['items'] = [
              {'item_name': 'Local item', 'quantity': 1, 'price_minor': 10000},
            ];
      final watch = Stopwatch()..start();
      await session.enqueueOrder(order);
      final table = await session.local!.get('tables', 'audit-table');
      watch.stop();
      expect(table!['status'], 'occupied');
      expect(table['current_order_id'], order['id']);
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
    },
  );
  test('saving more items on same open order retains added quantity', () async {
    final controller = OrderController(session, newOrder());
    const item = {
      'id': 'audit-item',
      'name': 'Audit item',
      'price_minor': 10000,
    };
    controller.add(item);
    await controller.save();
    await settled();
    controller.add(item);
    await controller.save();
    await settled();
    expect(controller.items.single['quantity'], 2);
    controller.dispose();
  });
  test('local bill reference retains complete receipt after sync', () async {
    final order = newOrder();
    order['items'] = [
      {'item_name': 'Audit item', 'quantity': 1, 'price_minor': 10000},
    ];
    final bill = await session.enqueueBill(order, {
      'discount_basis_points': 0,
      'payment_method': 'cash',
    });
    expect(bill['total_minor'], 10000);
    await settled();
    final id = await session.local!.meta('bill_${order['id']}');
    final stored = await session.local!.get('bills', id!);
    expect(stored!['receipt'], isNotNull);
  });
  test('attendance read includes locally saved attendance', () async {
    await session.mutate('attendance', {
      'staff_id': 'audit-staff',
      'date': '2026-09-18',
      'status': 'present',
    });
    await settled();
    final page = await session.request(
      'GET',
      'attendance?staff_id=audit-staff&from=2026-09-01&to=2026-09-30',
    );
    expect(page['data'], isNotEmpty);
  });
  test('analytics of empty database has zero sales', () async {
    final data = await session.request(
      'GET',
      'analytics?from=2000-01-01&to=2000-01-01',
    );
    expect(data['summary']['revenue_minor'], 0);
  });
  test('staff add persists complete profile locally', () async {
    final member = await session.mutate('staff', {
      'name': 'Audit only',
      'phone': '0000000000',
      'role': 'chef',
      'joining_date': '2026-09-18',
      'monthly_salary_minor': 2000000,
      'qualification': 'Test',
      'degree': 'Test',
      'experience': '2 years',
    });
    await settled();
    final stored = await session.local!.get('staff', member['id']);
    expect(stored!['name'], 'Audit only');
    expect(stored['experience'], '2 years');
  });
  test('new dining table has a usable empty status', () async {
    final table = await session.mutate('tables', {
      'table_number': 'NEW',
      'section': 'Main',
      'capacity': 4,
    });
    await settled();
    expect(
      (await session.local!.get('tables', table['id']))!['status'],
      'empty',
    );
  });
  test(
    'settings API used by settings page restores saved restaurant',
    () async {
      await session.mutate('settings', {'restaurant_name': 'Audit restaurant'});
      await settled();
      final page = await session.request('GET', 'settings');
      expect(page['data'], isNotNull);
    },
  );
  test('inventory keeps each physical count as dated local history', () async {
    final item = await session.createInventoryItem(
      name: 'Steel serving spoon',
      quantity: 24,
      note: 'Opening count',
    );
    await session.recordInventoryQuantity(
      item,
      quantity: 18,
      note: 'After dinner service',
    );
    final current = await session.local!.get('inventory_items', item['id']);
    final history = await session.local!.list(
      'inventory_entries',
      filters: {'inventory_item_id': item['id']},
      limit: 20,
    );
    expect(current!['current_quantity'], 18);
    expect(history, hasLength(2));
    expect(history.map((entry) => entry['quantity']), containsAll([24, 18]));
    expect(
      history.where((entry) => entry['quantity'] == 18).single['note'],
      'After dinner service',
    );
  });
}
