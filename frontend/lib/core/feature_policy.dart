const developerFeatures = <String, String>{
  'tables': 'Dining tables',
  'pos': 'Menu POS',
  'invoices': 'Invoices',
  'purchases': 'Purchases',
  'inventory': 'Inventory',
  'catalog': 'Menu catalog',
  'staff': 'Staff and attendance',
  'closing': 'Day closing',
  'analytics': 'Analytics',
  'settings': 'Restaurant settings',
  'banks': 'Bank accounts',
  'customers': 'Customers',
  'combos': 'Combos',
  'expenses': 'Expenses',
  'online_orders': 'Online orders',
  'takeaway': 'Takeaway orders',
  'kot': 'Kitchen tickets',
  'printing': 'Printing',
  'table_merge': 'Merge tables',
  'table_transfer': 'Move tables',
  'table_separate': 'Separate tables',
  'order_edit': 'Order editing',
  'discounts': 'New discounts',
  'upi': 'UPI payments',
  'card': 'Card / online payments',
  'mixed_payment': 'Mixed payments',
  'invoice_delete': 'Delete invoices',
  'updates': 'Client updates',
  'sync': 'Online sync',
};

String? resourceFeature(String resource) => switch (resource) {
  'bills' => 'invoices',
  'menu_items' => 'catalog',
  'inventory_items' || 'inventory_entries' || 'stock_movements' => 'inventory',
  'attendance' || 'payments' || 'staff_salary_adjustments' => 'staff',
  'purchase_categories' ||
  'purchase_items' ||
  'purchase_suppliers' ||
  'purchase_bills' ||
  'purchase_events' => 'purchases',
  'table_bookings' => 'tables',
  _ => developerFeatures.containsKey(resource) ? resource : null,
};

bool validPolicy(dynamic value) =>
    value is Map &&
    value['app_enabled'] is bool &&
    value['message'] is String &&
    (value['message'] as String).runes.length <= 240 &&
    value['features'] is Map &&
    (value['features'] as Map).values.every((flag) => flag is bool);
