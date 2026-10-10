<?php

return [
    // Provision only on the server. Never embed the password in EXE/APK/source.
    'password_hash' => env('DEVELOPER_PASSWORD_HASH', ''),
    'features' => [
        'tables' => 'Dining tables', 'pos' => 'Menu POS', 'invoices' => 'Invoices',
        'purchases' => 'Purchases', 'inventory' => 'Inventory', 'catalog' => 'Menu catalog',
        'staff' => 'Staff and attendance', 'closing' => 'Day closing', 'analytics' => 'Analytics',
        'settings' => 'Restaurant settings', 'banks' => 'Bank accounts', 'customers' => 'Customers',
        'combos' => 'Combos', 'expenses' => 'Expenses', 'online_orders' => 'Online orders',
        'takeaway' => 'Takeaway orders', 'kot' => 'Kitchen tickets', 'printing' => 'Printing',
        'table_merge' => 'Merge tables', 'table_transfer' => 'Move tables', 'table_separate' => 'Separate tables',
        'order_edit' => 'Order editing', 'discounts' => 'New discounts', 'upi' => 'UPI payments',
        'card' => 'Card / online payments', 'mixed_payment' => 'Mixed payments',
        'invoice_delete' => 'Delete invoices', 'updates' => 'Client updates', 'sync' => 'Online sync',
    ],
];
