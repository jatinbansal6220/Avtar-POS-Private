import 'package:flutter_test/flutter_test.dart';
import 'package:avtar_pos/core/models.dart';
import 'package:avtar_pos/features/billing/billing_calculator.dart';

void main() {
  test('billing preview rounds each amount in paise', () {
    final result = totals(
      [
        {'quantity': 2, 'price_minor': 10001},
      ],
      1000,
      500,
    );
    expect(result, {
      'subtotal_minor': 20002,
      'discount_minor': 2000,
      'tax_minor': 900,
      'total_minor': 18902,
    });
  });
  test('full discount produces zero tax and total', () {
    final result = totals(
      [
        {'quantity': 7, 'price_minor': 1099},
      ],
      10000,
      1800,
    );
    expect(result['total_minor'], 0);
    expect(result['tax_minor'], 0);
  });
  test('menu search supports short codes and small spelling mistakes', () {
    const item = {
      'name': 'Paneer Tikka',
      'short_code': 'PT01',
      'category': 'Starters',
    };
    expect(matchesMenuSearch(item, 'pt01'), isTrue);
    expect(matchesMenuSearch(item, 'paner tikka'), isTrue);
    expect(matchesMenuSearch(item, 'panner'), isTrue);
    expect(matchesMenuSearch(item, 'biryani'), isFalse);
  });
  test(
    'GST off stays zero and additional bill amounts are added after tax',
    () {
      final result = BillingCalculator.calculate(
        [
          {'quantity': 1, 'price_minor': 10000},
        ],
        {
          'discount_type': 'percent',
          'discount_value': 0,
          'additional_charges': [
            {'amount_minor': 1000, 'note': 'Packing'},
            {'amount_minor': 500},
          ],
        },
        0,
      );
      expect(result['tax_minor'], 0);
      expect(result['additional_amount_minor'], 1500);
      expect(result['total_minor'], 11500);
    },
  );
  test('GST rate is ignored unless GST is explicitly enabled', () {
    expect(
      effectiveTaxRate({'is_tax_enabled': false, 'tax_basis_points': 1800}),
      0,
    );
    expect(
      effectiveTaxRate({'is_tax_enabled': 'false', 'tax_basis_points': 1800}),
      0,
    );
    expect(
      effectiveTaxRate({'is_tax_enabled': true, 'tax_basis_points': 1800}),
      1800,
    );
  });
  test('online tender is valid for a split payment', () {
    expect(
      BillingCalculator.payments({
        'payments': [
          {'method': 'cash', 'amount_minor': 400},
          {'method': 'online', 'amount_minor': 600},
        ],
      }, 1000),
      hasLength(2),
    );
  });
  test('entered percentage is used exactly without a default discount', () {
    final items = [
      {'quantity': 1, 'price_minor': 10000},
    ];
    final onePercent = BillingCalculator.calculate(items, {
      'discount_type': 'percent',
      'discount_value': 100,
    }, 0);
    final twoPercent = BillingCalculator.calculate(items, {
      'discount_type': 'percent',
      'discount_value': 200,
    }, 0);
    expect(onePercent['bill_discount_minor'], 100);
    expect(twoPercent['bill_discount_minor'], 200);
  });
}
