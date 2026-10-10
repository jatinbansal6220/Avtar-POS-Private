part of 'session.dart';

/// Commit local data and upload intent atomically, then notify the UI without
/// awaiting HTTP. Each save has an immutable upload key, including later edits.
extension SessionOutbox on Session {
  /// A reviewed mutation keeps its original idempotency key. Retrying it is
  /// therefore safe: the server either completes the original request or
  /// returns its original acknowledgement, never creates a duplicate bill.
  Future<void> retrySyncReview(Json mutation) async {
    final key = '${mutation['key'] ?? ''}';
    if (key.isEmpty) throw ApiFailure(422, 'This sync review has no key.');
    await local!.db.transaction((txn) async {
      final changed = await txn.update(
        'outbox',
        {'state': 'pending', 'error': null},
        where: 'key=? AND state=?',
        whereArgs: [key, 'conflict'],
      );
      if (changed == 0) {
        throw ApiFailure(409, 'This review was already handled.');
      }
      await txn.delete('meta', where: 'key=?', whereArgs: ['prepared_$key']);
    });
    await refreshOutboxCounts();
    changed();
    requestImmediateSync();
  }

  /// Discarding removes only the blocked upload instruction. The locally
  /// saved order/bill remains visible, so an owner never loses data merely by
  /// clearing an obsolete or invalid sync review.
  Future<void> discardSyncReview(Json mutation) async {
    final key = '${mutation['key'] ?? ''}';
    if (key.isEmpty) throw ApiFailure(422, 'This sync review has no key.');
    await local!.db.transaction((txn) async {
      final changed = await txn.delete(
        'outbox',
        where: 'key=? AND state=?',
        whereArgs: [key, 'conflict'],
      );
      if (changed == 0) {
        throw ApiFailure(409, 'This review was already handled.');
      }
      await txn.delete('meta', where: 'key=?', whereArgs: ['prepared_$key']);
    });
    await refreshOutboxCounts();
    changed();
  }

  Future<void> queueMutation(
    DatabaseExecutor txn,
    String resource,
    String entity,
    String method,
    String path,
    Json payload,
  ) async {
    if (demoMode) return;
    await txn.insert('outbox', {
      'key': Session.uuid.v4(),
      'entity': entity,
      'resource': resource,
      'method': method,
      'path': path,
      'payload': jsonEncode(payload),
    });
  }

  void publishSave(Iterable<String> resources) {
    dataChanged(resources);
    if (!demoMode) requestImmediateSync();
  }

