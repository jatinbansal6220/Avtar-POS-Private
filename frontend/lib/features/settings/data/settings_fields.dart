import '../../shared/field_spec.dart';

const settingsFields = [
  FieldSpec('restaurant_name', 'Restaurant name'),
  FieldSpec('restaurant_address', 'Address', required: false),
  FieldSpec('restaurant_phone', 'Phone', required: false),
  FieldSpec('tagline', 'Receipt footer / tagline', required: false),
  FieldSpec('gstin', 'GSTIN', required: false),
  FieldSpec('fssai_lic', 'FSSAI licence', required: false),
  FieldSpec('is_tax_enabled', 'Enable tax', kind: 'bool'),
  FieldSpec('tax_basis_points', 'GST (%)', kind: 'percent'),
  FieldSpec(
    'default_discount_basis_points',
    'Standard discount (%)',
    kind: 'percent',
  ),
  FieldSpec('printer_paper_width', 'Paper width', options: ['80mm', '58mm']),
  FieldSpec('timezone', 'Restaurant timezone'),
];
