import '../../shared/field_spec.dart';

const banksFields = [
  FieldSpec('account_name', 'Account name'),
  FieldSpec('bank_name', 'Bank / counter name'),
  FieldSpec(
    'account_type',
    'Settlement type',
    options: ['upi', 'card'],
  ),
  FieldSpec('account_number', 'UPI ID / card settlement reference', required: false),
  FieldSpec('ifsc_code', 'IFSC', required: false),
  FieldSpec('initial_balance_minor', 'Opening balance (₹)', kind: 'money'),
  FieldSpec('use_for_card', 'Use for Card', kind: 'bool'),
  FieldSpec('is_default_qr', 'Default UPI QR', kind: 'bool'),
  active,
];
