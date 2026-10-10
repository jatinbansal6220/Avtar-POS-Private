class FieldSpec {
  final String key, label, kind;
  final List<String>? options;
  final bool required;
  const FieldSpec(
    this.key,
    this.label, {
    this.kind = 'text',
    this.options,
    this.required = true,
  });
}

const commonName = FieldSpec('name', 'Name');
const active = FieldSpec('is_active', 'Available', kind: 'bool');
const price = FieldSpec('price_minor', 'Selling price (₹)', kind: 'money');
const note = FieldSpec('notes', 'Notes', required: false);
const bank = FieldSpec(
  'bank_account_id',
  'Bank / cash account',
  kind: 'banks',
  required: false,
);
