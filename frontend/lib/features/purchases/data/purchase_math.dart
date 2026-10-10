import '../../../core/models.dart';

// Quantities use thousandths; money uses paise. No floating-point totals.
int purchaseDecimal(String text, {int scale = 100}) {
  final match = RegExp(r'^\d+(?:\.\d+)?$').firstMatch(text.trim());
  if (match == null) throw ApiFailure(422, 'Enter a positive number.');
  final parts = text.trim().split('.');
  final digits = scale == 1000 ? 3 : 2;
  if (parts.length > 1 && parts[1].length > digits) {
    throw ApiFailure(422, 'Use at most $digits decimal places.');
  }
  return int.parse(parts[0]) * scale +
      int.parse((parts.length > 1 ? parts[1] : '').padRight(digits, '0'));
}

int purchaseRound(int numerator, int denominator) =>
    (numerator + denominator ~/ 2) ~/ denominator;
String purchaseQty(dynamic value) => (number(value) / 1000)
    .toStringAsFixed(3)
    .replaceFirst(RegExp(r'\.?0+$'), '');

Json purchaseTotals(Json input) {
  final bill = clone(input);
  final lines = maps(bill['lines']);
  if (lines.isEmpty || lines.length > 100) {
    throw ApiFailure(422, 'Add 1 to 100 purchase items.');
  }
  var subtotal = 0, discount = 0, tax = 0;
  final ids = <String>{};
  for (final row in lines) {
    final qty = number(row['quantity_milli']),
        price = number(row['unit_price_minor']);
    final rate = number(row['tax_basis_points']),
        cut = number(row['discount_minor']);
    if (!ids.add('${row['id']}') ||
        qty <= 0 ||
        qty > 100000000 ||
        price < 0 ||
        price > 100000000 ||
        rate < 0 ||
        rate > 2800 ||
        cut < 0 ||
        '${row['item_name'] ?? ''}'.trim().isEmpty ||
        '${row['unit'] ?? ''}'.trim().isEmpty) {
      throw ApiFailure(
        422,
        'Check item quantity, price, unit, discount and tax.',
      );
    }
    final gross = purchaseRound(qty * price, 1000);
    if (cut > gross) {
      throw ApiFailure(422, 'Discount cannot exceed the item amount.');
    }
    final gst = purchaseRound((gross - cut) * rate, 10000);
    row.addAll({
      'subtotal_minor': gross,
      'tax_minor': gst,
      'total_minor': gross - cut + gst,
    });
    subtotal += gross;
    discount += cut;
    tax += gst;
  }
  final freight = number(bill['freight_minor']);
  final total = subtotal - discount + tax + freight;
  if (freight < 0 || total > 100000000) {
    throw ApiFailure(422, 'Purchase total exceeds the allowed limit.');
  }
  bill.addAll({
    'lines': lines,
    'subtotal_minor': subtotal,
    'discount_minor': discount,
    'tax_minor': tax,
    'total_minor': total,
  });
  return bill;
}

Json purchaseBalance(Json bill, List<Json> events) {
  if(bill['status']!='received') {
    return {'paid_minor':0,'returned_minor':0,'refunded_minor':0,'net_minor':0,'due_minor':0,'credit_minor':0};
  }
  var paid = number(bill['paid_minor']), returned = 0, refunded = 0;
  for (final event in events.where((e) => e['bill_id'] == bill['id'])) {
    switch (event['kind']) {
      case 'payment':
        paid += number(event['amount_minor']);
      case 'return':
        returned += number(event['amount_minor']);
      case 'refund':
        refunded += number(event['amount_minor']);
    }
  }
  final net = number(bill['total_minor']) - returned;
  final balance = net - paid + refunded;
  return {
    'paid_minor': paid,
    'returned_minor': returned,
    'refunded_minor': refunded,
    'net_minor': net,
    'due_minor': balance > 0 ? balance : 0,
    'credit_minor': balance < 0 ? -balance : 0,
  };
}

int purchaseStock(
  String itemId,
  String unit,
  List<Json> bills,
  List<Json> events,
) {
  var quantity = 0;
  for (final bill in bills.where((b) => b['status'] == 'received')) {
    for (final row in maps(bill['lines'])) {
      if (row['purchase_item_id'] == itemId && row['unit'] == unit) {
        quantity += number(row['quantity_milli']);
      }
    }
  }
  for (final event in events) {
    for (final row in maps(event['lines'])) {
      if (row['purchase_item_id'] == itemId && row['unit'] == unit) {
        quantity +=
            (event['kind'] == 'opening' ? 1 : -1) *
            number(row['quantity_milli']);
      }
    }
  }
  return quantity;
}

