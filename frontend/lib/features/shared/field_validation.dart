import '../../core/models.dart';
import 'field_spec.dart';

/// Validate every field, including those outside a lazy form's viewport.
String? validateField(FieldSpec field, String? text, dynamic selected) {
  if (field.kind == 'bool') return null;
  if (field.options != null || ['staff', 'banks'].contains(field.kind)) {
    return field.required && '${selected ?? ''}'.isEmpty
        ? '${field.label} is required'
        : null;
  }
  final input = text?.trim() ?? '';
  if (input.isEmpty) {
    return field.required ? '${field.label} is required' : null;
  }
  if (['money', 'percent', 'int', 'decimal'].contains(field.kind)) {
    final number = double.tryParse(input);
    if (number == null || !number.isFinite) return 'Enter a number';
    if (field.kind == 'int' && int.tryParse(input) == null) {
      return 'Enter a whole number';
    }
  }
  if (field.kind == 'date') {
    final parsed = DateTime.tryParse(input);
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(input) ||
        parsed == null ||
        day(parsed) != input) {
      return 'Use YYYY-MM-DD';
    }
  }
  return null;
}
