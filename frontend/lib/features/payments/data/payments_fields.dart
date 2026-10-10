import '../../shared/field_spec.dart';

const paymentsFields = [
  FieldSpec('staff_id', 'Staff member', kind: 'staff'),
  FieldSpec('amount_minor', 'Amount (₹)', kind: 'money'),
  FieldSpec('date', 'Payment date', kind: 'date'),
  FieldSpec(
    'payment_mode',
    'Paid through',
    options: ['cash', 'bank_transfer', 'upi'],
  ),
  bank,
  FieldSpec('note', 'Payment note', required: false),
];
