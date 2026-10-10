import 'dart:convert';

import 'package:flutter/services.dart';

import '../../core/local_store.dart';
import '../../core/models.dart';

/// One durable, local-only restaurant dataset for the Windows/APK demo.
/// It is intentionally independent of API availability.
Future<void> seedOfflineDemo(LocalStore store) async {
  if (await store.meta('offline_demo_seeded_v5') == '1') return;

  final tables = <Json>[
    for (var i = 1; i <= 16; i++)
      {
        'id': 'table_$i',
        'table_number': 'T${i.toString().padLeft(2, '0')}',
        'section': i <= 6
            ? 'Main Hall'
            : i <= 9
            ? 'Garden'
            : 'Family Room',
        'capacity': i % 3 == 0 ? 6 : 4,
        'status':
            <int, String>{
              2: 'occupied',
              4: 'bill_pending',
              6: 'occupied',
              9: 'occupied',
              11: 'bill_pending',
            }[i] ??
            'empty',
        'current_order_id': <int, String>{
          2: 'demo_order_2',
          4: 'demo_order_4',
          6: 'demo_order_6',
          9: 'demo_order_9',
          11: 'demo_order_11',
        }[i],
      },
  ];
  for (final table in tables) {
    await LocalStore.put(store.db, 'tables', table);
  }

  final menu = <Json>[];
  try {
    final source = await rootBundle.loadString(
      'assets/data/avtar_cooks_menu.json',
    );
    final imported = (jsonDecode(source) as List).cast<Map>();
    menu.addAll([
      for (var i = 0; i < imported.length; i++)
        {
          'id': 'menu_${i + 1}',
          'name': imported[i]['name'],
          'category': imported[i]['category'],
          'price_minor': number(imported[i]['price_minor']),
          'short_code': 'M${(i + 1).toString().padLeft(3, '0')}',
          'is_active': true,
        },
    ]);
  } catch (_) {
    menu.addAll([
      {
        'id': 'menu_1',
        'name': 'Aloo Gobhi',
        'category': 'Main Course',
        'price_minor': 18000,
        'is_active': true,
      },
      {
        'id': 'menu_2',
        'name': 'Dal Makhani',
        'category': 'Main Course',
        'price_minor': 22000,
        'is_active': true,
      },
      {
        'id': 'menu_3',
        'name': 'Butter Naan',
        'category': 'Breads',
        'price_minor': 4000,
        'is_active': true,
      },
      {
        'id': 'menu_4',
        'name': 'Paneer Tikka',
        'category': 'Starters',
        'price_minor': 26000,
        'is_active': true,
      },
      {
        'id': 'menu_5',
        'name': 'Veg Biryani',
        'category': 'Rice',
        'price_minor': 24000,
        'is_active': true,
      },
      {
        'id': 'menu_6',
        'name': 'Fresh Lime Soda',
        'category': 'Beverages',
        'price_minor': 9000,
        'is_active': true,
      },
      {
        'id': 'menu_7',
        'name': 'Gulab Jamun',
        'category': 'Desserts',
        'price_minor': 10000,
        'is_active': true,
      },
    ]);
  }
  // A distinct quick-access category for bottles/cold drinks. The catalog
  // page still lets an owner add any other drinks under this same category.
  const waterAndColdDrinks = [
    {
      'id': 'menu_demo_water_bottle',
      'name': 'Water Bottle (1 L)',
      'is_active': true,
      'price_minor': 2000,
      'category': 'Water & Cold Drinks',
    },
    {
      'id': 'menu_demo_cold_drink',
      'name': 'Cold Drink - Add MRP',
      'is_active': true,
      'price_minor': 0,
      'category': 'Water & Cold Drinks',
    },
  ];
  for (final item in waterAndColdDrinks) {
    if (!menu.any((row) => row['name'] == item['name'])) menu.add(item);
  }
  for (final item in menu) {
    await LocalStore.put(store.db, 'menu_items', item);
  }

  await LocalStore.put(store.db, 'settings', {
    'id': 'settings_demo',
    'restaurant_name': 'Avtar Cooks',
    'tagline': 'Food that feels like home',
    'restaurant_address': 'MG Road, Indore',
    'restaurant_phone': '+91 731 400 2020',
    'gstin': '',
    'fssai_lic': '',
    'is_tax_enabled': true,
    'tax_basis_points': 500,
    'default_discount_basis_points': 0,
    'printer_ip': '',
    'printer_port': 9100,
    'printer_paper_width': '80mm',
  });

  final openOrders = <Json>[
    {
      'id': 'demo_order_2',
      'table_id': 'table_2',
      'table_number': 'T02',
      'order_type': 'dine_in',
      'status': 'open',
      'items': [
        {'item_name': 'Paneer Tikka', 'quantity': 1, 'price_minor': 26000},
        {'item_name': 'Butter Naan', 'quantity': 4, 'price_minor': 4000},
      ],
      'subtotal_minor': 42000,
    },
    {
      'id': 'demo_order_4',
      'table_id': 'table_4',
      'table_number': 'T04',
      'order_type': 'dine_in',
      'status': 'open',
      'bill_pending': true,
      'items': [
        {'item_name': 'Dal Makhani', 'quantity': 2, 'price_minor': 22000},
        {'item_name': 'Butter Naan', 'quantity': 4, 'price_minor': 4000},
      ],
      'subtotal_minor': 60000,
    },
    {
      'id': 'demo_order_6',
      'table_id': 'table_6',
      'table_number': 'T06',
      'order_type': 'dine_in',
      'status': 'open',
      'items': [
        {'item_name': 'Aloo Gobhi', 'quantity': 2, 'price_minor': 18000},
        {'item_name': 'Veg Biryani', 'quantity': 1, 'price_minor': 24000},
      ],
      'subtotal_minor': 60000,
    },
    {
      'id': 'demo_order_9',
      'table_id': 'table_9',
      'table_number': 'T09',
      'order_type': 'dine_in',
      'status': 'open',
      'items': [
        {'item_name': 'Butter Chicken', 'quantity': 1, 'price_minor': 32000},
        {'item_name': 'Garlic Naan', 'quantity': 3, 'price_minor': 4500},
      ],
      'subtotal_minor': 45500,
    },
    {
      'id': 'demo_order_11',
      'table_id': 'table_11',
      'table_number': 'T11',
      'order_type': 'dine_in',
      'status': 'open',
      'bill_pending': true,
      'items': [
        {'item_name': 'Veg Biryani', 'quantity': 2, 'price_minor': 24000},
        {'item_name': 'Fresh Lime Soda', 'quantity': 2, 'price_minor': 9000},
      ],
      'subtotal_minor': 66000,
    },
  ];
  for (final order in openOrders) {
    await LocalStore.put(store.db, 'orders', order);
  }

  final staff = <Json>[
    {
      'id': 'staff_demo_1',
      'name': 'Rohan Sharma',
      'phone': '+91 98111 22334',
      'role': 'cashier',
      'joining_date': '2024-01-15',
      'monthly_salary_minor': 2800000,
      'qualification': 'Hospitality',
      'degree': 'B.Com',
      'experience': '5 years',
    },
    {
      'id': 'staff_demo_2',
      'name': 'Neha Kapoor',
      'phone': '+91 98765 43210',
      'role': 'manager',
      'joining_date': '2023-11-02',
      'monthly_salary_minor': 3500000,
      'qualification': 'Hotel Management',
      'degree': 'BHM',
      'experience': '8 years',
    },
    {
      'id': 'staff_demo_3',
      'name': 'Amit Singh',
      'phone': '+91 98000 11223',
      'role': 'waiter',
      'joining_date': '2025-02-10',
      'monthly_salary_minor': 2200000,
      'qualification': 'Food Service',
      'degree': 'Diploma',
      'experience': '2 years',
    },
    {
      'id': 'staff_demo_4',
      'name': 'Pooja Verma',
      'phone': '+91 98989 77665',
      'role': 'chef',
      'joining_date': '2022-06-18',
      'monthly_salary_minor': 3200000,
      'qualification': 'Culinary Arts',
      'degree': 'Diploma',
      'experience': '9 years',
    },
  ];
  for (final row in staff) {
    await LocalStore.put(store.db, 'staff', row);
  }

  final now = indiaNow();
  final dates = [
    day(now.subtract(const Duration(days: 2))),
    day(now.subtract(const Duration(days: 1))),
    day(now),
  ];
  for (final member in staff) {
    for (var i = 0; i < dates.length; i++) {
      await LocalStore.put(store.db, 'attendance', {
        'id': 'attendance_${member['id']}_$i',
        'staff_id': member['id'],
        'date': dates[i],
        'status': i == 1 && member['id'] == 'staff_demo_3'
            ? 'half_day'
            : 'present',
      });
    }
  }

  final bills = <Json>[
    {
      'id': 'bill_demo_1',
      'bill_number': 'AV-00000041',
      'table_number': 'T01',
      'customer_name': 'Walk-in guest',
      'generated_at': '${dates[0]}T13:14:00+05:30',
      'items': [
        {'item_name': 'Dal Makhani', 'quantity': 2, 'price_minor': 22000},
        {'item_name': 'Butter Naan', 'quantity': 4, 'price_minor': 4000},
      ],
      'subtotal_minor': 60000,
      'discount_minor': 0,
      'tax_minor': 3000,
      'total_minor': 63000,
      'payment_method': 'cash',
      'status': 'paid',
    },
    {
      'id': 'bill_demo_2',
      'bill_number': 'AV-00000042',
      'table_number': 'T07',
      'customer_name': 'Family table',
      'generated_at': '${dates[0]}T19:42:00+05:30',
      'items': [
        {'item_name': 'Paneer Tikka', 'quantity': 2, 'price_minor': 26000},
        {'item_name': 'Fresh Lime Soda', 'quantity': 3, 'price_minor': 9000},
      ],
      'subtotal_minor': 79000,
      'discount_minor': 2000,
      'tax_minor': 3850,
      'total_minor': 80850,
      'payment_method': 'upi',
      'status': 'paid',
    },
    {
      'id': 'bill_demo_3',
      'bill_number': 'AV-00000043',
      'table_number': 'Takeaway',
      'customer_name': 'Counter order',
      'generated_at': '${dates[1]}T12:08:00+05:30',
      'items': [
        {'item_name': 'Veg Biryani', 'quantity': 3, 'price_minor': 24000},
      ],
      'subtotal_minor': 72000,
      'discount_minor': 0,
      'tax_minor': 3600,
      'total_minor': 75600,
      'payment_method': 'card',
      'status': 'paid',
    },
    {
      'id': 'bill_demo_4',
      'bill_number': 'AV-00000044',
      'table_number': 'T03',
      'customer_name': 'Mehta family',
      'generated_at': '${dates[1]}T20:21:00+05:30',
      'items': [
        {'item_name': 'Butter Chicken', 'quantity': 2, 'price_minor': 32000},
        {'item_name': 'Garlic Naan', 'quantity': 6, 'price_minor': 4500},
      ],
      'subtotal_minor': 91000,
      'discount_minor': 0,
      'tax_minor': 4550,
      'total_minor': 95550,
      'payment_method': 'mixed',
      'status': 'paid',
    },
    {
      'id': 'bill_demo_5',
      'bill_number': 'AV-00000045',
      'table_number': 'T10',
      'customer_name': 'Office lunch',
      'generated_at': '${dates[2]}T13:05:00+05:30',
      'items': [
        {'item_name': 'Aloo Gobhi', 'quantity': 3, 'price_minor': 18000},
        {'item_name': 'Butter Naan', 'quantity': 6, 'price_minor': 4000},
      ],
      'subtotal_minor': 78000,
      'discount_minor': 3000,
      'tax_minor': 3750,
      'total_minor': 78750,
      'payment_method': 'upi',
      'status': 'paid',
    },
    {
      'id': 'bill_demo_6',
      'bill_number': 'AV-00000046',
      'table_number': 'Takeaway',
      'customer_name': 'Counter order',
      'generated_at': '${dates[2]}T16:30:00+05:30',
      'items': [
        {'item_name': 'Paneer Tikka', 'quantity': 1, 'price_minor': 26000},
        {'item_name': 'Gulab Jamun', 'quantity': 2, 'price_minor': 10000},
      ],
      'subtotal_minor': 46000,
      'discount_minor': 0,
      'tax_minor': 2300,
      'total_minor': 48300,
      'payment_method': 'cash',
      'status': 'paid',
    },
  ];
  for (final row in bills) {
    await LocalStore.put(store.db, 'bills', row);
  }
  await store.setMeta('offline_demo_seeded_v5', '1');
}
