import '../../shared/field_spec.dart';

const menuFields = [
  commonName,
  price,
  FieldSpec('category', 'Category'),
  FieldSpec('short_code', 'Short code', required: false),
  FieldSpec('description', 'Description', required: false),
  FieldSpec('image_url', 'Image URL (HTTPS, optional)', required: false),
  active,
  FieldSpec('is_veg', 'Vegetarian', kind: 'bool'),
];
