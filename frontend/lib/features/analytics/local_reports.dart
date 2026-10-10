import 'dart:convert';

import '../../core/local_store.dart';
import '../../core/models.dart';

/// Reports query only persisted bills/menu data. SQLite performs aggregation;
/// invoice collections are never materialized on the UI isolate.
class LocalReports {
  final LocalStore store;
  LocalReports(this.store);

  /// Current open carts are separate from finalized sales for the period.
  /// Drafts win, merged children never contribute another copy of the cart.
  Future<Json> openOrderSummary() async {
    final records = await store.db.query(
      'records',
      columns: ['id', 'status', 'body'],
      where: "resource='orders' AND (status='open' OR id IN (SELECT id FROM drafts))",
    );
    final saved = {for (final row in records) '${row['id']}': row};
    final orders = {
      for (final row in records)
        '${row['id']}': jsonDecode(row['body'] as String) as Json,
    };
    for (final draft in await store.drafts()) {
      final id = '${draft['id']}';
      if (saved[id] != null && saved[id]!['status'] != 'open') continue;
      orders[id] = draft;
    }
    final tables = {
      for (final table in await store.listAll('tables'))
        '${table['id']}': table,
    };
    var count = 0, amount = 0;
    for (final order in orders.values) {
      if (order['status'] != 'open' ||
          '${order['merged_into_order_id'] ?? ''}'.isNotEmpty) {
        continue;
      }
      final current =
          '${tables['${order['table_id']}']?['current_order_id'] ?? ''}';
      if (current.isNotEmpty && current != '${order['id']}') continue;
      final items = maps(order['items']);
      if (items.isEmpty) continue;
      count++;
      amount += items.fold<int>(
        0,
        (sum, item) =>
            sum + number(item['quantity']) * number(item['price_minor']),
      );
    }
    return {'orders': count, 'items_subtotal_minor': amount};
  }

  static const billDate =
      "substr(COALESCE(json_extract(body,'\$.generated_at'),json_extract(body,'\$.receipt.generated_at'),json_extract(body,'\$.date')),1,10)";
  static const generatedAt =
      "COALESCE(json_extract(body,'\$.generated_at'),json_extract(body,'\$.receipt.generated_at'),json_extract(body,'\$.date'))";

  Future<Json> _summary(String from, String to) async {
    const fields = [
      'subtotal_minor',
      'total_minor',
      'tax_minor',
      'discount_minor',
    ];
    final aggregates = fields
        .map(
          (field) =>
              "COALESCE(SUM(json_extract(body,char(36)||'.$field')),0) $field",
        )
        .join(',');
    final row = (await store.db.rawQuery(
      "SELECT COUNT(*) bills, $aggregates FROM records WHERE resource='bills' AND $billDate BETWEEN ? AND ?",
      [from, to],
    )).single;
    return {...row, 'revenue_minor': row['total_minor']};
  }

  (String, String) _previousRange(String from, String to) {
    final start = DateTime.parse('${from}T00:00:00Z');
    final end = DateTime.parse('${to}T00:00:00Z');
    final days = end.difference(start).inDays + 1;
    final previousEnd = start.subtract(const Duration(days: 1));
    return (
      day(previousEnd.subtract(Duration(days: days - 1))),
      day(previousEnd),
    );
  }