  Future<void> storeOrder(DatabaseExecutor txn, Json draft) async {
    // Keep local KOT acknowledgements in the SQLite order/draft, but strip
    // every local-only field before the snapshot becomes an API mutation.
    // This makes a kitchen print acknowledgement independent of server sync
    // and guarantees the final bill payload still contains normal items only.
    final localSnapshot = clone(draft)
      ..removeWhere(
        (key, _) => key.startsWith('_') && key != '_kot_sent_quantities',
      );
    final snapshot = clone(localSnapshot)
      ..remove('_kot_sent_quantities')
      ..['items'] = maps(localSnapshot['items'])
          .map((item) => item..removeWhere((key, _) => key.startsWith('_')))
          .toList();
    // KOT sent quantities are device-local printer acknowledgements. Retain
    // them in the local record/draft across an ordinary Save Order, but never
    // send them to the API and never let them affect a final receipt.
    snapshot['status'] = 'open';
    snapshot['updated_at'] = indiaTimestamp();
    localSnapshot['status'] = snapshot['status'];
    localSnapshot['updated_at'] = snapshot['updated_at'];
    await LocalStore.put(txn, 'orders', localSnapshot);
    await txn.insert('drafts', {
      'id': draft['id'],
      'body': jsonEncode(localSnapshot),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await queueMutation(
      txn,
      'orders',
      draft['id'],
      number(draft['version']) > 0 ? 'PUT' : 'POST',
      number(draft['version']) > 0 ? 'orders/${draft['id']}' : 'orders',
      snapshot,
    );
    // A joined bill has one group, but every occupied table still owns its
    // own editable cart. Saving Table 7 must never make Table 2 open Table
    // 7's items on the next tap.
    for (final tableId in <String>{
      if (draft['table_id'] != null) '${draft['table_id']}',
    }) {
      final rows = await txn.query(
        'restaurant_tables',
        where: 'id=?',
        whereArgs: [tableId],
      );
      if (rows.isNotEmpty) {
        final table = jsonDecode(rows.first['body'] as String) as Json;
        await LocalStore.put(txn, 'tables', {
          ...table,
          'status': draft['bill_pending'] == true ? 'bill_pending' : 'occupied',
          'current_order_id': draft['id'],
        });
      }
    }
  }

  Future<void> enqueueOrder(Json draft) async {
    requireOrderAccess(draft);
    await local!.db.transaction((txn) async {
      final existing = await txn.query(
        'records',
        where: 'resource=? AND id=?',
        whereArgs: ['orders', draft['id']],
      );
      if (existing.isNotEmpty && existing.first['status'] != 'open')
        throw ApiFailure(409, 'This order has already been finalized.');
      await storeOrder(txn, draft);
    });
    publishSave(['orders', 'tables']);
  }

  /// Applies a dining-table lifecycle transition locally first, then queues the
  /// matching server command. A cancelled order stays in audit history but no
  /// longer counts as an open order or holds the table.
  Future<void> changeOrderStatus(Json order, {required String action}) async {
    requireOrderAccess(order);
    if (!['bill_pending', 'cancel'].contains(action)) {
      throw ApiFailure(422, 'Unknown order status action.');
    }
    if (action == 'cancel' && !manager) {
      throw ApiFailure(
        403,
        'Only an owner or manager can clear an occupied table.',
      );
    }
    if (order['order_type'] != 'dine_in' || order['table_id'] == null) {
      throw ApiFailure(
        422,
        'Only a dining-table order can change table status.',
      );
    }
    final orderId = '${order['id']}';
    final tableId = '${order['table_id']}';
    await local!.db.transaction((txn) async {
      final stored = await txn.query(
        'records',
        where: 'resource=? AND id=?',
        whereArgs: ['orders', orderId],
        limit: 1,
      );
      // A never-saved order cannot exist remotely. Dropping its local draft is
      // enough; its table has never been assigned to this draft.
      if (stored.isEmpty) {
        await txn.delete('drafts', where: 'id=?', whereArgs: [orderId]);
        return;
      }
      final current = jsonDecode(stored.single['body'] as String) as Json;
      if (current['status'] != 'open') {
        throw ApiFailure(409, 'This order is already closed.');
      }
      final table = await txn.query(
        'records',
        where: 'resource=? AND id=?',
        whereArgs: ['tables', tableId],
        limit: 1,
      );
      if (table.isEmpty)
        throw ApiFailure(404, 'The assigned table was not found.');
      final tableValue = jsonDecode(table.single['body'] as String) as Json;
      if (tableValue['current_order_id'] != orderId) {
        throw ApiFailure(409, 'This table is now linked to a different order.');
      }
      final cancelled = action == 'cancel';
      final tableIds = <String>{
        tableId,
        ...List<String>.from(current['merged_table_ids'] ?? []),
      };
      if (cancelled && tableIds.length > 1) {
        throw ApiFailure(
          422,
          'Separate joined tables before cancelling an order.',
        );
      }
      await LocalStore.put(txn, 'orders', {
        ...current,
        'status': cancelled ? 'cancelled' : 'open',
        if (!cancelled) 'bill_pending': true,
        'updated_at': indiaTimestamp(),
      });
      for (final affectedTableId in tableIds) {
        final affected = affectedTableId == tableId
            ? tableValue
            : await txn
                  .query(
                    'records',
                    where: 'resource=? AND id=?',
                    whereArgs: ['tables', affectedTableId],
                    limit: 1,
                  )
                  .then(
                    (rows) => rows.isEmpty
                        ? null
                        : jsonDecode(rows.single['body'] as String) as Json,
                  );
        if (affected == null) {
          throw ApiFailure(404, 'A joined table was not found.');
        }
        if ('${affected['current_order_id'] ?? ''}' != orderId) {
          throw ApiFailure(
            409,
            'A joined table is linked to a different order.',
          );
        }
        await LocalStore.put(txn, 'tables', {
          ...affected,
          'status': cancelled ? 'empty' : 'bill_pending',
          'current_order_id': cancelled ? null : orderId,
          'updated_at': indiaTimestamp(),
        });
      }
      if (cancelled) {
        await txn.delete('drafts', where: 'id=?', whereArgs: [orderId]);
      }
      await queueMutation(
        txn,
        'orders',
        orderId,
        'POST',
        'orders/$orderId/status',
        {'version': number(current['version']), 'action': action},
      );
    });
    publishSave(['orders', 'tables']);
  }

  String _tableLookupKey(String raw) {
    final text = raw.trim().toUpperCase().replaceAll(RegExp(r'\s+'), '');
    final match = RegExp(r'^(?:TABLE|T)?0*(\d+)$').firstMatch(text);
    if (match == null) return text;
    return 'N${int.parse(match.group(1)!)}';
  }

  Future<Json> _findTableByNumber(String enteredNumber) async {
    final entered = enteredNumber.trim();
    if (entered.isEmpty) {
      throw ApiFailure(422, 'Enter a table number.');
    }
    // Cashiers may write 1 or 01. Three-digit forms such as 001 are rejected
    // deliberately so a mistyped table never silently moves a live order.
    if (RegExp(r'^\d+$').hasMatch(entered) &&
        !RegExp(r'^(?:0?[1-9]|[1-9]\d)$').hasMatch(entered)) {
      throw ApiFailure(422, 'Use a table number such as 1 or 01.');
    }
    final key = _tableLookupKey(entered);
    final table = (await local!.listAll('tables'))
        .where((row) => _tableLookupKey('${row['table_number'] ?? ''}') == key)
        .firstOrNull;
    if (table == null) {
      throw ApiFailure(404, 'Table $entered does not exist.');
    }
    return table;
  }

  /// Checks the chosen occupied table before the owner confirms a join. This
  /// is read-only: the actual merge repeats every validation inside its own
  /// local transaction so a table that changes during the three-second
  /// warning can never be joined by mistake.
  Future<Json> previewDiningTableMerge(
    Json order,
    String enteredTableNumber,
  ) async {
    if (order['order_type'] != 'dine_in' || order['table_id'] == null) {
      throw ApiFailure(422, 'Only dining-table orders can be merged.');
    }
    final table = await _findTableByNumber(enteredTableNumber);
    if ('${table['id']}' == '${order['table_id']}') {
      throw ApiFailure(422, 'Choose a different table to merge.');
    }
    final targetOrderId = '${table['current_order_id'] ?? ''}';
    if (targetOrderId.isEmpty) {
      return {
        'table_number': '${table['table_number']}',
        'status': 'empty',
        'is_empty': true,
        'customer_name': '',
        'item_count': 0,
        'joined_table_numbers': <String>['${table['table_number']}'],
      };
    }
    final targetOrder = await local!.get('orders', targetOrderId);
    if (targetOrder == null || targetOrder['status'] != 'open') {
      throw ApiFailure(409, 'The selected table no longer has an open order.');
    }
    final joined = List<String>.from(
      targetOrder['merged_table_numbers'] ?? const <String>[],
    );
    return {
      'table_number': '${table['table_number']}',
      'status': '${table['status'] ?? 'occupied'}',
      'is_empty': false,
      'customer_name': '${targetOrder['customer_name'] ?? ''}'.trim(),
      'item_count': maps(targetOrder['items']).length,
      'joined_table_numbers': joined.isEmpty
          ? <String>['${table['table_number']}']
          : joined,
    };
  }

  Future<void> _putOpenOrder(DatabaseExecutor txn, Json order) async {
    final snapshot = clone(order)..removeWhere((key, _) => key.startsWith('_'));
    snapshot['status'] = 'open';
    snapshot['updated_at'] = indiaTimestamp();
    await LocalStore.put(txn, 'orders', snapshot);
    await txn.insert('drafts', {
      'id': snapshot['id'],
      'body': jsonEncode(snapshot),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// A joined family uses one cart across all of its table cards. Same catalog
  /// lines are combined by quantity so merging Table 1 and Table 7 never
  /// produces duplicate dishes on the combined receipt.
  List<Json> _combineSharedCartItems(Iterable<Json> orders) {
    final itemsByKey = <String, Json>{};
    for (final order in orders) {
      for (final source in maps(order['items'])) {
        final item = clone(source);
        final key = [
          item['menu_item_id'] ?? '',
          item['combo_id'] ?? '',
          item['price_minor'] ?? 0,
          item['notes'] ?? '',
          item['discount_type'] ?? 'percent',
          item['discount_value'] ?? 0,
        ].join('|');
        final existing = itemsByKey[key];
        if (existing == null) {
          itemsByKey[key] = item;
        } else {
          if (existing.containsKey('_kot_printed_quantity') &&
              item.containsKey('_kot_printed_quantity')) {
            existing['_kot_printed_quantity'] =
                number(existing['_kot_printed_quantity']) +
                number(item['_kot_printed_quantity']);
          }
          existing['quantity'] =
              number(existing['quantity']) + number(item['quantity']);
        }
      }
    }
    return itemsByKey.values.toList();
  }

  /// Moves a saved dining order without re-entering any items. The table card
  /// changes locally inside the same transaction as the order, then the
  /// server action is queued for immediate delivery.
  Future<Json> transferDiningOrder(
    Json order,
    String enteredTableNumber,
  ) async {
    requireFeature('table_transfer');
    requireOrderAccess(order);
    // Table changes must move the latest locally saved cart, not an older
    // workspace snapshot. This matters when Save Order and Change Table are
    // pressed close together: the destination receives every saved line and
    // the source card is cleared in the same transaction.
    order =
        await local!.readDraft('${order['id']}') ??
        await local!.get('orders', '${order['id']}') ??
        order;
    if (order['order_type'] != 'dine_in' || order['table_id'] == null) {
      throw ApiFailure(422, 'Only a dining-table order can change tables.');
    }
    if (maps(order['items']).isEmpty) {
      throw ApiFailure(422, 'Add an item before changing the table.');
    }
    if (List<String>.from(order['merged_table_ids'] ?? []).length > 1) {
      throw ApiFailure(
        422,
        'Separate the merged tables before moving this order to another table.',
      );
    }
    final destination = await _findTableByNumber(enteredTableNumber);
    final sourceId = '${order['table_id']}';
    final destinationId = '${destination['id']}';
    if (sourceId == destinationId) {
      throw ApiFailure(422, 'This order is already on this table.');
    }
    if ('${destination['current_order_id'] ?? ''}'.isNotEmpty ||
        '${destination['status'] ?? 'empty'}' != 'empty') {
      throw ApiFailure(
        409,
        'Table ${destination['table_number']} already has an active order.',
      );
    }
    final moved = <String, dynamic>{
      ...clone(order),
      'table_id': destinationId,
      'table_number': destination['table_number'],
      'bill_pending': false,
    };
    await local!.db.transaction((txn) async {
      final source = await txn.query(
        'restaurant_tables',
        where: 'id=?',
        whereArgs: [sourceId],
        limit: 1,
      );
      if (source.isEmpty)
        throw ApiFailure(404, 'The current table was not found.');
      final target = await txn.query(
        'restaurant_tables',
        where: 'id=?',
        whereArgs: [destinationId],
        limit: 1,
      );
      if (target.isEmpty)
        throw ApiFailure(404, 'The destination table was not found.');
      final targetValue = jsonDecode(target.single['body'] as String) as Json;
      if ('${targetValue['current_order_id'] ?? ''}'.isNotEmpty ||
          '${targetValue['status'] ?? 'empty'}' != 'empty') {
        throw ApiFailure(409, 'The destination table is no longer empty.');
      }
      await _putOpenOrder(txn, moved);
      await LocalStore.put(txn, 'tables', {
        ...jsonDecode(source.single['body'] as String) as Json,
        'status': 'empty',
        'current_order_id': null,
        'updated_at': indiaTimestamp(),
      });
      await LocalStore.put(txn, 'tables', {
        ...targetValue,
        'status': 'occupied',
        'current_order_id': moved['id'],
        'updated_at': indiaTimestamp(),
      });
      await queueMutation(
        txn,
        'orders',
        '${moved['id']}',
        'POST',
        'orders/${moved['id']}/transfer',
        {'version': number(order['version']), 'target_table_id': destinationId},
      );
    });
    publishSave(['orders', 'tables']);
    return moved;
  }

  /// Joins tables into one shared cart. Any table card in the group opens the
  /// same order, and each item is stored once for one combined final bill.
  Future<Json> mergeDiningTables(Json order, String enteredTableNumber) async {
    requireFeature('table_merge');
    requireOrderAccess(order);
    // The workspace keeps the newest cart in drafts until (and after) Save
    // Order. Resolve it here so a merge can never overwrite recent lines with
    // an older in-memory/table-card snapshot.
    order =
        await local!.readDraft('${order['id']}') ??
        await local!.get('orders', '${order['id']}') ??
        order;
    if (order['order_type'] != 'dine_in' || order['table_id'] == null) {
      throw ApiFailure(422, 'Only dining-table orders can be merged.');
    }
    if (maps(order['items']).isEmpty) {
      throw ApiFailure(422, 'Add an item before merging this table.');
    }
    final destination = await _findTableByNumber(enteredTableNumber);
    final sourceId = '${order['table_id']}';
    final destinationId = '${destination['id']}';
    if (sourceId == destinationId) {
      throw ApiFailure(422, 'Choose a different table to merge.');
    }
    final targetOrderId = '${destination['current_order_id'] ?? ''}';
    // A family can occupy a second, previously empty table. It is still a
    // joined table group, but it contributes no child order/items.
    final targetOrder = targetOrderId.isEmpty
        ? null
        : await local!.readDraft(targetOrderId) ??
              await local!.get('orders', targetOrderId);
    if (targetOrderId.isNotEmpty &&
        (targetOrder == null || targetOrder['status'] != 'open')) {
      throw ApiFailure(409, 'The selected table no longer has an open order.');
    }
    final sourceOrderIds = <String>{
      '${order['id']}',
      ...List<String>.from(order['merged_order_ids'] ?? []),
    };
    final targetOrderIds = targetOrder == null
        ? <String>{}
        : <String>{
            '${targetOrder['id']}',
            ...List<String>.from(targetOrder['merged_order_ids'] ?? []),
          };
    if (sourceOrderIds.intersection(targetOrderIds).isNotEmpty) {
      throw ApiFailure(422, 'These tables are already joined.');
    }
    final sourceTables = <String>{
      sourceId,
      ...List<String>.from(order['merged_table_ids'] ?? []),
    };
    final targetTables = <String>{
      destinationId,
      if (targetOrder != null)
        ...List<String>.from(targetOrder['merged_table_ids'] ?? []),
    };
    final allTableIds = <String>{...sourceTables, ...targetTables}.toList();
    final tableRows = <String, Json>{
      for (final table in await local!.listAll('tables'))
        '${table['id']}': table,
    };
    if (allTableIds.any((id) => tableRows[id] == null)) {
      throw ApiFailure(
        409,
        'One of the tables could not be found. Refresh and try again.',
      );
    }
    final allOrderIds = <String>{...sourceOrderIds, ...targetOrderIds};
    final latestMembers = <String, Json>{};
    for (final orderId in allOrderIds) {
      final snapshot = orderId == '${order['id']}'
          ? order
          : await local!.readDraft(orderId) ??
                await local!.get('orders', orderId);
      if (snapshot != null) latestMembers[orderId] = snapshot;
    }
    // Keep the exact pre-join state with the queued command. If the server
    // later rejects it because another terminal changed a table first, sync
    // can safely restore both table cards and their original orders instead
    // of leaving a misleading local merged state.
    final rollbackOrders = <Json>[];
    for (final orderId in allOrderIds) {
      final snapshot = latestMembers[orderId];
      if (snapshot != null) rollbackOrders.add(clone(snapshot));
    }
    final merged = <String, dynamic>{
      ...clone(order),
      'items': _combineSharedCartItems(latestMembers.values),
      'merged_table_ids': allTableIds,
      'merged_table_numbers': [
        for (final id in allTableIds) '${tableRows[id]!['table_number']}',
      ],
      'merged_order_ids': allOrderIds.toList(),
      'bill_pending': false,
    };
    await local!.db.transaction((txn) async {
      await _putOpenOrder(txn, merged);
      for (final childId in allOrderIds) {
        final stored = await txn.query(
          'records',
          where: 'resource=? AND id=?',
          whereArgs: ['orders', childId],
          limit: 1,
        );
        if (stored.isEmpty) continue;
        final child = jsonDecode(stored.single['body'] as String) as Json;
        if (childId == '${merged['id']}') continue;
        await _putOpenOrder(txn, {
          ...child,
          // Child rows only retain their table membership. Their old lines
          // moved to the primary shared cart above, so opening either table
          // can never duplicate a dish in the final bill.
          'items': <Json>[],
          'merged_table_ids': allTableIds,
          'merged_table_numbers': merged['merged_table_numbers'],
          'merged_order_ids': merged['merged_order_ids'],
          'merged_into_order_id': merged['id'],
        });
      }
      for (final tableId in allTableIds) {
        await LocalStore.put(txn, 'tables', {
          ...tableRows[tableId]!,
          'status': 'occupied',
          'current_order_id': merged['id'],
          'updated_at': indiaTimestamp(),
        });
      }
      await queueMutation(
        txn,
        'orders',
        '${merged['id']}',
        'POST',
        'orders/${merged['id']}/merge',
        {
          'version': number(order['version']),
          'target_table_id': destinationId,
          '_local_rollback': {
            'orders': rollbackOrders,
            'tables': [
              for (final tableId in allTableIds) clone(tableRows[tableId]!),
            ],
          },
        },
      );
    });
    publishSave(['orders', 'tables']);
    return merged;
  }

  /// Reverts only an unaccepted local table join. The server performs its
  /// merge transaction atomically, so a non-2xx merge response means none of
  /// the remote table changes were applied. This is deliberately not used for
  /// transport failures: those remain pending and retry safely.
  Future<bool> rollbackRejectedDiningMerge(Json payload) async {
    final raw = payload['_local_rollback'];
    if (raw is! Map) return false;
    final rollback = Map<String, dynamic>.from(raw);
    final orders = maps(rollback['orders']);
    final tables = maps(rollback['tables']);
    if (orders.isEmpty || tables.isEmpty) return false;
    await local!.db.transaction((txn) async {
      for (final order in orders) {
        await LocalStore.put(txn, 'orders', order);
        if (order['status'] == 'open') {
          await txn.insert('drafts', {
            'id': order['id'],
            'body': jsonEncode(order),
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
      for (final table in tables) {
        await LocalStore.put(txn, 'tables', table);
      }
    });
    return true;
  }

  /// Restores a joined group to its original table orders before separate
  /// settlement. The owner can then bill each table normally.
  Future<void> separateDiningTables(Json order) async {
    requireFeature('table_separate');
    requireOrderAccess(order);
    final tableIds = List<String>.from(order['merged_table_ids'] ?? []);
    final orderIds = List<String>.from(order['merged_order_ids'] ?? []);
    if (tableIds.length < 2 || orderIds.length < 2) return;
    final tables = <String, Json>{
      for (final table in await local!.listAll('tables'))
        '${table['id']}': table,
    };
    await local!.db.transaction((txn) async {
      for (final orderId in orderIds) {
        final stored = await txn.query(
          'records',
          where: 'resource=? AND id=?',
          whereArgs: ['orders', orderId],
          limit: 1,
        );
        if (stored.isEmpty) continue;
        final current = jsonDecode(stored.single['body'] as String) as Json;
        await _putOpenOrder(txn, {
          ...current,
          'merged_table_ids': <String>[],
          'merged_table_numbers': <String>[],
          'merged_order_ids': <String>[],
          'merged_into_order_id': null,
        });
        final tableId = '${current['table_id'] ?? ''}';
        final table = tables[tableId];
        if (table != null) {
          await LocalStore.put(txn, 'tables', {
            ...table,
            'status': 'occupied',
            'current_order_id': orderId,
            'updated_at': indiaTimestamp(),
          });
        }
      }
      await queueMutation(
        txn,
        'orders',
        '${order['id']}',
        'POST',
        'orders/${order['id']}/unmerge',
        {'version': number(order['version'])},
      );
    });
    publishSave(['orders', 'tables']);
  }

  Future<Json> mutate(
    String resource,
    Json value, {
    bool delete = false,
    String? path,
  }) async {
    final feature = resourceFeature(resource);
    if (feature != null) requireFeature(feature);
    final localValue = clone(value);
    // Generate compatible account artwork in the same local save as its UPI
    // ID. Checkout remains read-only, and the existing API receives a PNG.
    if (!delete &&
        resource == 'banks' &&
        ['upi', 'upi_merchant'].contains(localValue['account_type']) &&
        validUpiId(localValue['account_number'])) {
      localValue['qr_image_base64'] = upiQrPng(
        upiPaymentUri(
          upiId: '${localValue['account_number']}',
          name: '${localValue['account_name'] ?? 'Merchant'}',
        ),
      );
    }
    if (resource == 'settings' && localValue['id'] == null) {
      final current = (await local!.list('settings', limit: 1)).firstOrNull;
      if (current != null) localValue.addAll({...current, ...value});
    }
    final isNew = localValue['id'] == null;
    final id = '${localValue['id'] ?? Session.uuid.v4()}';
    localValue['id'] = id;
    if (resource == 'tables') localValue['status'] ??= 'empty';
    if (isNew) localValue['created_at'] ??= indiaTimestamp();
    localValue['updated_at'] = indiaTimestamp();
    final method = delete
        ? 'DELETE'
        : isNew
        ? 'POST'
        : 'PUT';
    await local!.db.transaction((txn) async {
      // Match the API's unique employee/day and employee/month rules locally.
      // Checking inside the transaction also protects rapid duplicate saves.
      if (!delete &&
          ['attendance', 'staff_salary_adjustments'].contains(resource)) {
        final period = resource == 'attendance' ? 'date' : 'month_start';
        final duplicate = await txn.rawQuery(
          "SELECT id FROM records WHERE resource=? AND json_extract(body, '\$.staff_id')=? AND json_extract(body, '\$.$period')=? AND id<>? LIMIT 1",
          [resource, localValue['staff_id'], localValue[period], id],
        );
        if (duplicate.isNotEmpty) {
          throw ApiFailure(
            422,
            resource == 'attendance'
                ? 'Attendance is already marked for this staff member and date. Edit the existing entry.'
                : 'This staff month already has a confirmed salary cut.',
          );
        }
      }
      if (delete) {
        await txn.delete(
          'records',
          where: 'resource=? AND id=?',
          whereArgs: [resource, id],
        );
        if (resource == 'tables')
          await txn.delete('restaurant_tables', where: 'id=?', whereArgs: [id]);
      } else {
        await LocalStore.put(txn, resource, localValue);
      }
      await queueMutation(
        txn,
        resource,
        id,
        method,
        path ?? (isNew ? resource : '$resource/$id'),
        localValue,
      );
    });
    publishSave([resource]);
    return localValue;
  }

  String _invoiceDeleteCodeHash(String code) =>
      sha256.convert(utf8.encode(code.trim())).toString();

  void _validateInvoiceDeleteCode(String code) {
    if (!RegExp(r'^\d{4,8}$').hasMatch(code.trim())) {
      throw ApiFailure(422, 'Enter a 4 to 8 digit invoice deletion code.');
    }
  }

  /// The same owner code protects destructive invoice deletion and every
  /// settlement edit. Only its SHA-256 proof is placed in a queued mutation;
  /// the raw code never reaches SQLite or the server.
  Future<String> verifyInvoiceAccessCode(String code) async {
    _validateInvoiceDeleteCode(code);
    final settings =
        (await local!.list('settings', limit: 1)).firstOrNull ??
        <String, dynamic>{};
    final configuredHash = '${settings['invoice_delete_code_hash'] ?? ''}';
    final proof = _invoiceDeleteCodeHash(code);
    if (configuredHash.isEmpty) {
      throw ApiFailure(
        422,
        'Owner access code is not set. Open Invoices and tap the code icon to set it for Analytics, Day Closing and invoice changes.',
      );
    }
    if (configuredHash != proof) {
      throw ApiFailure(403, 'Invoice deletion/edit code is incorrect.');
    }
    return proof;
  }

  /// Removes a finalized invoice from the visible history locally first, then
  /// queues the server-side soft delete. The code itself is never stored in
  /// SQLite/outbox: only its SHA-256 verification value is transmitted.
  Future<void> deleteInvoice(Json bill, String code) async {
    requireFeature('invoice_delete');
    requireFeature('invoices');
    final proof = await verifyInvoiceAccessCode(code);
    // Invoice history is an owner-facing local view. Once the protected
    // delete is confirmed, remove it immediately even if its original bill
    // upload is still queued. The POST and following DELETE stay ordered in
    // the outbox, so a later connection still reconciles the server safely.
    await mutate('bills', {...bill, 'delete_code_hash': proof}, delete: true);
  }

  /// A reset is deliberately online-only so every terminal receives the same
  /// new cached verification value through the normal settings sync.
  Future<void> setInvoiceDeleteCode({
    required String newCode,
    String currentCode = '',
  }) async {
    _validateInvoiceDeleteCode(newCode);
    final settings =
        (await local!.list('settings', limit: 1)).firstOrNull ??
        <String, dynamic>{};
    final configuredHash = '${settings['invoice_delete_code_hash'] ?? ''}';
    if (configuredHash.isNotEmpty) {
      _validateInvoiceDeleteCode(currentCode);
      if (_invoiceDeleteCodeHash(currentCode) != configuredHash) {
        throw ApiFailure(403, 'Current invoice deletion code is incorrect.');
      }
    }
    final result = demoMode
        ? <String, dynamic>{
            ...settings,
            'invoice_delete_code_hash': _invoiceDeleteCodeHash(newCode),
          }
        : await request(
            'POST',
            'bills/delete-code',
            body: {
              'current_code_hash': configuredHash.isEmpty
                  ? null
                  : _invoiceDeleteCodeHash(currentCode),
              'new_code_hash': _invoiceDeleteCodeHash(newCode),
            },
            key: Session.uuid.v4(),
          );
    await local!.db.transaction(
      (txn) => LocalStore.put(txn, 'settings', result),
    );
    publishSave(['settings']);
  }

  Future<Json> enqueueBill(
    Json order,
    Json payment, {
    Json? sourceOrder,
  }) async {
    requireFeature('invoices');
    requireOrderAccess(order);
    validateControlledPayment(payment);
    final settings =
        (await local!.list('settings', limit: 1)).firstOrNull ??
        <String, dynamic>{};
    final taxRate = effectiveTaxRate(settings);
    final bankId = payment['bank_account_id']?.toString();
    final bank = bankId == null || bankId.isEmpty
        ? null
        : await local!.get('banks', bankId);
    final qrBankId = payment['qr_bank_account_id']?.toString();
    final qrBank = qrBankId == null || qrBankId.isEmpty
        ? null
        : await local!.get('banks', qrBankId);
    if (bankId != null && bankId.isNotEmpty) {
      if (bank == null || !enabled(bank['is_active'])) {
        throw ApiFailure(422, 'Select an active bank account.');
      }
    }
    if (qrBankId != null && qrBankId.isNotEmpty) {
      if (qrBank == null ||
          !enabled(qrBank['is_active']) ||
          '${qrBank['qr_image_base64'] ?? ''}'.trim().isEmpty) {
        throw ApiFailure(
          422,
          'Select an active account with an uploaded bill QR image.',
        );
      }
    }
    final paymentMethod = payment['payment_method']?.toString() ?? 'cash';
    final paymentRows = maps(payment['payments']);
    final hasCardTender =
        ['card', 'online'].contains(paymentMethod) ||
        (paymentMethod == 'mixed' &&
            paymentRows.any(
              (row) =>
                  ['card', 'online'].contains(row['method']) &&
                  number(row['amount_minor']) > 0,
            ));
    final hasUpiTender =
        paymentMethod == 'upi' ||
        (paymentMethod == 'mixed' &&
            paymentRows.any(
              (row) =>
                  row['method'] == 'upi' && number(row['amount_minor']) > 0,
            ));
    if (hasCardTender && bank == null) {
      throw ApiFailure(
        422,
        'Select an active Card settlement account before saving this payment.',
      );
    }
    if (hasUpiTender && qrBank == null) {
      throw ApiFailure(
        422,
        'Select an active UPI account with an uploaded bill QR before saving this payment.',
      );
    }
    final summary = BillingCalculator.calculate(
      maps(order['items']),
      payment,
      taxRate,
    );
    if (maps(order['items']).isEmpty)
      throw ApiFailure(422, 'Add an item before billing.');
    final tenders = BillingCalculator.payments(
      payment,
      number(summary['total_minor']),
    );
    final parts = List<int>.from(payment['split_amounts'] ?? []);
    if (parts.isNotEmpty &&
        (parts.any((v) => v <= 0) ||
            parts.fold<int>(0, (a, b) => a + b) != summary['total_minor']))
      throw ApiFailure(422, 'Bill parts must equal the total.');
    final billId = Session.uuid.v4();
    final generatedAt = indiaNow();
    final billDay = day(generatedAt);
    final sequenceKey = 'bill_sequence_$billDay';
    var dailySequence = 0;
    await local!.db.transaction((txn) async {
      final rows = await txn.query(
        'meta',
        where: 'key=?',
        whereArgs: [sequenceKey],
      );
      dailySequence = number(rows.firstOrNull?['value']) + 1;
      await txn.insert('meta', {
        'key': sequenceKey,
        'value': '$dailySequence',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
    final billNumber =
        'BILL-${billDay.replaceAll('-', '')}-${dailySequence.toString().padLeft(3, '0')}';
    final sourceTerminalId = await terminalId();
    final sourceTerminalLabel = terminalLabel;
    final mergedTableNumbers = List<String>.from(
      order['merged_table_numbers'] ?? const <String>[],
    );
    final receipt = <String, dynamic>{
      'restaurant': settings,
      'bill_number': billNumber,
      'source_terminal_id': sourceTerminalId,
      'source_terminal_label': sourceTerminalLabel,
      'table_number': mergedTableNumbers.length > 1
          ? mergedTableNumbers.join(' + ')
          : order['table_number'],
      'order_type': order['order_type'],
      'online_platform': order['online_platform'],
      'online_platform_name': order['online_platform_name'],
      'customer_name': order['customer_name'],
      'customer_phone': order['customer_phone'],
      'merged_table_numbers': mergedTableNumbers,
      'items': maps(order['items']),
      'table_sections': maps(order['table_sections']),
      'voids': maps(order['voids']),
      ...summary,
      'tax_basis_points': taxRate,
      'discount_basis_points': payment['discount_basis_points'] ?? 0,
      'discount_type': payment['discount_type'],
      'discount_display_type': payment['discount_display_type'],
      'discount_value': payment['discount_value'],
      'additional_charges': maps(payment['additional_charges']),
      'payment_method': tenders.length > 1 ? 'mixed' : tenders.first['method'],
      'bank_account_id': bankId,
      'bank_account_name': bank?['account_name'],
      'qr_bank_account_id': qrBankId,
      'qr_bank_account_name': qrBank?['account_name'],
      'qr_upi_id': qrBank?['account_number'],
      'qr_image_base64': qrBank?['qr_image_base64'],
      'payments': tenders,
      'split_amounts': parts,
      'cashier_name': user?['name'] ?? 'Owner',
      'generated_at': indiaTimestamp(generatedAt),
    };
    final bill = <String, dynamic>{
      ...receipt,
      'id': billId,
      'order_id': order['id'],
      'table_id': order['table_id'],
      'receipt': receipt,
    };
    await local!.db.transaction((txn) async {
      final existing = await txn.query(
        'meta',
        where: 'key=?',
        whereArgs: ['bill_${order['id']}'],
      );
      if (existing.isNotEmpty)
        throw ApiFailure(409, 'This order already has a final bill.');
      // For a joined bill, `order.items` is the combined receipt view while
      // `sourceOrder` is the primary table's real editable order. Never write
      // the combined view back over that source order; the separate-bill path
      // must retain every original table order intact.
      await storeOrder(txn, sourceOrder ?? order);
      await LocalStore.put(txn, 'bills', bill);
      final groupedOrderIds = <String>{
        '${order['id']}',
        ...List<String>.from(order['merged_order_ids'] ?? []),
      };
      for (final orderId in groupedOrderIds) {
        final rows = await txn.query(
          'records',
          where: 'resource=? AND id=?',
          whereArgs: ['orders', orderId],
          limit: 1,
        );
        if (rows.isNotEmpty) {
          await LocalStore.put(txn, 'orders', {
            ...jsonDecode(rows.single['body'] as String) as Json,
            'status': 'billed',
            'updated_at': indiaTimestamp(),
          });
        }
        await txn.delete('drafts', where: 'id=?', whereArgs: [orderId]);
      }
      for (final tableId in <String>{
        if (order['table_id'] != null) '${order['table_id']}',
        ...List<String>.from(order['merged_table_ids'] ?? []),
      }) {
        final rows = await txn.query(
          'restaurant_tables',
          where: 'id=?',
          whereArgs: [tableId],
        );
        if (rows.isNotEmpty)
          await LocalStore.put(txn, 'tables', {
            ...jsonDecode(rows.first['body'] as String) as Json,
            'status': 'empty',
            'current_order_id': null,
          });
      }
      await txn.insert('meta', {
        'key': 'bill_${order['id']}',
        'value': billId,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await queueMutation(txn, 'bills', order['id'], 'POST', 'bills/generate', {
        'id': billId,
        'order_id': order['id'],
        'version': order['version'],
        // New receipts deliberately declare that their Card/UPI accounts were
        // selected in the current checkout flow. The server uses this only to
        // keep new sales strict; pre-existing offline receipts without this
        // field must remain uploadable after an app/server upgrade.
        'payment_schema_version': 2,
        'client_bill_number': billNumber,
        'client_generated_at': indiaTimestamp(generatedAt),
        'source_terminal_id': sourceTerminalId,
        'source_terminal_label': sourceTerminalLabel,
        ...payment,
        'payments': tenders,
        'split_amounts': parts,
      });
    });
    publishSave(['bills', 'orders', 'tables']);
    return bill;
  }

  /// Changes only how a finalized invoice is settled. Its ordered items,
  /// original bill number and table history remain immutable. The receipt
  /// carries an append-only settlement audit so every terminal can show who
  /// edited it, when, and why.
  Future<Json> updateBillSettlement(
    Json bill,
    Json payment, {
    required String invoiceAccessCodeHash,
  }) async {
    requireFeature('invoices');
    validateControlledPayment(payment);
    final remark = '${payment['settlement_remark'] ?? ''}'.trim();
    if (remark.isEmpty) {
      throw ApiFailure(
        422,
        'Enter a settlement remark before saving the edit.',
      );
    }
    final settings =
        (await local!.list('settings', limit: 1)).firstOrNull ??
        <String, dynamic>{};
    final receipt = bill['receipt'] is Map
        ? Map<String, dynamic>.from(bill['receipt'] as Map)
        : <String, dynamic>{};
    final items = maps(receipt['items'] ?? bill['items']);
    if (items.isEmpty)
      throw ApiFailure(422, 'This invoice has no items to settle.');
    final summary = BillingCalculator.calculate(
      items,
      payment,
      effectiveTaxRate(settings),
    );
    final total = number(summary['total_minor']);
    final tenders = BillingCalculator.payments(payment, total);
    final parts = List<int>.from(payment['split_amounts'] ?? const <int>[]);
    if (parts.isNotEmpty &&
        (parts.any((value) => value <= 0) ||
            parts.fold<int>(0, (sum, value) => sum + value) != total)) {
      throw ApiFailure(422, 'Bill parts must equal the total.');
    }
    final bankId = payment['bank_account_id']?.toString();
    final qrBankId = payment['qr_bank_account_id']?.toString();
    final bank = bankId == null || bankId.isEmpty
        ? null
        : await local!.get('banks', bankId);
    final qrBank = qrBankId == null || qrBankId.isEmpty
        ? null
        : await local!.get('banks', qrBankId);
    final now = indiaTimestamp();
    final previousAudit = maps(receipt['settlement_edits']);
    final revisedReceipt = <String, dynamic>{
      ...receipt,
      ...summary,
      'items': items,
      'tax_basis_points': effectiveTaxRate(settings),
      'discount_basis_points': payment['discount_basis_points'] ?? 0,
      'discount_type': payment['discount_type'],
      'discount_display_type': payment['discount_display_type'],
      'discount_value': payment['discount_value'],
      'additional_charges': maps(payment['additional_charges']),
      'payment_method': tenders.length > 1 ? 'mixed' : tenders.first['method'],
      'payments': tenders,
      'split_amounts': parts,
      'settlement_remark': remark,
      'bank_account_id': bankId,
      'bank_account_name': bank?['account_name'],
      'qr_bank_account_id': qrBankId,
      'qr_bank_account_name': qrBank?['account_name'],
      'qr_upi_id': qrBank?['account_number'],
      'qr_image_base64': qrBank?['qr_image_base64'],
      'last_settlement_edited_at': now,
      'last_settlement_edited_by': user?['name'] ?? 'Owner',
      'settlement_edits': [
        ...previousAudit,
        {
          'edited_at': now,
          'edited_by': user?['name'] ?? 'Owner',
          'remark': remark,
          'previous_total_minor': number(
            receipt['total_minor'] ?? bill['total_minor'],
          ),
          'new_total_minor': total,
          'previous_payment_method':
              receipt['payment_method'] ?? bill['payment_method'],
          'payment_method': tenders.length > 1
              ? 'mixed'
              : tenders.first['method'],
          'discount_display_type': payment['discount_display_type'],
          'discount_value': payment['discount_value'],
        },
      ],
    };
    final revisedBill = <String, dynamic>{
      ...bill,
      ...summary,
      'payment_method': revisedReceipt['payment_method'],
      'receipt': revisedReceipt,
      'updated_at': now,
    };
    await local!.db.transaction((txn) async {
      await LocalStore.put(txn, 'bills', revisedBill);
      await queueMutation(
        txn,
        'bills',
        '${bill['id']}',
        'POST',
        'bills/${bill['id']}/settlement',
        {
          'version': number(bill['version']),
          'invoice_access_code_hash': invoiceAccessCodeHash,
          'payment_schema_version': 2,
          ...payment,
          'payments': tenders,
          'split_amounts': parts,
        },
      );
    });
    publishSave(['bills']);
    return revisedBill;
  }
}
