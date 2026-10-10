import '../../core/models.dart';

/// Include quiet days so a sales graph never joins over missing calendar dates.
List<Json> dailyAnalyticsSeries(String from, String to, List<Json> rows) {
  final parsedStart = DateTime.tryParse(from),
      parsedEnd = DateTime.tryParse(to);
  if (parsedStart == null ||
      parsedEnd == null ||
      day(parsedStart) != from ||
      day(parsedEnd) != to) {
    throw ApiFailure(422, 'Choose a valid range of up to 366 days.');
  }
  final start = DateTime.utc(
    parsedStart.year,
    parsedStart.month,
    parsedStart.day,
  );
  final end = DateTime.utc(parsedEnd.year, parsedEnd.month, parsedEnd.day);
  if (end.isBefore(start) || end.difference(start).inDays >= 366) {
    throw ApiFailure(422, 'Choose a valid range of up to 366 days.');
  }
  final indexed = {for (final row in rows) '${row['day']}': row};
  return [
    for (
      var date = start;
      !date.isAfter(end);
      date = date.add(const Duration(days: 1))
    )
      {
        'day': day(date),
        'revenue_minor': number(indexed[day(date)]?['revenue_minor']),
        'bills': number(indexed[day(date)]?['bills']),
      },
  ];
}

List<Json> hourlyAnalyticsSeries(List<Json> rows) {
  final indexed = {for (final row in rows) '${row['hour']}': row};
  return [
    for (var hour = 0; hour < 24; hour++)
      {
        'hour': '${hour.toString().padLeft(2, '0')}:00',
        'revenue_minor': number(
          indexed['${hour.toString().padLeft(2, '0')}:00']?['revenue_minor'],
        ),
        'bills': number(
          indexed['${hour.toString().padLeft(2, '0')}:00']?['bills'],
        ),
      },
  ];
}
