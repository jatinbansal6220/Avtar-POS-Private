import 'shared/field_spec.dart';
import 'tables/data/tables_fields.dart';
import 'menu/data/menu_fields.dart';
import 'combos/data/combos_fields.dart';
import 'staff/data/staff_fields.dart';
import 'attendance/data/attendance_fields.dart';
import 'payments/data/payments_fields.dart';
import 'banks/data/banks_fields.dart';
import 'purchases/data/purchases_fields.dart';
import 'settings/data/settings_fields.dart';

const specs = <String, List<FieldSpec>>{
  'tables': tablesFields,
  'menu_items': menuFields,
  'combos': combosFields,
  'staff': staffFields,
  'attendance': attendanceFields,
  'payments': paymentsFields,
  'banks': banksFields,
  'purchases': purchasesFields,
  'settings': settingsFields,
};
const titles = {
  'tables': 'Tables',
  'menu_items': 'Menu items',
  'combos': 'Combos',
  'staff': 'Staff',
  'attendance': 'Attendance',
  'payments': 'Salary payments',
  'banks': 'Bank accounts',
  'purchases': 'Purchases',
  'settings': 'Restaurant settings',
  'bills': 'Bill history',
  'orders': 'Orders',
};
