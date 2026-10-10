import '../../shared/field_spec.dart';

const purchasesFields = [
  FieldSpec('purchase_item_id', 'Purchase item', required: false),
  FieldSpec('item_name', 'Item purchased'),
  FieldSpec('category', 'Category'),
  FieldSpec('supplier_name', 'Supplier'),
  FieldSpec('quantity', 'Quantity', kind: 'decimal'),
  FieldSpec('unit', 'Unit (kg, L, pcs)'),
  FieldSpec('unit_price_minor', 'Price per unit (₹)', kind: 'money'),
  FieldSpec('purchase_date', 'Purchase date', kind: 'date'),
  FieldSpec(
    'payment_mode',
    'Paid through',
    options: ['cash', 'bank_transfer', 'upi', 'credit'],
  ),
  bank,
  FieldSpec('invoice_number', 'Supplier invoice', required: false),
  note,
];
