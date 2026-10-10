part of 'session.dart';

extension SessionPurchases on Session {
  void _purchaseAccess() {
    requireFeature('purchases');
    if (!manager) throw ApiFailure(403, 'Manager access required.');
  }

  Future<List<Json>> _purchaseRows(
    DatabaseExecutor txn,
    String resource,
  ) async => (await txn.query(
    'records',
    columns: ['body'],
    where: 'resource=?',
    whereArgs: [resource],
  )).map((r) => jsonDecode(r['body'] as String) as Json).toList();

  Future<Json> savePurchaseBill(Json input) async {
    _purchaseAccess();
    final bill = purchaseTotals(input);
    bill['id'] ??= Session.uuid.v4();
    bill['created_at'] ??= indiaTimestamp();
    bill['updated_at'] = indiaTimestamp();
    final id = '${bill['id']}';
    final date = '${bill['purchase_date']}';
    if (DateTime.tryParse(date) == null || day(DateTime.parse(date)) != date) {
      throw ApiFailure(422, 'Choose a valid purchase date.');
    }
    final due = '${bill['due_date'] ?? ''}';
    if (due.isNotEmpty &&
        (DateTime.tryParse(due) == null ||
            day(DateTime.parse(due)) != due ||
            due.compareTo(date) < 0)) {
      throw ApiFailure(422, 'Due date must be on or after the purchase date.');
    }
    if (![
      'draft',
      'ordered',
      'received',
      'cancelled',
    ].contains(bill['status'])) {
      throw ApiFailure(422, 'Choose a purchase status.');
    }
    final paid = number(bill['paid_minor']);
    if (paid < 0 ||
        paid > number(bill['total_minor']) ||
        ((bill['status'] != 'received' || bill['payment_mode'] == 'credit') &&
            paid != 0)) {
      throw ApiFailure(
        422,
        'Check initial payment. Drafts and orders cannot record payment.',
      );
    }
    if (![
      'cash',
      'upi',
      'bank_transfer',
      'credit',
    ].contains(bill['payment_mode'])) {
      throw ApiFailure(422, 'Choose a payment method.');
    }
    await local!.db.transaction((txn) async {
      final bills = await _purchaseRows(txn, 'purchase_bills');
      final old = bills.where((b) => b['id'] == id).firstOrNull;
      if (old != null && number(old['version']) != number(bill['version'])) {
        throw ApiFailure(
          409,
          'This purchase changed while you were editing. Reopen it before saving.',
        );
      }
      if (old != null && ['received', 'cancelled'].contains(old['status'])) {
        throw ApiFailure(
          409,
          'Posted or cancelled purchases cannot be edited. Record a return instead.',
        );
      }
      if (old?['status'] == 'ordered' && bill['status'] == 'draft') {
        throw ApiFailure(422, 'An order cannot return to draft.');
      }
      final supplier = (await _purchaseRows(
        txn,
        'purchase_suppliers',
      )).where((s) => s['id'] == bill['supplier_id']).firstOrNull;
      if (supplier == null) throw ApiFailure(422, 'Choose a saved supplier.');
      bill['supplier_name'] = supplier['name'];
      final invoice = '${bill['invoice_number'] ?? ''}'.trim().toLowerCase();
      if (invoice.isNotEmpty &&
          bill['status'] != 'cancelled' &&
          bills.any(
            (b) =>
                b['id'] != id &&
                b['status'] != 'cancelled' &&
                b['supplier_id'] == bill['supplier_id'] &&
                '${b['invoice_number'] ?? ''}'.trim().toLowerCase() == invoice,
          )) {
        throw ApiFailure(422, 'This supplier invoice is already recorded.');
      }
      final items = await _purchaseRows(txn, 'purchase_items');
      final seen = <String>{};
      for (final line in maps(bill['lines'])) {
        if (!seen.add('${line['purchase_item_id']}|${line['unit']}') ||
            !items.any((i) => i['id'] == line['purchase_item_id'])) {
          throw ApiFailure(
            422,
            'Choose existing items and combine repeated items in the same unit.',
          );
        }
      }
      await LocalStore.put(txn, 'purchase_bills', bill);
      await queueMutation(
        txn,
        'purchase_bills',
        id,
        old == null ? 'POST' : 'PUT',
        old == null ? 'purchase_bills' : 'purchase_bills/$id',
        bill,
      );
    });
    publishSave(['purchase_bills']);
    return bill;
  }

  Future<Json> recordPurchaseEvent(Json input) async {
    _purchaseAccess();
    final draft = clone(input)..['id'] ??= Session.uuid.v4();
    draft['created_at'] = indiaTimestamp();
    draft['updated_at'] = indiaTimestamp();
    late Json saved;
    await local!.db.transaction((txn) async {
      saved = purchaseEvent(
        draft,
        await _purchaseRows(txn, 'purchase_bills'),
        await _purchaseRows(txn, 'purchase_events'),
      );
      final items = await _purchaseRows(txn, 'purchase_items');
      if (maps(saved['lines'])
          .any((l) => !items.any((i) => i['id'] == l['purchase_item_id']))) {
        throw ApiFailure(422, 'Purchase item was not found.');
      }
      await LocalStore.put(txn, 'purchase_events', saved);
      await queueMutation(
        txn,
        'purchase_events',
        '${saved['id']}',
        'POST',
        'purchase_events',
        saved,
      );
    });
    publishSave(['purchase_events']);
    return saved;
  }
}
