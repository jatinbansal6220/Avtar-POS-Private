part of 'session.dart';

/// A single background worker serializes uploads. Payload/version are frozen
/// before first transmission so timeout retries retain the same idempotency key.
/// Pending local edits always win over older acknowledgments and incoming deltas.
extension SessionSync on Session {
  Future<void> bootstrap() async => local!.setMeta('cursor', '0');

  /// Loads invoice history in small pages only when the Invoice screen asks
  /// for it. This keeps normal POS screens isolated while allowing a new
  /// device to browse older server bills without downloading every record.
  Future<bool?> hydrateBillsHistoryPage() async {
    if (demoMode || local == null || expired) return false;
    final cursor = await local!.meta('bills_history_cursor');
    if (cursor == 'complete') return false;
    try {
      final params = <String, String>{'limit': '50'};
      if (cursor != null && cursor.isNotEmpty) params['cursor'] = cursor;
      final data = await request(
        'GET',
        'bills?${Uri(queryParameters: params).query}',
      );
      // A proxy/default web site can return a 200 JSON response which is not
      // the AvtarPOS bills contract. Never treat that as an empty invoice
      // page: doing so would incorrectly mark history as complete and hide
      // old server receipts until the local database was manually cleared.
      if (data['data'] is! List) {
        throw ApiFailure(
          502,
          'Invoice history received an invalid server response. It will retry automatically.',
        );
      }
      final bills = maps(data['data']);
      final next = data['next_cursor']?.toString();
      await local!.db.transaction((txn) async {
        for (final bill in bills) {
          // A local bill awaiting its server acknowledgement has a different
          // temporary id. It is deliberately retained until the outbox maps it
          // to the authoritative server bill.
          await LocalStore.put(txn, 'bills', bill);
        }
        await txn.insert('meta', {
          'key': 'bills_history_cursor',
          'value': next == null || next.isEmpty ? 'complete' : next,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      });
      online = true;
      syncError = null;
      if (bills.isNotEmpty) dataChanged(['bills']);
      return next != null && next.isNotEmpty;
    } on ApiFailure catch (error) {
      // An API response still means the terminal is online. The sync page can
      // show the precise error without labelling all POS work as offline.
      online = true;
      syncError = error.message;
      return null;
    } catch (_) {
      // Keep the existing local receipts usable and retry this page only when
      // the cashier scrolls again or reopens Invoice history.
      return null;
    }
  }

  Future<void> _repairLegacyBillMutations() async {
    final rows = await local!.db.query(
      'outbox',
      where: "resource='bills' AND state IN ('pending','conflict')",
    );
    for (final row in rows) {
      final payload = jsonDecode(row['payload'] as String) as Json;
      var repaired = false;
      if (payload['discount_type'] == 'minus') {
        payload['discount_type'] = 'fixed';
        payload['discount_basis_points'] = 0;
        repaired = true;
      }
      // Version-1 receipts existed before QR/Card settlement accounts were
      // added. They were valid at the time of sale, but a later stricter API
      // returned 422 and left them as permanent conflicts. The current API
      // accepts those legacy payloads, so safely place only that known class
      // of conflict back in the queue. Never auto-retry an arbitrary error.
      final error = '${row['error'] ?? ''}';
      final legacyPayment = payload['payment_schema_version'] == null;
      final accountRuleRejected =
          error.contains('settlement account') ||
          error.contains('UPI account') ||
          error.contains('UPI QR') ||
          error.contains('Use for Card');
      if (row['state'] == 'conflict' && legacyPayment && accountRuleRejected) {
        repaired = true;
      }
      if (!repaired) continue;
      await local!.db.update(
        'outbox',
        {'payload': jsonEncode(payload), 'state': 'pending', 'error': null},
        where: 'key=?',
        whereArgs: [row['key']],
      );
      await local!.db.delete(
        'meta',
        where: 'key=?',
        whereArgs: ['prepared_${row['key']}'],
      );
    }
  }

  /// A second terminal may settle a dining order while this terminal still
  /// has its own local receipt queued. When the server returns 409, look up
  /// the authoritative bill by immutable order id and replace only the local
  /// duplicate. Invalid payments or ordinary version conflicts still remain
  /// visible for owner review.
  Future<bool> _reconcileExistingBill(String orderId) async {
    try {
      final data = await request('GET', 'bills?order_id=$orderId&limit=1');
      if (data['data'] is! List) return false;
      final serverBill = maps(data['data']).firstOrNull;
      if (serverBill == null ||
          '${serverBill['order_id'] ?? ''}' != orderId ||
          serverBill['receipt'] is! Map) {
        return false;
      }
      Json? serverOrder;
      try {
        serverOrder = await request('GET', 'orders/$orderId');
      } catch (_) {
        // The bill is still safe to reconcile; table/order deltas will arrive
        // through the normal updates feed on the next pass.
      }
      await local!.db.transaction((txn) async {
        final refs = await txn.query(
          'meta',
          where: 'key=?',
          whereArgs: ['bill_$orderId'],
        );
        final localBillId = refs.firstOrNull?['value'];
        await LocalStore.put(txn, 'bills', serverBill);
        if (localBillId != null && localBillId != serverBill['id']) {
          await txn.delete(
            'records',
            where: 'resource=? AND id=?',
            whereArgs: ['bills', localBillId],
          );
        }
        if (serverOrder != null) {
          await LocalStore.put(txn, 'orders', serverOrder);
        }
        await txn.insert('meta', {
          'key': 'bill_$orderId',
          'value': '${serverBill['id']}',
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Final checkout queues the last order snapshot immediately before its
  /// bill. If another terminal won the race, that earlier order PUT receives
  /// "finalized" first and would otherwise block the later bill mutation.
  /// Once the authoritative bill is found, both intents for that one order
  /// are obsolete and can be removed together.
  Future<bool> _reconcileFinalizedOrder(String orderId) async {
    final billRows = await local!.db.query(
      'outbox',
      where: "entity=? AND resource='bills' AND state='pending'",
      whereArgs: [orderId],
      limit: 1,
    );
    if (billRows.isEmpty || !await _reconcileExistingBill(orderId)) {
      return false;
    }
    final obsolete = await local!.db.query(
      'outbox',
      where: "entity=? AND resource IN ('orders','bills')",
      whereArgs: [orderId],
    );
    await local!.db.transaction((txn) async {
      for (final mutation in obsolete) {
        await txn.delete(
          'outbox',
          where: 'key=?',
          whereArgs: [mutation['key']],
        );
        await txn.delete(
          'meta',
          where: 'key=?',
          whereArgs: ['prepared_${mutation['key']}'],
        );
      }
    });
    return true;
  }

  Future<void> sync() async {
    if (accountLoginRequired) return;
    if (!policyAllows('sync')) return;
    if (demoMode || local == null || expired || installingUpdate) return;
    if (syncing) return;
    final wasOnline = online;
    final previousQueued = queued;
    final previousConflicts = conflicts;
    final previousExpired = expired;
    final previousError = syncError;
    syncing = true;
    final touched = <String>{};
    var uploadedThisRun = false;
    var failed = false;
    try {
      if (await local!.meta('cursor') == null) await bootstrap();
      await _repairLegacyBillMutations();
      for (var batch = 0; batch < 100; batch++) {
        final pending = await local!.db.query(
          'outbox',
          where: "state='pending'",
          orderBy: 'seq',
          limit: 20,
        );
        if (pending.isEmpty) break;
        var progressed = false;
        for (final row in pending) {
          final resource = '${row['resource']}', entity = '${row['entity']}';
          final isBillGeneration =
              resource == 'bills' && row['path'] == 'bills/generate';
          // Procurement commands depend on their supplier/item/bill uploads.
          // Leave them pending if a parent needs review rather than creating
          // another validation conflict for each dependent ledger entry.
          final purchasePayload = jsonDecode(row['payload'] as String) as Json;
          final parents = <String>[
            if (resource == 'purchase_bills')
              '${purchasePayload['supplier_id']}',
            if (resource == 'purchase_bills')
              ...maps(purchasePayload['lines'])
                  .map((l) => '${l['purchase_item_id']}'),
            if (resource == 'purchase_events' &&
                purchasePayload['bill_id'] != null)
              '${purchasePayload['bill_id']}',
            if (resource == 'purchase_events')
              ...maps(purchasePayload['lines'])
                  .map((l) => '${l['purchase_item_id']}'),
          ];
          if (parents.isNotEmpty &&
              (await local!.db.query(
                'outbox',
                columns: ['seq'],
                where:
                    "seq<? AND entity IN (${List.filled(parents.length, '?').join(',')}) AND state IN ('pending','conflict')",
                whereArgs: [row['seq'], ...parents],
                limit: 1,
              )).isNotEmpty)
            continue;
          final blocked = await local!.db.query(
            'outbox',
            where: "entity=? AND seq<? AND state='conflict'",
            whereArgs: [entity, row['seq']],
            limit: 1,
          );
          if (blocked.isNotEmpty) {
            // A network timeout can commit the server bill but leave an older
            // order retry marked conflicted locally. Bills use the order id as
            // their outbox entity, so that stale conflict previously blocked
            // invoice reconciliation forever. Check the authoritative receipt
            // before giving up; if it exists, remove both obsolete intents.
            if (isBillGeneration && await _reconcileFinalizedOrder(entity)) {
              touched.addAll(['bills', 'orders', 'tables']);
              progressed = true;
            }
            continue;
          }
          Json? failedPayload;
          String? failedPath;
          try {
            var payload = jsonDecode(row['payload'] as String) as Json;
            var method = '${row['method']}', path = '${row['path']}';
            failedPayload = payload;
            failedPath = path;
            // Builds released before the minus-amount compatibility change
            // stored this UI label directly. Treat it as the fixed rupee
            // discount it always represented, so those invoices do not stay
            // stuck on an otherwise-connected terminal.
            if (resource == 'bills' && payload['discount_type'] == 'minus') {
              payload['discount_type'] = 'fixed';
              payload['discount_basis_points'] = 0;
            }
            final preparedKey = 'prepared_${row['key']}';
            if (await local!.meta(preparedKey) == null) {
              final ack = number(
                await local!.meta(
                  'ack_${resource == 'bills' && path == 'bills/generate' ? 'orders' : resource}_$entity',
                ),
              );
              if (ack > 0) {
                payload['version'] = ack;
                // Status commands have their own endpoint. Rewriting one as a
                // generic order PUT would silently re-occupy a cleared table.
                if (resource != 'bills' &&
                    method != 'DELETE' &&
                    path == resource) {
                  method = 'PUT';
                  path = '$resource/$entity';
                }
              }
              await local!.db.transaction((txn) async {
                await txn.update(
                  'outbox',
                  {
                    'payload': jsonEncode(payload),
                    'method': method,
                    'path': path,
                  },
                  where: 'key=?',
                  whereArgs: [row['key']],
                );
                await txn.insert('meta', {
                  'key': preparedKey,
                  'value': '1',
                }, conflictAlgorithm: ConflictAlgorithm.replace);
              });
            }
            final result = await request(
              method,
              path,
              body: payload,
              key: '${row['key']}',
            );
            uploadedThisRun = true;
            // A generated/settled invoice must contain the complete immutable
            // receipt before replacing local data. A DELETE correctly returns
            // only {id, deleted}; treating that acknowledgement as a receipt
            // made every invoice deletion stay stuck in Sync review.
            final needsReceipt =
                resource == 'bills' &&
                (path == 'bills/generate' || path.endsWith('/settlement'));
            if (needsReceipt &&
                (result['receipt'] is! Map ||
                    result['receipt']['items'] is! List ||
                    result['generated_at'] == null)) {
              throw ApiFailure(
                502,
                'Server returned an incomplete receipt; local receipt retained.',
              );
            }
            await local!.db.transaction((txn) async {
              if (result['version'] != null)
                await txn.insert('meta', {
                  'key': 'ack_${resource}_$entity',
                  'value': '${result['version']}',
                }, conflictAlgorithm: ConflictAlgorithm.replace);
              final later = await txn.query(
                'outbox',
                where: 'entity=? AND seq>?',
                whereArgs: [entity, row['seq']],
                limit: 1,
              );
              final drafts = await txn.query(
                'drafts',
                where: 'id=?',
                whereArgs: [entity],
              );
              if (result['version'] != null && method != 'DELETE') {
                final current = await txn.query(
                  'records',
                  where: 'resource=? AND id=?',
                  whereArgs: [resource, entity],
                );
                if (current.isNotEmpty)
                  await LocalStore.put(txn, resource, {
                    ...jsonDecode(current.first['body'] as String) as Json,
                    'version': result['version'],
                  });
              }
              // A draft may contain unsaved edits newer than this upload.
              if (result['id'] != null &&
                  method != 'DELETE' &&
                  later.isEmpty &&
                  drafts.isEmpty)
                await LocalStore.put(txn, resource, result);
              // Bill generation maps an order-id outbox entity to a new bill
              // id. Settlement edits already use the bill id, so the generic
              // acknowledgement above must retain any later local edit.
              if (resource == 'bills' && path == 'bills/generate') {
                final refs = await txn.query(
                  'meta',
                  where: 'key=?',
                  whereArgs: ['bill_$entity'],
                );
                final oldId = refs.firstOrNull?['value'];
                await LocalStore.put(txn, 'bills', result);
                if (oldId != null && oldId != result['id'])
                  await txn.delete(
                    'records',
                    where: 'resource=? AND id=?',
                    whereArgs: ['bills', oldId],
                  );
                await txn.insert('meta', {
                  'key': 'bill_$entity',
                  'value': '${result['id']}',
                }, conflictAlgorithm: ConflictAlgorithm.replace);
              }
              await txn.delete(
                'outbox',
                where: 'key=?',
                whereArgs: [row['key']],
              );
              await txn.delete(
                'meta',
                where: 'key=?',
                whereArgs: [preparedKey],
              );
            });
            touched.add(resource);
            progressed = true;
          } on ApiFailure catch (error) {
            if (error.status == 401 ||
                error.status == 429 ||
                error.status >= 500)
              rethrow;
            if (error.status == 409 &&
                (resource == 'orders' || resource == 'bills') &&
                await _reconcileFinalizedOrder(entity)) {
              touched.addAll(['bills', 'orders', 'tables']);
              progressed = true;
              continue;
            }
            // A permanent merge rejection (for example the target was
            // billed or changed on another terminal during confirmation)
            // must not leave two local cards falsely joined. The immutable
            // snapshot attached to this mutation restores the pre-merge
            // orders/tables; the conflict remains visible for audit.
            if (failedPath?.endsWith('/merge') == true &&
                failedPayload != null &&
                await rollbackRejectedDiningMerge(failedPayload)) {
              touched.addAll(['orders', 'tables']);
            }
            await local!.db.update(
              'outbox',
              {'state': 'conflict', 'error': error.message},
              where: 'key=?',
              whereArgs: [row['key']],
            );
            progressed = true;
          } on SocketException {
            // Keep genuine transport failures pending for the exponential
            // retry scheduler. Marking them conflicted would lose the
            // offline-first guarantee.
            rethrow;
          } on TimeoutException {
            rethrow;
          } on http.ClientException {
            rethrow;
          } catch (error) {
            // An old/malformed local record must never wedge the whole queue.
            // Preserve it for owner review and allow every independent later
            // order, bill, bank, and table update to upload immediately.
            await local!.db.update(
              'outbox',
              {
                'state': 'conflict',
                'error': 'Local sync record needs review: $error',
              },
              where: 'key=?',
              whereArgs: [row['key']],
            );
            progressed = true;
          }
        }
        if (!progressed) break;
      }
      final cursor = await local!.meta('cursor') ?? '0';
      final delta = await request('GET', 'updates?last_checked=$cursor');
      await local!.db.transaction((txn) async {
        for (final event in maps(delta['changes'])) {
          final incoming = event['operation'] == 'delete'
              ? null
              : Map<String, dynamic>.from(event['data'] as Map);
          // A server-finalized order always wins over an old open draft. This
          // is what releases Device 1's table after Device 2 settles it.
          // Open drafts still win over ordinary incoming edits, preserving
          // genuine offline work.
          final finalizedOrder =
              event['resource'] == 'orders' &&
              incoming != null &&
              '${incoming['status']}' != 'open';
          final releasedTable =
              event['resource'] == 'tables' &&
              incoming != null &&
              '${incoming['status']}' == 'empty' &&
              incoming['current_order_id'] == null;
          final pending = await txn.query(
            'outbox',
            where: 'entity=?',
            whereArgs: [event['id']],
            limit: 1,
          );
          if (pending.isNotEmpty && !finalizedOrder) continue;
          if (finalizedOrder) {
            await txn.delete('drafts', where: 'id=?', whereArgs: [event['id']]);
          } else if (event['resource'] == 'orders' &&
              (await txn.query(
                'drafts',
                where: 'id=?',
                whereArgs: [event['id']],
                limit: 1,
              )).isNotEmpty)
            continue;
          if (event['resource'] == 'tables') {
            final pendingOrders = await txn.rawQuery(
              "SELECT 1 FROM outbox WHERE resource='orders' AND json_extract(payload,'\$.table_id')=? LIMIT 1",
              [event['id']],
            );
            if (pendingOrders.isNotEmpty && !releasedTable) continue;
          }
          if (event['operation'] == 'delete') {
            await txn.delete(
              'records',
              where: 'resource=? AND id=?',
              whereArgs: [event['resource'], event['id']],
            );
          } else {
            await LocalStore.put(txn, event['resource'], incoming!);
          }
          touched.add(event['resource']);
        }
        await txn.insert('meta', {
          'key': 'cursor',
          'value': '${delta['next_cursor']}',
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      });
      online = true;
      syncError = null;
      syncSucceeded();
    } on ApiFailure catch (error) {
      expired = error.status == 401;
      syncError = error.message;
      // A JSON API response proves that the server is reachable. Validation,
      // conflict, or expired-session messages must not misleadingly turn the
      // POS into "Offline" straight after a successful login.
      online = true;
      failed = true;
      if (error.status == 429 || error.status >= 500) {
        syncFailed();
      } else {
        syncSucceeded();
      }
    } catch (error) {
      // A bill/order may already have been accepted in this same run and only
      // the optional change-feed refresh timed out. Keep that terminal online
      // and retain the actual error for Sync; never mislabel a saved invoice
      // as offline or leave it waiting just because the follow-up pull failed.
      failed = true;
      syncError =
          error is SocketException ||
              error is TimeoutException ||
              error is http.ClientException
          ? null
          : '$error';
      syncFailed();
      // A brief updates-feed timeout must not flip a functioning counter to
      // Offline. Keep the last verified state for one retry; two consecutive
      // connection failures still show Offline normally.
      online = uploadedThisRun || (wasOnline && syncFailures < 2);
    } finally {
      await refreshOutboxCounts();
      syncing = false;
      if (touched.isNotEmpty) dataChanged(touched);
      // The app bar owns the global Connected / Pending / Offline label. It
      // listens to Session rather than individual records, so publish a state
      // change whenever the upload result actually changes that label.
      if (wasOnline != online ||
          previousQueued != queued ||
          previousConflicts != conflicts ||
          previousExpired != expired ||
          previousError != syncError) {
        changed();
      }
      // A bill/order saved while a previous request was finishing must not
      // wait for the periodic worker. At most one extra immediate pass is
      // made; if it fails, syncFailed() has already restored backoff.
      final requestedWhileBusy = _syncRequestedWhileBusy;
      _syncRequestedWhileBusy = false;
      if (requestedWhileBusy && !expired && queued > 0) {
        retryTimer?.cancel();
        retryTimer = null;
        unawaited(sync());
        return;
      }
      // Newly queued commands during the final pull must not wait for the poll.
      if (!failed && queued > 0) {
        final remaining = await local!.db.rawQuery(
          "SELECT 1 FROM outbox p WHERE p.state='pending' AND NOT EXISTS (SELECT 1 FROM outbox c WHERE c.entity=p.entity AND c.seq<p.seq AND c.state='conflict') LIMIT 1",
        );
        if (remaining.isNotEmpty) unawaited(sync());
      }
    }
  }
}
