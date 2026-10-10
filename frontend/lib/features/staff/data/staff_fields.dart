import '../../shared/field_spec.dart';

const staffFields = [
  commonName,
  FieldSpec('phone', 'Phone'),
  FieldSpec('qualification', 'Qualification', required: false),
  FieldSpec('degree', 'Degree', required: false),
  FieldSpec('experience', 'Experience', required: false),
  FieldSpec(
    'role',
    'Role',
    options: ['manager', 'waiter', 'chef', 'cashier', 'cleaner'],
  ),
  FieldSpec('joining_date', 'Joining date', kind: 'date'),
  FieldSpec('monthly_salary_minor', 'Monthly salary (₹)', kind: 'money'),
  FieldSpec('is_active', 'Active staff', kind: 'bool'),
];
