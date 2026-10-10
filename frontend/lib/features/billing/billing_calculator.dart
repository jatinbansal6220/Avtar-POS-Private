import '../../core/models.dart';

/// Integer-paise calculation shared by checkout, receipts and tests.
class BillingCalculator {
  static int discount(int base, String type, int value) {
    if (value < 0 ||
        (type == 'percent' && value > 10000) ||
        (type == 'fixed' && value > base))
      throw ApiFailure(422, 'Discount exceeds the amount available.');
    return type == 'fixed' ? value : (base * value + 5000) ~/ 10000;
  }

  static Json calculate(List<Json> items, Json payment, int taxRate) {
    var subtotal = 0, itemDiscount = 0;
    for (final item in items) {
      final amount = number(item['quantity']) * number(item['price_minor']);
      subtotal += amount;
      itemDiscount += discount(
        amount,
        '${item['discount_type'] ?? 'percent'}',
        number(item['discount_value']),
      );
    }
    final billDiscount = discount(
      subtotal - itemDiscount,
      '${payment['discount_type'] ?? 'percent'}',
      number(payment['discount_value'] ?? payment['discount_basis_points']),
    );
    final tax =
        ((subtotal - itemDiscount - billDiscount) * taxRate + 5000) ~/ 10000;
    final additionalCharges = maps(payment['additional_charges']);
    final additionalAmount = additionalCharges.fold<int>(0, (total, charge) {
      final amount = number(charge['amount_minor']);
      if (amount <= 0) {
        throw ApiFailure(422, 'Additional amount must be greater than zero.');
      }
      return total + amount;
    });
    return {
      'subtotal_minor': subtotal,
      'item_discount_minor': itemDiscount,
      'bill_discount_minor': billDiscount,
      'discount_minor': itemDiscount + billDiscount,
      'tax_minor': tax,
      'additional_amount_minor': additionalAmount,
      'total_minor':
          subtotal - itemDiscount - billDiscount + tax + additionalAmount,
    };
  }

  /// Allocate rounding remainder deterministically, without losing paise.
  static List<int> splitEqual(int total, int count) {
    if (count < 2 || count > 50)
      throw ApiFailure(422, 'Choose 2–50 bill parts.');
    return List.generate(
      count,
      (index) => total ~/ count + (index < total % count ? 1 : 0),
    );
  }

  static List<Json> payments(Json payment, int total) {
    final rows = maps(payment['payments']);
    if (rows.isEmpty)
      return [
        {'method': payment['payment_method'] ?? 'cash', 'amount_minor': total},
      ];
    if (rows.any(
          (r) =>
          !['cash', 'online', 'upi', 'card', 'complimentary'].contains(r['method']) ||
              number(r['amount_minor']) < 0,
        ) ||
        rows.fold<int>(0, (sum, r) => sum + number(r['amount_minor'])) != total)
      throw ApiFailure(422, 'Payment amounts must equal the bill total.');
    return rows;
  }
}
