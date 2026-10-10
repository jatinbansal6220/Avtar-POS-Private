import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/models.dart';
import '../../../core/session.dart';
import 'kot_tracker.dart';

class OrderController extends ChangeNotifier {
  final Session session;
  Json order;
  Future<void> _writes = Future.value();
  String? persistenceError;
  bool saving = false;
  bool draftSaving = false, draftSaved = false, _disposed = false;
  int _draftRevision = 0;
  Map<String, int> _kotSent = {};
  final List<List<Json>> _undoItems = [];
  bool get canUndo =>
      !saving && order['status'] == 'open' && _undoItems.isNotEmpty;
  void undo() {
    if (!canUndo) return;
    final previous = _undoItems.removeLast();
    change(() => order['items'] = previous);
  }

  OrderController(this.session, Json initial) : order = clone(initial) {
    unawaited(refreshKotState());
  }
  int get kotPendingQuantity => KotTracker.prepare(
    order,
    _kotSent,
  ).items.fold<int>(0, (sum, item) => sum + number(item['quantity']));

  Future<void> refreshKotState() async {
    final id = '${order['id']}';
    try {
      final v2 = await session.local!.meta('kot_sent_quantities_v2_$id');
      final raw = v2 ?? await session.local!.meta('kot_sent_quantities_v1_$id');
      final sent = v2 == null
          ? KotTracker.readSent(order['_kot_sent_quantities'])
          : <String, int>{};
      if (raw != null) {
        final stored = KotTracker.readSent(jsonDecode(raw));
        for (final entry in stored.entries) {
          if (entry.value > (sent[entry.key] ?? 0)) {
            sent[entry.key] = entry.value;
          }
        }
      }
      if (!_disposed && '${order['id']}' == id) {
        _kotSent = sent;
        notifyListeners();
      }
    } catch (_) {
      // Explicit line acknowledgements still provide the current KOT count.
    }
  }

  List<Json> get items => maps(order['items']);
  int get subtotal => items.fold(
    0,
    (sum, row) => sum + number(row['price_minor']) * number(row['quantity']),
  );
  void change(void Function() edit, {bool undoable = false}) {
    session.requireFeature('order_edit');
    session.requireOrderAccess(order);
    if (undoable) {
      _undoItems.add(maps(clone(order)['items']));
      if (_undoItems.length > 20) _undoItems.removeAt(0);
    }
    edit();
    if (order['_queued_key'] != null) order['_dirty_after_queue'] = true;
    final snapshot = clone(order);
    final revision = ++_draftRevision;
    draftSaving = true;
    _writes = _writes
        .then((_) => session.local!.draft(snapshot))
        .then((_) {
          if (revision == _draftRevision &&
              snapshot['order_type'] == 'dine_in') {
            session.dataChanged(['orders']);
          }
          if (!_disposed && revision == _draftRevision) {
            draftSaving = false;
            draftSaved = true;
            persistenceError = null;
            notifyListeners();
          }
        })
        .catchError((Object e) {
          if (!_disposed && revision == _draftRevision) {
            draftSaving = false;
            draftSaved = false;
            persistenceError = 'Could not save draft: $e';
            notifyListeners();
          }
        });
    notifyListeners();
  }

  void add(Json item, {bool combo = false}) {
    if (combo) session.requireFeature('combos');
    change(() {
      final rows = items;
      final field = combo ? 'combo_id' : 'menu_item_id';
      final found = rows.where((row) => row[field] == item['id']).firstOrNull;
      if (found != null) {
        found['quantity'] = number(found['quantity']) + 1;
      } else {
        rows.add({
          'menu_item_id': combo ? null : item['id'],
          'combo_id': combo ? item['id'] : null,
          'item_name': item['name'],
          'price_minor': number(item['price_minor']),
          'quantity': 1,
          '_kot_printed_quantity': 0,
          'notes': '',
        });
      }
      order['items'] = rows;
    }, undoable: true);
  }