Json purchaseEvent(Json input, List<Json> bills, List<Json> events) {
  final event = clone(input);
  final kind = '${event['kind']}';
  if (![
    'payment',
    'refund',
    'return',
    'opening',
    'usage',
    'waste',
  ].contains(kind)) {
    throw ApiFailure(422, 'Unknown purchase action.');
  }
  final date = '${event['date'] ?? ''}';
  if (DateTime.tryParse(date) == null || day(DateTime.parse(date)) != date) {
    throw ApiFailure(422, 'Choose a valid date.');
  }
  if (events.any((e) => e['id'] == event['id'])) {
    throw ApiFailure(409, 'This action is already saved.');
  }
  final bill = bills.where((b) => b['id'] == event['bill_id']).firstOrNull;
  if (['payment', 'refund', 'return'].contains(kind) &&
      bill?['status'] != 'received') {
    throw ApiFailure(
      422,
      'Receive this purchase before recording payments or returns.',
    );
  }
  if (['payment', 'refund', 'return'].contains(kind) &&
      bill != null &&
      date.compareTo('${bill['purchase_date']}') < 0) {
    throw ApiFailure(422, 'Action date cannot be before the purchase date.');
  }
  if (!['payment', 'refund', 'return'].contains(kind)) event['bill_id'] = null;
  if (['payment', 'refund'].contains(kind)) {
    final balance = purchaseBalance(bill!, events);
    final amount = number(event['amount_minor']);
    if (amount <= 0 ||
        amount >
            number(balance[kind == 'payment' ? 'due_minor' : 'credit_minor'])) {
      throw ApiFailure(422, 'Amount exceeds the available balance.');
    }
    if (!['cash', 'upi', 'bank_transfer'].contains(event['payment_mode'])) {
      throw ApiFailure(422, 'Choose a payment method.');
    }
    event['lines'] = <Json>[];
  } else {
    final lines = maps(event['lines']);
    if (lines.isEmpty || lines.length > 100) {
      throw ApiFailure(422, 'Add stock quantities.');
    }
    var credit = 0;
    final seen = <String>{};
    for (final line in lines) {
      var qty = number(line['quantity_milli']);
      if (qty <= 0 || qty > 100000000) {
        throw ApiFailure(422, 'Check stock quantity; combine repeated items.');
      }
      if (kind == 'return') {
        final original = maps(bill!['lines'])
            .where((r) => r['id'] == line['line_id'])
            .firstOrNull;
        if (original == null) {
          throw ApiFailure(422, 'Original purchase line was not found.');
        }
        line.addAll({
          'purchase_item_id': original['purchase_item_id'],
          'item_name': original['item_name'],
          'unit': original['unit'],
        });
        final prior = events
            .where((e) => e['kind'] == 'return' && e['bill_id'] == bill['id'])
            .expand((e) => maps(e['lines']))
            .where((r) => r['line_id'] == line['line_id'])
            .fold<int>(0, (s, r) => s + number(r['quantity_milli']));
        if (prior + qty > number(original['quantity_milli'])) {
          throw ApiFailure(
            422,
            'Return quantity exceeds the purchased quantity.',
          );
        }
        // Cumulative rounding means returning in parts cannot create extra credit.
        credit +=
            purchaseRound(
              (prior + qty) * number(original['total_minor']),
              number(original['quantity_milli']),
            ) -
            purchaseRound(
              prior * number(original['total_minor']),
              number(original['quantity_milli']),
            );
      }
      if (!seen.add('${line['purchase_item_id']}|${line['unit']}') ||
          '${line['unit'] ?? ''}'.trim().isEmpty ||
          '${line['unit']}'.length > 20) {
        throw ApiFailure(422, 'Choose a unit and combine repeated items.');
      }
      if (kind != 'opening' &&
          qty >
              purchaseAvailableStock(
                '${line['purchase_item_id']}',
                '${line['unit']}',
                bills,
                events,
                date,
              )) {
        throw ApiFailure(422, 'Not enough material stock for this action.');
      }
    }
    if ('${event['note'] ?? ''}'.trim().isEmpty) {
      throw ApiFailure(422, 'Enter a reason for this stock action.');
    }
    event['lines'] = lines;
    event['amount_minor'] = credit;
  }
  return event;
}

// A backdated debit must leave enough stock on every later ledger date, too.
int purchaseAvailableStock(
  String item,
  String unit,
  List<Json> bills,
  List<Json> events,
  String date,
) {
  final days = <String, int>{};
  for (final bill in bills.where((b) => b['status'] == 'received')) {
    for (final line in maps(bill['lines'])) {
      if (line['purchase_item_id'] == item && line['unit'] == unit) {
        days.update(
          '${bill['purchase_date']}',
          (v) => v + number(line['quantity_milli']),
          ifAbsent: () => number(line['quantity_milli']),
        );
      }
    }
  }
  for (final event in events) {
    for (final line in maps(event['lines'])) {
      if (line['purchase_item_id'] == item && line['unit'] == unit) {
        final qty =
            (event['kind'] == 'opening' ? 1 : -1) *
            number(line['quantity_milli']);
        days.update('${event['date']}', (v) => v + qty, ifAbsent: () => qty);
      }
    }
  }
  days.putIfAbsent(date, () => 0);
  var balance = 0;
  int? minimum;
  for (final key in days.keys.toList()..sort()) {
    balance += days[key]!;
    if (key.compareTo(date) >= 0) {
      minimum = minimum == null || balance < minimum ? balance : minimum;
    }
  }
  return minimum ?? 0;
}
