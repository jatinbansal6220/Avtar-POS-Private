import 'dart:convert';

typedef Json = Map<String, dynamic>;
int number(dynamic value) =>
    value is num ? value.toInt() : int.tryParse('$value') ?? 0;
bool enabled(dynamic value) =>
    value == true ||
    value == 1 ||
    value == '1' ||
    (value is String && value.trim().toLowerCase() == 'true');

/// GST applies only when the setting is explicitly enabled. This prevents a
/// stored rate from leaking into a final bill after GST has been switched off.
int effectiveTaxRate(Json settings) => enabled(settings['is_tax_enabled'])
    ? number(settings['tax_basis_points'])
    : 0;
String money(dynamic value) => '₹${(number(value) / 100).toStringAsFixed(2)}';
Json clone(Json value) =>
    Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);
List<Json> maps(dynamic value) => (value as List? ?? [])
    .map((e) => Map<String, dynamic>.from(e as Map))
    .toList();

/// AvtarPOS is operated on India Standard Time irrespective of the phone,
/// Windows, or VPS timezone.  We keep the wall-clock values timezone-free in
/// SQLite/MySQL for compatibility with the existing DATETIME columns, while
/// all components are always calculated in Asia/Kolkata (UTC+05:30).
const indiaOffset = Duration(hours: 5, minutes: 30);
Duration _indiaClockCorrection = Duration.zero;

/// A connected terminal follows the restaurant server clock so a PC with an
/// incorrectly set Windows clock cannot create invoices at the wrong time.
/// When offline, the correction remains zero and the device clock is the safe
/// fallback required for offline-first billing.
void updateIndiaClock(dynamic rawServerTime) {
  final server = DateTime.tryParse(rawServerTime?.toString() ?? '');
  if (server == null) return;
  _indiaClockCorrection = server.toUtc().difference(DateTime.now().toUtc());
}

DateTime indiaNow() => DateTime.now()
    .toUtc()
    .add(_indiaClockCorrection)
    .add(indiaOffset);

DateTime indiaWallTime(DateTime value) => DateTime.utc(
  value.year,
  value.month,
  value.day,
  value.hour,
  value.minute,
  value.second,
  value.millisecond,
  value.microsecond,
);

/// Reads both new India wall-clock values and older ISO values that include a
/// timezone offset.  Offset-bearing values represent an instant and are
/// converted to IST; legacy values without one are already restaurant time.
DateTime? indiaDateTime(dynamic raw) {
  final text = raw?.toString().trim() ?? '';
  if (text.isEmpty) return null;
  final parsed = DateTime.tryParse(text);
  if (parsed == null) return null;
  final hasOffset = RegExp(r'(Z|[+-]\d{2}:?\d{2})$', caseSensitive: false)
      .hasMatch(text);
  return hasOffset
      ? parsed.toUtc().add(indiaOffset)
      : indiaWallTime(parsed);
}

String indiaTimestamp([DateTime? value]) {
  final time = value == null ? indiaNow() : indiaWallTime(value);
  String two(int part) => part.toString().padLeft(2, '0');
  String three(int part) => part.toString().padLeft(3, '0');
  return '${time.year.toString().padLeft(4, '0')}-${two(time.month)}-${two(time.day)}'
      'T${two(time.hour)}:${two(time.minute)}:${two(time.second)}.${three(time.millisecond)}';
}

String day(DateTime value) {
  final time = indiaWallTime(value);
  return '${time.year.toString().padLeft(4, '0')}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')}';
}

/// Menu lookup stays local so POS remains instant offline. It accepts a short
/// code, a name fragment, or a small spelling mistake in each typed word.
bool matchesMenuSearch(Json item, String value) {
  final query = _searchWords(value);
  if (query.isEmpty) return true;
  final terms = _searchWords(
    '${item['name'] ?? ''} ${item['short_code'] ?? ''} ${item['category'] ?? ''}',
  );
  return query.every(
    (word) => terms.any(
      (term) =>
          term.contains(word) ||
          word.contains(term) ||
          _editDistance(word, term) <= _allowedTypos(word.length),
    ),
  );
}

List<String> _searchWords(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
    .split(' ')
    .where((word) => word.isNotEmpty)
    .toList();

int _allowedTypos(int length) => length < 3
    ? 0
    : length < 6
    ? 1
    : 2;

int _editDistance(String left, String right) {
  if (left == right) return 0;
  if (left.isEmpty) return right.length;
  if (right.isEmpty) return left.length;
  var previous = List<int>.generate(right.length + 1, (index) => index);
  for (var row = 1; row <= left.length; row++) {
    final current = <int>[row];
    for (var column = 1; column <= right.length; column++) {
      current.add(
        [
          current[column - 1] + 1,
          previous[column] + 1,
          previous[column - 1] + (left[row - 1] == right[column - 1] ? 0 : 1),
        ].reduce((a, b) => a < b ? a : b),
      );
    }
    previous = current;
  }
  return previous.last;
}

class ApiFailure implements Exception {
  final int status;
  final String message;
  ApiFailure(this.status, this.message);
  @override
  String toString() => message;
}

/// Integer arithmetic shared by previews; final totals always come from the API.
Json totals(List<Json> items, int discountRate, int taxRate) {
  final subtotal = items.fold<int>(
    0,
    (sum, item) => sum + number(item['price_minor']) * number(item['quantity']),
  );
  final discount = (subtotal * discountRate + 5000) ~/ 10000;
  final tax = ((subtotal - discount) * taxRate + 5000) ~/ 10000;
  return {
    'subtotal_minor': subtotal,
    'discount_minor': discount,
    'tax_minor': tax,
    'total_minor': subtotal - discount + tax,
  };
}