  void quantity(int index, int delta) => change(() {
    final rows = items;
    final next = number(rows[index]['quantity']) + delta;
    if (next <= 0) {
      rows.removeAt(index);
    } else if (next <= 999) {
      rows[index]['quantity'] = next;
    }
    order['items'] = rows;
  }, undoable: true);
  void text(String key, String value) => change(() => order[key] = value);
  Future<void> save() async {
    if (saving) return;
    saving = true;
    notifyListeners();
    try {
      await _writes;
      if (persistenceError != null) throw ApiFailure(500, persistenceError!);
      final stored = await session.local!.get('orders', order['id']);
      if (stored != null)
        order['version'] = stored['version'] ?? order['version'];
      await session.enqueueOrder(order);
      _undoItems.clear();
    } finally {
      saving = false;
      notifyListeners();
    }
  }

  Future<void> refreshVersion() async {
    final pending = await session.local!.db.query(
      'outbox',
      where: 'entity=?',
      whereArgs: [order['id']],
    );
    if (pending.isNotEmpty) return;
    final draft = await session.local!.readDraft(order['id']);
    final server = await session.local!.get('orders', order['id']);
    if (server != null && order['_queued_key'] != null) {
      if (draft == null) {
        order = clone(server);
      } else {
        order['version'] = number(
          await session.local!.meta('ack_${order['id']}'),
        );
        order.remove('_queued_key');
      }
    }
  }

  Future<void> flush() => _writes;

  /// Keeps a completed POS bill in history while clearing only the active cart.
  void startFreshOrder(Json nextOrder) {
    _undoItems.clear();
    order = clone(nextOrder);
    persistenceError = null;
    _writes = Future.value();
    _draftRevision++;
    draftSaving = false;
    draftSaved = false;
    _kotSent = KotTracker.readSent(order['_kot_sent_quantities']);
    notifyListeners();
    unawaited(refreshKotState());
  }

  /// Persist item details locally without involving the upload worker.
  void editItem(
    int index, {
    required String notes,
    required String discountType,
    required int discountValue,
  }) => change(() {
    if (discountValue > 0) session.requireFeature('discounts');
    _undoItems.clear();
    final rows = items;
    rows[index].addAll({
      'notes': notes,
      'discount_type': discountType,
      'discount_value': discountValue,
    });
    order['items'] = rows;
  });
  void voidItem(int index, String reason) {
    if (reason.trim().isEmpty)
      throw ApiFailure(422, 'A cancellation reason is required.');
    change(() {
      _undoItems.clear();
      final rows = items;
      order['voids'] = [
        ...maps(order['voids']),
        {
          ...rows.removeAt(index),
          'reason': reason.trim(),
          'voided_at': indiaTimestamp(),
          'actor': session.user?['name'] ?? 'Owner',
        },
      ];
      order['items'] = rows;
    });
  }

  bool get lastDiningItem =>
      order['order_type'] == 'dine_in' &&
      order['table_id'] != null &&
      items.length == 1;

  /// Clears a dining table only after the final line has been voided and the
  /// manager explicitly approves it.
  Future<void> clearEmptyDiningTable() async {
    if (items.isNotEmpty) {
      throw ApiFailure(422, 'Remove the final item before clearing the table.');
    }
    await flush();
    await session.changeOrderStatus(order, action: 'cancel');
    _undoItems.clear();
    order['status'] = 'cancelled';
    notifyListeners();
  }

  Future<void> markBillPending() async {
    if (items.isEmpty) {
      throw ApiFailure(
        422,
        'Add at least one item before marking a table bill pending.',
      );
    }
    await flush();
    await save();
    await session.changeOrderStatus(order, action: 'bill_pending');
    order['bill_pending'] = true;
    notifyListeners();
  }

  bool get hasMergedTables =>
      List<String>.from(order['merged_table_ids'] ?? []).length > 1;

  Future<void> changeTable(String enteredTableNumber) async {
    if (hasMergedTables) {
      throw ApiFailure(
        422,
        'Separate the merged tables before changing this table.',
      );
    }
    await flush();
    await save();
    order = clone(await session.transferDiningOrder(order, enteredTableNumber));
    notifyListeners();
  }

  Future<void> mergeTable(String enteredTableNumber) async {
    await flush();
    await save();
    order = clone(await session.mergeDiningTables(order, enteredTableNumber));
    notifyListeners();
  }

  Future<void> separateTables() async {
    await flush();
    _undoItems.clear();
    await session.separateDiningTables(order);
    order = {
      ...order,
      'merged_table_ids': <String>[],
      'merged_table_numbers': <String>[],
      'merged_order_ids': <String>[],
    };
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
