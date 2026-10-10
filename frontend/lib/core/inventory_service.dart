part of 'session.dart';

/// Inventory counts are snapshots, not adjustments. This preserves the
/// physical count that staff recorded at a particular time for audit history.
extension SessionInventory on Session {
  Future<Json> createInventoryItem({
    required String name,
    required int quantity,
    String unit = 'pcs',
    String? note,
  }) async {
    requireFeature('inventory');
    if (name.trim().isEmpty) throw ApiFailure(422, 'Enter an item title.');
    if (quantity < 0) throw ApiFailure(422, 'Quantity cannot be negative.');
    final recordedAt = indiaTimestamp();
    final item = <String, dynamic>{
      'id': Session.uuid.v4(),
      'name': name.trim(),
      'unit': unit.trim().isEmpty ? 'pcs' : unit.trim(),
      'current_quantity': quantity,
      'last_recorded_at': recordedAt,
      'created_at': recordedAt,
      'updated_at': recordedAt,
    };
    final entry = <String, dynamic>{
      'id': Session.uuid.v4(),
      'inventory_item_id': item['id'],
      'quantity': quantity,
      'recorded_at': recordedAt,
      if (note?.trim().isNotEmpty == true) 'note': note!.trim(),
      'created_at': recordedAt,
      'updated_at': recordedAt,
    };
    await local!.db.transaction((txn) async {
      await LocalStore.put(txn, 'inventory_items', item);
      await LocalStore.put(txn, 'inventory_entries', entry);
      // The parent item is always queued first, so its history reference is
      // valid on the server even when a device was offline during both saves.
      await queueMutation(
        txn,
        'inventory_items',
        item['id'] as String,
        'POST',
        'inventory_items',
        item,
      );
      await queueMutation(
        txn,
        'inventory_entries',
        entry['id'] as String,
        'POST',
        'inventory_entries',
        entry,
      );
    });
    publishSave(['inventory_items', 'inventory_entries']);
    return item;
  }

  Future<Json> recordInventoryQuantity(
    Json item, {
    required int quantity,
    String? note,
  }) async {
    requireFeature('inventory');
    if (quantity < 0) throw ApiFailure(422, 'Quantity cannot be negative.');
    final id = item['id']?.toString() ?? '';
    if (id.isEmpty) throw ApiFailure(422, 'Inventory item is missing.');
    final recordedAt = indiaTimestamp();
    final entry = <String, dynamic>{
      'id': Session.uuid.v4(),
      'inventory_item_id': id,
      'quantity': quantity,
      'recorded_at': recordedAt,
      if (note?.trim().isNotEmpty == true) 'note': note!.trim(),
      'created_at': recordedAt,
      'updated_at': recordedAt,
    };
    await local!.db.transaction((txn) async {
      final current = await txn.query(
        'records',
        where: 'resource=? AND id=?',
        whereArgs: ['inventory_items', id],
        limit: 1,
      );
      if (current.isEmpty) {
        throw ApiFailure(404, 'Inventory item was not found.');
      }
      final stored = jsonDecode(current.single['body'] as String) as Json;
      await LocalStore.put(txn, 'inventory_items', {
        ...stored,
        'current_quantity': quantity,
        'last_recorded_at': recordedAt,
        'updated_at': recordedAt,
      });
      await LocalStore.put(txn, 'inventory_entries', entry);
      // The API recalculates and emits the parent item from this immutable
      // entry; no competing client can overwrite its current quantity.
      await queueMutation(
        txn,
        'inventory_entries',
        entry['id'] as String,
        'POST',
        'inventory_entries',
        entry,
      );
    });
    publishSave(['inventory_items', 'inventory_entries']);
    return entry;
  }
}
