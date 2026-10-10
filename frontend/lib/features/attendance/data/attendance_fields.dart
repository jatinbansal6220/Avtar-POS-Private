import '../../shared/field_spec.dart';

const attendanceFields = [
  FieldSpec('staff_id', 'Staff member', kind: 'staff'),
  FieldSpec('date', 'Date', kind: 'date'),
  FieldSpec(
    'status',
    'Attendance',
    options: ['present', 'absent', 'half_day', 'leave'],
  ),
  note,
];
