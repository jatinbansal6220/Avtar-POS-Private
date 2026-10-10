import '../../core/models.dart';

DateTime _dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

DateTime _salaryDay(DateTime month, int joiningDay) => DateTime(
  month.year,
  month.month,
  joiningDay.clamp(1, DateTime(month.year, month.month + 1, 0).day),
);

/// Counts salary cycles from the day this staff profile was added to AvtarPOS,
/// never from a historical joining date. The joining date only supplies the
/// monthly salary day. The first salary is due on the next upcoming salary
/// day, never immediately when a historical employee is entered in the app.
int completedSalaryMonths(Json staff, {DateTime? today}) {
  final joined = indiaDateTime(staff['joining_date']);
  if (joined == null) return 0;
  final now = _dateOnly(today ?? indiaNow());
  final recorded = indiaDateTime(staff['created_at']);
  final started = _dateOnly(recorded ?? now);
  if (now.isBefore(started)) return 0;

  final joiningDay = joined.day;
  var due = _salaryDay(started, joiningDay);
  var cycles = 0;
  // A due date on (or before) the profile-creation day belongs to the old
  // manual ledger. Begin the AvtarPOS ledger from the *next* salary day.
  if (!due.isAfter(started)) {
    due = _salaryDay(DateTime(started.year, started.month + 1), joiningDay);
  }
  while (!due.isAfter(now) && cycles < 1200) {
    cycles++;
    due = _salaryDay(DateTime(due.year, due.month + 1), joiningDay);
  }
  return cycles;
}

int staffSalaryAccrued(Json staff, {DateTime? today}) =>
    number(staff['monthly_salary_minor']) *
    completedSalaryMonths(staff, today: today);

/// Attendance is preserved permanently. This returns only the rupee deduction
/// for one completed calendar month: one absent is a full daily rate and one
/// half day is half that rate. Dates before the staff profile was created are
/// ignored because AvtarPOS starts accounting from that date.
int attendanceSalaryDeductionForMonth(
  Json staff,
  Iterable<Json> attendance,
  DateTime month,
) {
  final started = indiaDateTime(staff['created_at']);
  final monthly = number(staff['monthly_salary_minor']);
  if (monthly <= 0) return 0;
  final days = DateTime(month.year, month.month + 1, 0).day;
  var halfDayUnits = 0;
  for (final row in attendance) {
    if ('${row['staff_id']}' != '${staff['id']}') continue;
    final date = indiaDateTime(row['date']);
    if (date == null || date.year != month.year || date.month != month.month) {
      continue;
    }
    if (started != null && _dateOnly(date).isBefore(_dateOnly(started))) {
      continue;
    }
    if (row['status'] == 'absent') halfDayUnits += 2;
    if (row['status'] == 'half_day') halfDayUnits += 1;
  }
  return (monthly * halfDayUnits / (days * 2)).round();
}

/// Applies attendance cuts only for fully completed calendar months. A current
/// month's deduction is shown after month-end, then reduces the next due
/// salary; no attendance entry is edited or deleted.
int staffAttendanceSalaryDeduction(
  Json staff,
  Iterable<Json> attendance, {
  DateTime? today,
}) {
  final now = _dateOnly(today ?? indiaNow());
  final started = indiaDateTime(staff['created_at']);
  if (started == null) return 0;
  var cursor = DateTime(started.year, started.month);
  final lastCompleted = DateTime(now.year, now.month - 1);
  var total = 0;
  while (!cursor.isAfter(lastCompleted)) {
    total += attendanceSalaryDeductionForMonth(staff, attendance, cursor);
    cursor = DateTime(cursor.year, cursor.month + 1);
  }
  return total;
}