  Future<Json> analytics(String from, String to) async {
    if (DateTime.tryParse(from) == null ||
        DateTime.tryParse(to) == null ||
        from.compareTo(to) > 0) {
      throw ApiFailure(422, 'Choose a valid date range.');
    }
    final summary = await _summary(from, to);
    final previousRange = _previousRange(from, to);
    final previous = await _summary(previousRange.$1, previousRange.$2);
    final now = indiaNow();
    final today = day(now);
    final todayItems = await items(today, today);
    final weekItems = await items(
      day(now.subtract(Duration(days: now.weekday - 1))),
      today,
    );
    final menu = await store.db.rawQuery(
      "SELECT id,name FROM records WHERE resource='menu_items' AND COALESCE(json_extract(body,'\$.is_active'),1)=1",
    );
    final quantities = {
      for (final row in todayItems) row['item_id']: row['quantity'],
    };
    final least =
        menu
            .map(
              (r) => <String, dynamic>{
                'name': r['name'],
                'quantity': quantities[r['id']] ?? 0,
              },
            )
            .toList()
          ..sort((a, b) {
            final comparison = number(a['quantity'])
                .compareTo(number(b['quantity']));
            return comparison == 0
                ? '${a['name']}'.compareTo('${b['name']}')
                : comparison;
          });
    final tables = await store.db.rawQuery(
      "SELECT COALESCE(NULLIF(json_extract(body,'\$.table_number'),''),NULLIF(json_extract(body,'\$.receipt.table_number'),''),'POS / Takeaway') table_number, COUNT(*) orders, SUM(json_extract(body,'\$.total_minor')) revenue_minor FROM records WHERE resource='bills' AND $billDate BETWEEN ? AND ? GROUP BY table_number ORDER BY revenue_minor DESC",
      [from, to],
    );
    final daily = await store.db.rawQuery(
      "SELECT $billDate day, COUNT(*) bills, COALESCE(SUM(json_extract(body,'\$.total_minor')),0) revenue_minor FROM records WHERE resource='bills' AND $billDate BETWEEN ? AND ? GROUP BY day ORDER BY day",
      [from, to],
    );
    final channels = await store.db.rawQuery(
      """
      SELECT CASE
        WHEN COALESCE(json_extract(body,'\$.order_type'),json_extract(body,'\$.receipt.order_type'),'dine_in')='online'
          THEN COALESCE(NULLIF(json_extract(body,'\$.online_platform_name'),''),NULLIF(json_extract(body,'\$.online_platform'),''),'Online')
        WHEN COALESCE(json_extract(body,'\$.order_type'),json_extract(body,'\$.receipt.order_type'),'dine_in')='takeaway' THEN 'Takeaway'
        WHEN COALESCE(json_extract(body,'\$.order_type'),json_extract(body,'\$.receipt.order_type'),'dine_in')='pos' THEN 'Menu POS'
        ELSE 'Dine in' END channel,
        COUNT(*) orders, SUM(json_extract(body,'\$.total_minor')) revenue_minor
      FROM records WHERE resource='bills' AND $billDate BETWEEN ? AND ?
      GROUP BY channel ORDER BY revenue_minor DESC
    """,
      [from, to],
    );
    final payments = await store.db.rawQuery(
      """
      SELECT CASE WHEN LOWER(COALESCE(NULLIF(json_extract(payment.value,'\$.method'),''),'cash')) IN ('upi','online','card')
          THEN 'Online payment' ELSE 'Offline payment' END method,
        COUNT(DISTINCT records.id) orders,
        COALESCE(SUM(COALESCE(json_extract(payment.value,'\$.amount_minor'),0)),0) revenue_minor
      FROM records, json_each(
        CASE WHEN json_array_length(COALESCE(json_extract(body,'\$.payments'),json_extract(body,'\$.receipt.payments'),'[]')) > 0
          THEN COALESCE(json_extract(body,'\$.payments'),json_extract(body,'\$.receipt.payments'))
          ELSE json_array(json_object(
            'method',COALESCE(json_extract(body,'\$.payment_method'),json_extract(body,'\$.receipt.payment_method'),'cash'),
            'amount_minor',COALESCE(json_extract(body,'\$.total_minor'),json_extract(body,'\$.receipt.total_minor'),0)
          )) END
      ) payment
      WHERE resource='bills' AND $billDate BETWEEN ? AND ? GROUP BY method ORDER BY revenue_minor DESC
    """,
      [from, to],
    );
    final discounts = await store.db.rawQuery(
      """
      SELECT CASE COALESCE(json_extract(body,'\$.discount_display_type'),json_extract(body,'\$.receipt.discount_display_type'),json_extract(body,'\$.discount_type'),json_extract(body,'\$.receipt.discount_type'),'')
        WHEN 'minus' THEN 'Minus amount'
        WHEN 'fixed' THEN 'Fixed discount'
        WHEN 'percent' THEN 'Percentage discount'
        ELSE 'Discount' END type,
        COUNT(*) orders,
        SUM(COALESCE(json_extract(body,'\$.discount_minor'),json_extract(body,'\$.receipt.discount_minor'),0)) discount_minor
      FROM records
      WHERE resource='bills' AND $billDate BETWEEN ? AND ?
        AND COALESCE(json_extract(body,'\$.discount_minor'),json_extract(body,'\$.receipt.discount_minor'),0)>0
      GROUP BY type ORDER BY discount_minor DESC
    """,
      [from, to],
    );
    final hourly = await store.db.rawQuery(
      """
      SELECT CASE WHEN length($generatedAt) >= 13 THEN substr($generatedAt,12,2)||':00' ELSE 'Unspecified' END hour,
        COUNT(*) bills, SUM(json_extract(body,'\$.total_minor')) revenue_minor
      FROM records WHERE resource='bills' AND $billDate BETWEEN ? AND ?
      GROUP BY hour ORDER BY hour
    """,
      [from, to],
    );
    final cashiers = await store.db.rawQuery(
      """
      SELECT COALESCE(NULLIF(json_extract(body,'\$.cashier_name'),''),NULLIF(json_extract(body,'\$.receipt.cashier_name'),''),'Unassigned') cashier,
        COUNT(*) bills, SUM(json_extract(body,'\$.total_minor')) revenue_minor
      FROM records WHERE resource='bills' AND $billDate BETWEEN ? AND ?
      GROUP BY cashier ORDER BY revenue_minor DESC
    """,
      [from, to],
    );
    final voids = await store.db.rawQuery(
      """
      SELECT COALESCE(json_extract(void.value,'\$.item_name'),'Unnamed item') name,
        SUM(json_extract(void.value,'\$.quantity')) quantity,
        SUM(json_extract(void.value,'\$.quantity') * json_extract(void.value,'\$.price_minor')) revenue_minor
      FROM records, json_each(COALESCE(json_extract(body,'\$.voids'),json_extract(body,'\$.receipt.voids'),'[]')) void
      WHERE resource='bills' AND $billDate BETWEEN ? AND ?
      GROUP BY name ORDER BY revenue_minor DESC
    """,
      [from, to],
    );
    final legacyPurchase = (await store.db.rawQuery(
      """
      SELECT COUNT(*) entries, COALESCE(SUM(json_extract(body,'\$.total_minor')),0) spend_minor
      FROM records WHERE resource='purchases' AND substr(json_extract(body,'\$.purchase_date'),1,10) BETWEEN ? AND ?
    """,
      [from, to],
    )).single;
    final posted = (await store.db.rawQuery(
      "SELECT COUNT(*) entries, COALESCE(SUM(json_extract(body,'\$.total_minor')),0) spend_minor FROM records WHERE resource='purchase_bills' AND status='received' AND json_extract(body,'\$.purchase_date') BETWEEN ? AND ?",
      [from, to],
    )).single;
    final returns = (await store.db.rawQuery(
      "SELECT COALESCE(SUM(json_extract(body,'\$.amount_minor')),0) amount FROM records WHERE resource='purchase_events' AND json_extract(body,'\$.kind')='return' AND json_extract(body,'\$.date') BETWEEN ? AND ?",
      [from, to],
    )).single;
    final purchase = {
      'entries': number(legacyPurchase['entries']) + number(posted['entries']),
      'spend_minor':
          number(legacyPurchase['spend_minor']) +
          number(posted['spend_minor']) -
          number(returns['amount']),
    };
    return {
      'summary': summary,
      'previous': previous,
      'previous_from': previousRange.$1,
      'previous_to': previousRange.$2,
      'purchase': purchase,
      'top_today': todayItems.firstOrNull,
      'least_today': least.firstOrNull,
      'top_week': weekItems.firstOrNull,
      'items': await items(from, to),
      'tables': tables,
      'daily': daily,
      'channels': channels,
      'payments': payments,
      'discounts': discounts,
      'hourly': hourly,
      'cashiers': cashiers,
      'voids': voids,
    };
  }

