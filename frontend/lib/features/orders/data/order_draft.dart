import '../../../core/models.dart';
import '../../../core/session.dart';

Json newOrder({Json? table, String channel = 'takeaway', int? posSlot}) => {
  'id': Session.uuid.v4(),
  'version': 0,
  'status': 'open',
  'created_at': indiaTimestamp(),
  'table_id': table?['id'],
  'table_number':
      table?['table_number'] ??
      (channel == 'online'
          ? 'Online'
          : channel == 'pos'
          ? 'Menu POS'
          : 'Takeaway'),
  'order_type': table != null ? 'dine_in' : channel,
  'online_platform': channel == 'online' ? 'direct' : null,
  'online_platform_name': channel == 'online' ? 'Direct online order' : null,
  // Menu POS can keep up to ten independent customer carts. This key is a
  // local workspace label only; the server continues to treat every cart as
  // a normal, independent POS order.
  if (channel == 'pos' && posSlot != null) 'pos_slot': posSlot,
  'items': <Json>[],
  'customer_name': '',
  'customer_phone': '',
  'notes': '',
};

Json orderPayload(Json order) => {
  for (final key in [
    'id',
    'version',
    'table_id',
    'order_type',
    'online_platform',
    'online_platform_name',
    'customer_name',
    'customer_phone',
    'notes',
    'voids',
  ])
    key: order[key],
  'items': maps(order['items'])
      .map(
        (item) => {
          'menu_item_id': item['menu_item_id'],
          'combo_id': item['combo_id'],
          'quantity': number(item['quantity']),
          'notes': item['notes'] ?? '',
          'discount_type': item['discount_type'] ?? 'percent',
          'discount_value': number(item['discount_value']),
        },
      )
      .toList(),
};
