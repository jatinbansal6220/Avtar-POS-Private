import '../../../core/models.dart';

/// Local kitchen acknowledgements, independent of bill quantities and prices.
class KotTicket {
  final List<Json> items;
  final Json acknowledgedOrder;
  final Map<String, int> sent;
  const KotTicket(this.items, this.acknowledgedOrder, this.sent);
}

class KotTracker {
  static String itemKey(Json item) {
    final menu = '${item['menu_item_id'] ?? ''}';
    final combo = '${item['combo_id'] ?? ''}';
    if (menu.isNotEmpty) return 'menu:$menu';
    if (combo.isNotEmpty) return 'combo:$combo';
    return 'name:${item['item_name'] ?? ''}';
  }

  /// Migrate the previous name/notes-based keys without counting the same
  /// printed quantity twice after a cart is cloned or renamed by server sync.
  static Map<String, int> readSent(dynamic raw) {
    final result = <String, int>{};
    if (raw is! Map) return result;
    for (final entry in raw.entries) {
      final key = '${entry.key}';
      final parts = key.split('|');
      final normalized =
          !key.startsWith('menu:') &&
              !key.startsWith('combo:') &&
              !key.startsWith('name:') &&
              parts.length >= 4
          ? itemKey({
              'menu_item_id': parts[0],
              'combo_id': parts[1],
              'item_name': parts[2],
            })
          : key;
      result[normalized] = (result[normalized] ?? 0) + number(entry.value);
    }
    return result;
  }

  static KotTicket prepare(Json order, Map<String, int> sent) {
    final snapshot = clone(order);
    final rows = maps(snapshot['items']);
    final baseline = Map<String, int>.from(sent);
    final marked = <String, int>{};
    for (final row in rows) {
      final key = itemKey(row);
      marked[key] = (marked[key] ?? 0) + number(row['_kot_printed_quantity']);
    }
    for (final entry in marked.entries) {
      if (entry.value > (baseline[entry.key] ?? 0)) {
        baseline[entry.key] = entry.value;
      }
    }
    final remaining = Map<String, int>.from(baseline);
    // Explicit line markers win. Newly added/re-added lines start at zero,
    // even when an older line for the same dish was already sent to kitchen.
    for (final row in rows) {
      if (!row.containsKey('_kot_printed_quantity')) continue;
      final key = itemKey(row);
      remaining[key] =
          ((remaining[key] ?? 0) - number(row['_kot_printed_quantity'])).clamp(
            0,
            1000000000,
          );
    }
    final items = <Json>[];
    final updated = Map<String, int>.from(baseline);
    for (final row in rows) {
      final key = itemKey(row);
      final quantity = number(row['quantity']);
      final printed = row.containsKey('_kot_printed_quantity')
          ? number(row['_kot_printed_quantity'])
          : (remaining[key] ?? 0).clamp(0, quantity);
      if (!row.containsKey('_kot_printed_quantity')) {
        remaining[key] = (remaining[key] ?? 0) - printed;
      }
      final delta = quantity - printed;
      row['_kot_printed_quantity'] = printed;
      if (delta <= 0) continue;
      items.add({...row, 'quantity': delta});
      row['_kot_printed_quantity'] = printed + delta;
      updated[key] = (updated[key] ?? 0) + delta;
    }
    snapshot['items'] = rows;
    snapshot['_kot_sent_quantities'] = updated;
    return KotTicket(items, snapshot, updated);
  }
}