  Future<List<Json>> items(String from, String to) async => maps(
    await store.db.rawQuery(
      """
    SELECT COALESCE(json_extract(item.value,'\$.menu_item_id'), json_extract(item.value,'\$.combo_id'),json_extract(item.value,'\$.item_name')) item_id,
    json_extract(item.value,'\$.item_name') name, SUM(json_extract(item.value,'\$.quantity')) quantity,
    SUM(json_extract(item.value,'\$.quantity') * json_extract(item.value,'\$.price_minor')) revenue_minor
    FROM records, json_each(COALESCE(json_extract(body,'\$.receipt.items'),json_extract(body,'\$.items'),'[]')) item
    WHERE resource='bills' AND $billDate BETWEEN ? AND ?
    GROUP BY item_id ORDER BY quantity DESC,name
  """,
      [from, to],
    ),
  );

  /// Tally-style invoice ledger. Amounts are allocated from each tender row,
  /// so a split bill contributes its cash/UPI/online portions once each rather
  /// than incorrectly counting the full bill in every payment card.
  Future<Json> dayReport(
    String from,
    String to, {
    int offset = 0,
    String paymentScope = 'all',
  }) async {
    if (DateTime.tryParse(from) == null ||
        DateTime.tryParse(to) == null ||
        from.compareTo(to) > 0) {
      throw ApiFailure(422, 'Choose a valid date range.');
    }
    if (!const {
      'all',
      'cash',
      'upi',
      'card',
      'online',
      'split',
    }.contains(paymentScope)) {
      throw ApiFailure(422, 'Choose a valid payment report.');
    }
    const pageSize = 100;
    // The cashbook cards must cover the entire selected period. Detailed
    // invoice tiles below remain paginated, but their account/payment totals
    // are never based on only the first visible page.
    final allRecords = await store.db.rawQuery(
      "SELECT id, body FROM records WHERE resource='bills' AND $billDate BETWEEN ? AND ? ORDER BY $generatedAt DESC, id DESC",
      [from, to],
    );
    final allRows = allRecords.map((row) {
      final body = jsonDecode(row['body'] as String);
      return Map<String, dynamic>.from(body as Map);
    }).toList();

    List<Json> tendersFor(Json bill) {
      final receipt = bill['receipt'] is Map
          ? Map<String, dynamic>.from(bill['receipt'] as Map)
          : bill;
      final method =
          '${receipt['payment_method'] ?? bill['payment_method'] ?? 'cash'}'
              .toLowerCase();
      final total = number(receipt['total_minor'] ?? bill['total_minor']);
      final saved = maps(receipt['payments'] ?? bill['payments']);
      return saved.isEmpty
          ? [
              {'method': method, 'amount_minor': total},
            ]
          : saved;
    }

    bool inScope(Json bill) {
      if (paymentScope == 'all') return true;
      final tenders = tendersFor(bill)
          .where((row) => number(row['amount_minor']) > 0)
          .toList();
      if (paymentScope == 'split') return tenders.length > 1;
      return tenders.any(
        (row) => '${row['method'] ?? ''}'.toLowerCase() == paymentScope,
      );
    }

    final filteredRows = allRows.where(inScope).toList();
    final rows = filteredRows.skip(offset).take(pageSize).toList();
    // Card totals always cover the complete selected date range, even when
    // the cashier is currently looking inside one payment card.
    final scopeTotals = <String, Json>{
      for (final scope in ['all', 'cash', 'upi', 'card', 'online', 'split'])
        scope: {'orders': 0, 'amount_minor': 0},
    };
    for (final bill in allRows) {
      final receipt = bill['receipt'] is Map
          ? Map<String, dynamic>.from(bill['receipt'] as Map)
          : bill;
      final total = number(receipt['total_minor'] ?? bill['total_minor']);
      scopeTotals['all']!['orders'] = number(scopeTotals['all']!['orders']) + 1;
      scopeTotals['all']!['amount_minor'] =
          number(scopeTotals['all']!['amount_minor']) + total;
      final tenders = tendersFor(bill)
          .where((row) => number(row['amount_minor']) > 0)
          .toList();
      for (final scope in ['cash', 'upi', 'card', 'online']) {
        final amount = tenders
            .where((row) => '${row['method'] ?? ''}'.toLowerCase() == scope)
            .fold<int>(0, (sum, row) => sum + number(row['amount_minor']));
        if (amount > 0) {
          scopeTotals[scope]!['orders'] =
              number(scopeTotals[scope]!['orders']) + 1;
          scopeTotals[scope]!['amount_minor'] =
              number(scopeTotals[scope]!['amount_minor']) + amount;
        }
      }
      if (tenders.length > 1) {
        scopeTotals['split']!['orders'] =
            number(scopeTotals['split']!['orders']) + 1;
        scopeTotals['split']!['amount_minor'] =
            number(scopeTotals['split']!['amount_minor']) +
            tenders.fold<int>(
              0,
              (sum, row) => sum + number(row['amount_minor']),
            );
      }
    }
    final methods = <String, Json>{};
    final accounts = <String, Json>{};
    final audit = <Json>[];
    var gross = 0, discounts = 0, tax = 0, additional = 0, complimentary = 0;
    for (final bill in filteredRows) {
      final receipt = bill['receipt'] is Map
          ? Map<String, dynamic>.from(bill['receipt'] as Map)
          : bill;
      final total = number(receipt['total_minor'] ?? bill['total_minor']);
      gross += total;
      discounts += number(receipt['discount_minor'] ?? bill['discount_minor']);
      tax += number(receipt['tax_minor'] ?? bill['tax_minor']);
      additional += number(
        receipt['additional_amount_minor'] ?? bill['additional_amount_minor'],
      );
      final displayType = '${receipt['discount_display_type'] ?? ''}';
      final method =
          '${receipt['payment_method'] ?? bill['payment_method'] ?? 'cash'}';
      if (displayType == 'charges_not_applicable' ||
          method == 'complimentary') {
        complimentary += number(
          receipt['bill_discount_minor'] ?? receipt['discount_minor'],
        );
      }
      var tenders = maps(receipt['payments'] ?? bill['payments']);
      if (tenders.isEmpty) {
        tenders = [
          {'method': method, 'amount_minor': total},
        ];
      }
      final includedMethods = <String>{};
      for (final tender in tenders) {
        final tenderMethod = '${tender['method'] ?? method}'.toLowerCase();
        final amount = number(tender['amount_minor']);
        if (paymentScope != 'all' &&
            paymentScope != 'split' &&
            tenderMethod != paymentScope) {
          continue;
        }
        final label = switch (tenderMethod) {
          'cash' => 'Cash',
          'upi' => 'UPI',
          'online' => 'Online payment',
          'card' => 'Card',
          'complimentary' => 'Charges not applicable',
          _ => tenderMethod.isEmpty ? 'Cash' : tenderMethod,
        };
        final group = methods.putIfAbsent(
          label,
          () => {'method': label, 'orders': 0, 'amount_minor': 0},
        );
        group['amount_minor'] = number(group['amount_minor']) + amount;
        if (includedMethods.add(label)) {
          group['orders'] = number(group['orders']) + 1;
        }
        if (['upi', 'online', 'card'].contains(tenderMethod) && amount > 0) {
          // Split tenders can contain both a Card and a UPI payment. Their
          // collection must land in their own account cards, not all under
          // the first generic bank name saved on the receipt.
          final accountName = tenderMethod == 'upi'
              ? '${receipt['qr_bank_account_name'] ?? receipt['bank_account_name'] ?? 'Unassigned UPI account'}'
              : '${receipt['bank_account_name'] ?? receipt['qr_bank_account_name'] ?? 'Unassigned Card account'}';
          final account = accounts.putIfAbsent(
            accountName,
            () => {'account_name': accountName, 'orders': 0, 'amount_minor': 0},
          );
          account['amount_minor'] = number(account['amount_minor']) + amount;
          if (includedMethods.add('bank:$accountName')) {
            account['orders'] = number(account['orders']) + 1;
          }
        }
      }
      for (final edit in maps(receipt['settlement_edits'])) {
        audit.add({
          ...edit,
          'bill_id': bill['id'],
          'bill_number': receipt['bill_number'] ?? bill['bill_number'],
          'table_number': receipt['table_number'] ?? bill['table_number'],
        });
      }
    }
    Json ledgerRow(Json bill) {
      final receipt = bill['receipt'] is Map
          ? Map<String, dynamic>.from(bill['receipt'] as Map)
          : bill;
      final paymentMethod =
          '${receipt['payment_method'] ?? bill['payment_method'] ?? 'cash'}'
              .toLowerCase();
      final tenders = tendersFor(bill);
      final scopedTenderTotal = paymentScope == 'all' || paymentScope == 'split'
          ? tenders.fold<int>(
              0,
              (sum, tender) => sum + number(tender['amount_minor']),
            )
          : tenders
                .where(
                  (tender) =>
                      '${tender['method'] ?? ''}'.toLowerCase() == paymentScope,
                )
                .fold<int>(
                  0,
                  (sum, tender) => sum + number(tender['amount_minor']),
                );
      return {
        'id': bill['id'],
        'bill_number': receipt['bill_number'] ?? bill['bill_number'],
        'generated_at': receipt['generated_at'] ?? bill['generated_at'],
        'table_number': receipt['table_number'] ?? bill['table_number'],
        'customer_name': receipt['customer_name'] ?? bill['customer_name'],
        'order_type': receipt['order_type'] ?? bill['order_type'],
        'total_minor': receipt['total_minor'] ?? bill['total_minor'],
        'report_amount_minor': scopedTenderTotal,
        'discount_minor': receipt['discount_minor'] ?? bill['discount_minor'],
        'payment_method': receipt['payment_method'] ?? bill['payment_method'],
        'payments': receipt['payments'] ?? bill['payments'],
        'bank_account_name': paymentMethod == 'upi'
            ? receipt['qr_bank_account_name'] ?? receipt['bank_account_name']
            : receipt['bank_account_name'] ?? receipt['qr_bank_account_name'],
        'discount_display_type': receipt['discount_display_type'],
        'settlement_remark': receipt['settlement_remark'],
        'settlement_edits': receipt['settlement_edits'] ?? const <Json>[],
      };
    }

    final ledger = rows.map(ledgerRow).toList();
    final exportLedger = filteredRows.map(ledgerRow).toList();
    final paymentTotal = paymentScope == 'all'
        ? gross
        : exportLedger.fold<int>(
            0,
            (sum, row) => sum + number(row['report_amount_minor']),
          );
    return {
      'from': from,
      'to': to,
      'open_orders_now': await openOrderSummary(),
      'summary': {
        'bills': filteredRows.length,
        'revenue_minor': gross,
        'payment_total_minor': paymentTotal,
        'discount_minor': discounts,
        'tax_minor': tax,
        'additional_amount_minor': additional,
        'complimentary_minor': complimentary,
      },
      'payments': methods.values.toList()
        ..sort(
          (a, b) =>
              number(b['amount_minor']).compareTo(number(a['amount_minor'])),
        ),
      'accounts': accounts.values.toList()
        ..sort(
          (a, b) =>
              number(b['amount_minor']).compareTo(number(a['amount_minor'])),
        ),
      'audit': audit
        ..sort((a, b) => '${b['edited_at']}'.compareTo('${a['edited_at']}')),
      'ledger': ledger,
      // Export receives the complete selected scope, while the screen remains
      // paginated and smooth for long operating periods.
      'export_ledger': exportLedger,
      'payment_scope': paymentScope,
      'scope_totals': scopeTotals,
      'next_offset': offset + pageSize < filteredRows.length
          ? offset + pageSize
          : null,
    };
  }

  /// Closing totals include mixed tender allocations exactly once per bill.
  Future<Json> closing(String date) async {
    final report = await analytics(date, date);
    final payments = await store.db.rawQuery(
      """
      SELECT json_extract(payment.value,'\$.method') method,
      SUM(json_extract(payment.value,'\$.amount_minor')) amount_minor
      FROM records, json_each(COALESCE(json_extract(body,'\$.payments'),json_extract(body,'\$.receipt.payments'),
        json_array(json_object('method',COALESCE(json_extract(body,'\$.payment_method'),'cash'),'amount_minor',json_extract(body,'\$.total_minor'))))) payment
      WHERE resource='bills' AND $billDate=? GROUP BY method
    """,
      [date],
    );
    return {
      'date': date,
      ...report['summary'] as Map<String, dynamic>,
      'payments': payments,
    };
  }
}
