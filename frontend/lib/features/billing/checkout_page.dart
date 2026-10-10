import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/session.dart';
import '../../ui/receipt.dart';
import '../../ui/shared.dart' show secondaryText;
import 'billing_calculator.dart';

/// Local checkout supports discounts, bill shares and mixed tender settlement.
class CheckoutPage extends StatefulWidget {
  final Session session;
  final Json order;
  const CheckoutPage(this.session, this.order, {super.key});
  @override
  State<CheckoutPage> createState() => _CheckoutPageState();
}

class _CheckoutPageState extends State<CheckoutPage> {
  final discount = TextEditingController(text: '0'),
      custom = TextEditingController(),
      count = TextEditingController(text: '2'),
      additional = TextEditingController(),
      cashReceived = TextEditingController(),
      settlementRemark = TextEditingController();
  final amounts = {
    for (final mode in ['cash', 'card', 'upi'])
      mode: TextEditingController(text: '0'),
  };
  final additionalCharges = <Json>[];
  String discountType = 'percent', paymentMethod = 'cash', split = 'none';
  Json settings = {};
  List<Json> banks = [];
  String? bankId;
  String? qrBankId;
  String? error;
  bool submitting = false;
  List<Json> joinedOrders = [];
  Json activeOrder = {};
  bool loaded = false;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() {
      loaded = false;
      error = null;
    });
    try {
      final values = await Future.wait([
        widget.session.local!.list('settings', limit: 1),
        widget.session.local!.list('banks', limit: 500),
        widget.session.local!.drafts(),
      ]);
      final value = values[0].firstOrNull ?? <String, dynamic>{};
      final activeBanks = values[1]
          .where((bank) => enabled(bank['is_active']))
          .toList();
      final cardBanks = activeBanks.where(isCardSettlementAccount).toList();
      final selectedBank = cardBanks.firstOrNull;
      final qrBanks = activeBanks
          .where(
            (bank) =>
                isUpiSettlementAccount(bank) &&
                '${bank['qr_image_base64'] ?? ''}'.trim().isNotEmpty,
          )
          .toList();
      final defaultQrBank = qrBanks
          .where((bank) => enabled(bank['is_default_qr']))
          .firstOrNull;
      final savedOpenOrders = List<Json>.from(values[2]);
      // A joined child table can still have its own draft. Always resolve the
      // primary order before checkout so billing from either table opens the
      // same complete joint receipt.
      // The workspace writes every tap into `drafts` before opening checkout,
      // while the durable `orders` record can deliberately be an older Saved
      // Order snapshot. Billing must always prefer that newest draft (or the
      // in-memory workspace passed by the caller), otherwise recent lines can
      // disappear from the Generate Bill screen.
      final draftById = <String, Json>{
        for (final draft in savedOpenOrders) '${draft['id']}': draft,
      };
      var primaryOrder =
          draftById['${widget.order['id']}'] ?? clone(widget.order);
      final mergedInto = '${primaryOrder['merged_into_order_id'] ?? ''}'.trim();
      if (mergedInto.isNotEmpty) {
        primaryOrder =
            draftById[mergedInto] ??
            await widget.session.local!.get('orders', mergedInto) ??
            primaryOrder;
      }
      final primaryId = '${primaryOrder['id']}';
      // A previous build may have left the primary order with stale merge
      // metadata. Child orders still carry their immutable parent link, so
      // discover them as a second source of truth before a bill is prepared.
      final linkedChildIds = savedOpenOrders
          .where(
            (candidate) =>
                '${candidate['id']}' != primaryId &&
                ('${candidate['merged_into_order_id'] ?? ''}' == primaryId ||
                    List<String>.from(
                      candidate['merged_order_ids'] ?? const <String>[],
                    ).contains(primaryId)),
          )
          .map((candidate) => '${candidate['id']}')
          .toList();
      final orderIds = <String>{
        primaryId,
        ...List<String>.from(primaryOrder['merged_order_ids'] ?? const []),
        ...linkedChildIds,
      }.toList();
      final orders = <Json>[];
      for (final orderId in orderIds) {
        // The primary table is already the checkout source. Its snapshot is a
        // safe fallback while SQLite finishes an incoming sync transaction.
        final order =
            draftById[orderId] ??
            (orderId == '${primaryOrder['id']}'
                ? primaryOrder
                : await widget.session.local!.get('orders', orderId));
        if (order != null && order['status'] == 'open') {
          orders.add(order);
        }
      }
      if (mounted) {
        setState(() {
          settings = value;
          banks = activeBanks;
          bankId = selectedBank?['id']?.toString();
          qrBankId =
              (defaultQrBank ??
                      (qrBanks.length == 1 ? qrBanks.first : null))?['id']
                  ?.toString();
          activeOrder = primaryOrder;
          joinedOrders = orders;
          loaded = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '$e';
          loaded = false;
        });
      }
    }
  }

  @override
  void dispose() {
    for (final field in [
      discount,
      custom,
      count,
      additional,
      settlementRemark,
      cashReceived,
      ...amounts.values,
    ]) {
      field.dispose();
    }
    super.dispose();
  }

  bool isUpiSettlementAccount(Json bank) =>
      ['upi', 'upi_merchant'].contains('${bank['account_type'] ?? ''}');
  bool isCardSettlementAccount(Json bank) {
    final type = '${bank['account_type'] ?? ''}';
    // The owner explicitly controls whether a bank account appears under the
    // Card payment method. Legacy dedicated-card records remain usable.
    if (bank.containsKey('use_for_card')) return enabled(bank['use_for_card']);
    return ['card', 'current', 'savings', 'cash_drawer'].contains(type);
  }

  List<Json> get cardBanks => banks.where(isCardSettlementAccount).toList();
  bool get needsCardAccount =>
      paymentMethod == 'card' ||
      (paymentMethod == 'mixed' &&
          (double.tryParse(amounts['card']!.text) ?? 0) > 0);
  bool get needsQr =>
      paymentMethod == 'upi' ||
      (paymentMethod == 'mixed' &&
          (double.tryParse(amounts['upi']!.text) ?? 0) > 0);
  bool get needsBank => needsCardAccount || needsQr;
  String? get selectedBankId => paymentMethod == 'upi'
      ? qrBankId
      : needsCardAccount
      ? bankId
      : needsQr
      ? qrBankId
      : null;
  List<Json> get qrBanks => banks
      .where(
        (bank) =>
            isUpiSettlementAccount(bank) &&
            '${bank['qr_image_base64'] ?? ''}'.trim().isNotEmpty,
      )
      .toList();
  Json? get selectedQrBank => qrBankId == null
      ? null
      : qrBanks.where((bank) => '${bank['id']}' == qrBankId).firstOrNull;
  Json get checkoutOrder => activeOrder.isEmpty ? widget.order : activeOrder;

  /// "Minus amount" is intentionally stored as a fixed rupee discount.
  /// This preserves compatibility with existing local/server bill records while
  /// giving the cashier a clearer settlement-oriented label in the UI.
  bool get chargesNotApplicable => discountType == 'charges_not_applicable';

  int? get cashReceivedMinor {
    final value = cashReceived.text.trim();
    if (!RegExp(r'^\d+(\.\d{1,2})?$').hasMatch(value)) return null;
    final parts = value.split('.');
    final rupees = int.tryParse(parts.first);
    if (rupees == null || rupees > 100000000) return null;
    return rupees * 100 +
        (parts.length == 1 ? 0 : int.parse(parts[1].padRight(2, '0')));
  }

  String? cashError(int total) {
    if (chargesNotApplicable ||
        paymentMethod != 'cash' ||
        cashReceived.text.trim().isEmpty) {
      return null;
    }
    final received = cashReceivedMinor;
    if (received == null) {
      return 'Enter a valid cash amount (up to two decimal places).';
    }
    if (received < total) return 'Cash remaining: ${money(total - received)}';
    return null;
  }

  String? paymentError(int total) {
    final cash = cashError(total);
    if (cash != null) return cash;
    if (chargesNotApplicable || paymentMethod != 'mixed') return null;
    var paid = 0;
    for (final field in amounts.values) {
      final amount = double.tryParse(field.text.trim());
      if (amount == null ||
          !amount.isFinite ||
          amount < 0 ||
          amount > 100000000) {
        return 'Enter valid split payment amounts.';
      }
      paid += (amount * 100).round();
    }
    if (paid < total) return 'Payment remaining: ${money(total - paid)}';
    if (paid > total) return 'Payment exceeds bill by ${money(paid - total)}';
    return null;
  }

  /// A complimentary/family settlement is stored as a fixed discount equal
  /// to the eligible item total, while its visible type and audit remark stay
  /// on the saved receipt.
  int get chargesNotApplicableDiscount {
    var eligible = 0;
    for (final item in maps(billingOrder['items'])) {
      final line = number(item['quantity']) * number(item['price_minor']);
      eligible +=
          line -
          BillingCalculator.discount(
            line,
            '${item['discount_type'] ?? 'percent'}',
            number(item['discount_value']),
          );
    }
    return eligible;
  }

  String get storedDiscountType =>
      ['minus', 'charges_not_applicable'].contains(discountType)
      ? 'fixed'
      : discountType;

  Json payment() => {
    'discount_type': storedDiscountType,
    'discount_display_type': discountType,
    'discount_value': chargesNotApplicable
        ? chargesNotApplicableDiscount
        : ((double.tryParse(discount.text) ?? 0) * 100).round(),
    'discount_basis_points': discountType == 'percent'
        ? ((double.tryParse(discount.text) ?? 0) * 100).round()
        : 0,
    'payment_method': chargesNotApplicable ? 'complimentary' : paymentMethod,
    'additional_charges': additionalCharges,
    if (chargesNotApplicable) 'settlement_remark': settlementRemark.text.trim(),
    if (!chargesNotApplicable && needsBank && selectedBankId != null)
      'bank_account_id': selectedBankId,
    if (!chargesNotApplicable && qrBankId != null)
      'qr_bank_account_id': qrBankId,
  };

  /// The primary merge record is the source of truth for expected members.
  /// Never infer a joined bill from the number of locally loaded rows: doing
  /// so can silently turn a two-table bill into a one-table bill mid-sync.
  List<String> get joinedOrderIds => <String>{
    '${checkoutOrder['id']}',
    ...List<String>.from(checkoutOrder['merged_order_ids'] ?? const []),
  }.toList();
  List<String> get joinedTableIds => <String>{
    '${checkoutOrder['table_id'] ?? ''}',
    ...List<String>.from(checkoutOrder['merged_table_ids'] ?? const []),
    ...joinedOrders.map((order) => '${order['table_id'] ?? ''}'),
  }.where((id) => id.isNotEmpty).toList();
  List<String> get joinedTableNumbers => <String>{
    ...List<String>.from(
      checkoutOrder['merged_table_numbers'] ?? const <String>[],
    ),
    ...joinedOrders.map((order) => '${order['table_number'] ?? ''}'),
  }.where((number) => number.isNotEmpty).toList();
  bool get hasJoinedTables => joinedTableIds.length > 1;
  List<String> get missingJoinedOrderIds {
    final loadedIds = joinedOrders.map((order) => '${order['id']}').toSet();
    return joinedOrderIds.where((id) => !loadedIds.contains(id)).toList();
  }

  bool get isJoinedBillComplete => missingJoinedOrderIds.isEmpty;

  List<Json> get billTableSections => [
    for (final order in joinedOrders)
      if (maps(order['items']).isNotEmpty)
        {
          'table_id': order['table_id'],
          'table_number': order['table_number'],
          'items': [
            for (final item in maps(order['items']))
              {...item, 'source_table_number': order['table_number']},
          ],
          'subtotal_minor': maps(order['items']).fold<int>(
            0,
            (total, item) =>
                total + number(item['quantity']) * number(item['price_minor']),
          ),
        },
  ];

  Json get billingOrder {
    if (!hasJoinedTables) return checkoutOrder;
    if (!isJoinedBillComplete) {
      throw ApiFailure(
        409,
        'Merged table data is still loading. Reopen checkout after Sync; no incomplete bill has been saved.',
      );
    }
    return {
      ...checkoutOrder,
      'items': [
        for (final section in billTableSections) ...maps(section['items']),
      ],
      'table_sections': billTableSections,
      'merged_table_ids': joinedTableIds,
      'merged_table_numbers': joinedTableNumbers,
      'merged_order_ids': checkoutOrder['merged_order_ids'],
    };
  }

  Json summary() => BillingCalculator.calculate(
    maps(billingOrder['items']),
    payment(),
    effectiveTaxRate(settings),
  );
  List<int> parts(int total) => split == 'equal'
      ? BillingCalculator.splitEqual(total, int.tryParse(count.text) ?? 0)
      : split == 'custom'
      ? custom.text.split(',').map((value) {
          final amount = double.tryParse(value.trim());
          if (amount == null) {
            throw ApiFailure(422, 'Enter comma-separated amounts.');
          }
          return (amount * 100).round();
        }).toList()
      : [];

  List<Json> previewPayments(int total) =>
      !chargesNotApplicable && paymentMethod == 'mixed'
      ? [
          for (final entry in amounts.entries)
            {
              'method': entry.key,
              'amount_minor': ((double.tryParse(entry.value.text) ?? 0) * 100)
                  .round(),
            },
        ]
      : [
          {'method': paymentMethod, 'amount_minor': total},
        ];

  Json previewBill() {
    final previewSummary = summary();
    final qr = selectedQrBank;
    return {
      'receipt': {
        'restaurant': settings,
        'bill_number': 'PREVIEW',
        'table_number': billingOrder['table_number'],
        'merged_table_numbers': billingOrder['merged_table_numbers'],
        'order_type': billingOrder['order_type'],
        'online_platform': billingOrder['online_platform'],
        'online_platform_name': billingOrder['online_platform_name'],
        'customer_name': billingOrder['customer_name'],
        'customer_phone': billingOrder['customer_phone'],
        'items': maps(billingOrder['items']),
        'table_sections': maps(billingOrder['table_sections']),
        'voids': maps(billingOrder['voids']),
        ...previewSummary,
        'tax_basis_points': effectiveTaxRate(settings),
        'discount_basis_points': payment()['discount_basis_points'],
        'discount_type': payment()['discount_type'],
        'discount_display_type': payment()['discount_display_type'],
        'discount_value': payment()['discount_value'],
        'additional_charges': additionalCharges,
        'payment_method': chargesNotApplicable
            ? 'complimentary'
            : paymentMethod,
        'payments': previewPayments(number(previewSummary['total_minor'])),
        'bank_account_name': selectedBankId == null
            ? null
            : banks
                  .where((bank) => '${bank['id']}' == selectedBankId)
                  .firstOrNull?['account_name'],
        'qr_bank_account_id': qr?['id'],
        'qr_bank_account_name': qr?['account_name'],
        'qr_upi_id': qr?['account_number'],
        'qr_image_base64': qr?['qr_image_base64'],
        'cashier_name': widget.session.user?['name'] ?? 'Owner',
        'generated_at': indiaTimestamp(),
      },
    };
  }

  Future<void> previewReceipt() async {
    try {
      final chosen = await Navigator.of(context).push<String>(
        MaterialPageRoute(
          builder: (_) => ReceiptPage(
            widget.session,
            previewBill(),
            previewOnly: true,
            qrOptions: qrBanks,
            selectedQrBankId: qrBankId,
          ),
        ),
      );
      if (chosen != null && mounted) setState(() => qrBankId = chosen);
    } catch (exception) {
      if (mounted) setState(() => error = '$exception');
    }
  }

  Future<void> addAdditionalAmount(int amount) async {
    if (amount <= 0) return;
    var note = '';
    final savedNote = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Add ${money(amount)}'),
        content: TextField(
          autofocus: true,
          maxLines: 2,
          textCapitalization: TextCapitalization.sentences,
          onChanged: (value) => note = value,
          decoration: const InputDecoration(
            labelText: 'Note (optional)',
            hintText: 'For example: Packing charge',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              // Closing the note dialog must also close the mobile keyboard;
              // otherwise its old focus returns to the custom amount field.
              FocusScope.of(dialogContext).unfocus();
              Navigator.pop(dialogContext, note.trim());
            },
            child: const Text('Add to bill'),
          ),
        ],
      ),
    );
    if (savedNote == null || !mounted) return;
    FocusScope.of(context).unfocus();
    setState(
      () => additionalCharges.add({
        'amount_minor': amount,
        if (savedNote.isNotEmpty) 'note': savedNote,
      }),
    );
  }

  Future<void> addCustomAdditionalAmount() async {
    final amount = double.tryParse(additional.text.trim());
    if (amount == null || amount <= 0) {
      setState(() => error = 'Enter a valid additional amount.');
      return;
    }
    await addAdditionalAmount((amount * 100).round());
    if (mounted) {
      FocusScope.of(context).unfocus();
      additional.clear();
    }
  }

  Future<void> submit({int printCopies = 0}) async {
    if (submitting) return;
    setState(() {
      submitting = true;
      error = null;
    });
    try {
      if (!loaded) throw ApiFailure(409, 'Loading table order. Please wait.');
      if (hasJoinedTables && !isJoinedBillComplete) {
        throw ApiFailure(
          409,
          'Merged table data is still loading. Reopen checkout after Sync; no incomplete bill has been saved.',
        );
      }
      if (double.tryParse(discount.text) == null) {
        throw ApiFailure(422, 'Enter a valid discount.');
      }
      if (chargesNotApplicable && settlementRemark.text.trim().isEmpty) {
        throw ApiFailure(
          422,
          'Enter a settlement remark for charges not applicable.',
        );
      }
      if (needsCardAccount && cardBanks.isEmpty) {
        throw ApiFailure(
          422,
          'Add an active Card settlement account in Settings before saving this payment.',
        );
      }
      if (needsQr && selectedQrBank == null) {
        throw ApiFailure(
          422,
          'Select an active UPI account before saving or printing.',
        );
      }
      if (needsCardAccount && bankId == null) {
        throw ApiFailure(
          422,
          'Select an active Card settlement account for this payment.',
        );
      }
      final total = number(summary()['total_minor']);
      final invalidCash = paymentError(total);
      if (invalidCash != null) throw ApiFailure(422, invalidCash);
      final tender = payment();
      tender['split_amounts'] = parts(total);
      if (paymentMethod == 'mixed' && !chargesNotApplicable) {
        tender['payments'] = [
          for (final entry in amounts.entries)
            {
              'method': entry.key,
              'amount_minor': ((double.tryParse(entry.value.text) ?? -1) * 100)
                  .round(),
            },
        ];
      }
      final bill = await widget.session.enqueueBill(
        billingOrder,
        tender,
        sourceOrder: checkoutOrder,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Bill saved on device · ${money(total)} · ${chargesNotApplicable ? 'Complimentary' : paymentMethod.toUpperCase()}',
          ),
        ),
      );
      // Save Bill is deliberately printer-free. It stores the final bill
      // locally, releases the table/cart through enqueueBill, then returns the
      // cashier straight to the prior Table or Menu POS screen.
      if (printCopies == 0) {
        Navigator.of(context).pop(true);
        return;
      }
      // Keep Checkout beneath the receipt. The receipt returns only after the
      // cashier confirms the paper output, so Print Bill remains the sole
      // route that invokes the printer.
      await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => ReceiptPage(
            widget.session,
            bill,
            autoPrint: true,
            autoPrintCopies: printCopies,
            closeAfterConfirmedPrint: true,
          ),
        ),
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    Json calculated = {};
    String? calculationError;
    try {
      calculated = summary();
    } catch (e) {
      calculationError = '$e';
    }
    // A joined checkout never renders a partial fallback list. Until every
    // expected order is present locally, it shows the recovery message below
    // and keeps both final-bill actions disabled.
    final displayItems = calculationError == null
        ? maps(billingOrder['items'])
        : const <Json>[];
    final total = number(calculated['total_minor']);
    final cashValidation = cashError(total);
    final tenderValidation = paymentError(total);
    final canComplete =
        loaded &&
        !submitting &&
        calculationError == null &&
        tenderValidation == null &&
        (!needsCardAccount || bankId != null && cardBanks.isNotEmpty) &&
        (!needsQr || selectedQrBank != null);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Checkout · ${hasJoinedTables ? joinedTableNumbers.join(' + ') : checkoutOrder['table_number']}',
        ),
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              if (!loaded && error == null) const LinearProgressIndicator(),
              Card(
                color: Theme.of(context).colorScheme.primaryContainer,
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Amount to collect',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        money(total),
                        style: const TextStyle(
                          fontSize: 34,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final mode in ['cash', 'upi', 'card', 'mixed'])
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(120, 52),
                        backgroundColor: paymentMethod == mode
                            ? Theme.of(context).colorScheme.primaryContainer
                            : null,
                      ),
                      icon: Icon(switch (mode) {
                        'cash' => Icons.payments_outlined,
                        'upi' => Icons.qr_code,
                        'card' => Icons.credit_card,
                        _ => Icons.call_split,
                      }),
                      label: Text(
                        mode == 'mixed' ? 'Split payment' : mode.toUpperCase(),
                      ),
                      onPressed:
                          submitting ||
                              chargesNotApplicable ||
                              (mode != 'cash' &&
                                  !widget.session.featureEnabled(
                                    mode == 'mixed' ? 'mixed_payment' : mode,
                                  ))
                          ? null
                          : () => setState(() => paymentMethod = mode),
                    ),
                ],
              ),
              if (paymentMethod == 'cash' && !chargesNotApplicable) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: cashReceived,
                  enabled: !submitting,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: 'Cash received (₹)',
                    hintText: 'Optional · exact amount if left blank',
                    errorText: cashValidation,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 8),
                Text(
                  'Change to return: ${money(cashReceivedMinor == null || cashReceivedMinor! < total ? 0 : cashReceivedMinor! - total)}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ],
              if (needsQr)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: DropdownButtonFormField<String>(
                    key: ValueKey(qrBankId),
                    isExpanded: true,
                    initialValue: qrBankId,
                    decoration: const InputDecoration(
                      labelText: 'UPI QR account',
                    ),
                    items: qrBanks
                        .map(
                          (bank) => DropdownMenuItem(
                            value: '${bank['id']}',
                            child: Text(
                              '${bank['account_name']} Â· ${bank['account_number'] ?? 'UPI QR'}',
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (value) => setState(() => qrBankId = value),
                  ),
                ),
              if (needsCardAccount && cardBanks.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: DropdownButtonFormField<String>(
                    key: ValueKey(bankId),
                    initialValue: bankId,
                    decoration: const InputDecoration(
                      labelText: 'Card settlement account',
                    ),
                    items: cardBanks
                        .map(
                          (bank) => DropdownMenuItem(
                            value: bank['id'].toString(),
                            child: Text(
                              '${bank['account_name']} · ${bank['bank_name']}',
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (value) => setState(() => bankId = value),
                  ),
                ),
              if (needsCardAccount && cardBanks.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text(
                    'Add an active Card settlement account in Settings.',
                    style: TextStyle(color: Colors.red),
                  ),
                ),
              if (needsQr && qrBanks.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text(
                    'Add your UPI ID under Payment accounts in Settings. Its QR is generated automatically.',
                    style: TextStyle(color: Colors.red),
                  ),
                ),
              if (paymentMethod == 'mixed')
                for (final entry in amounts.entries)
                  Padding(
                    key: ValueKey('tender_${entry.key}'),
                    padding: const EdgeInsets.only(top: 12),
                    child: TextField(
                      controller: entry.value,
                      onChanged: (_) => setState(() => error = null),
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: '${entry.key.toUpperCase()} amount',
                      ),
                    ),
                  ),
              if (paymentMethod == 'mixed' && tenderValidation != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    tenderValidation,
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
              const SizedBox(height: 20),
              const Text(
                'Order details & optional adjustments',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              ExpansionTile(
                title: Text(
                  'Order items (${displayItems.fold<int>(0, (sum, item) => sum + number(item['quantity']))})',
                ),
                children: [
                  if (hasJoinedTables)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Joint bill: ${joinedTableNumbers.join(' + ')}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              isJoinedBillComplete
                                  ? 'One final bill will be saved. Receipt items stay grouped by their original table.'
                                  : 'Loading every joined table before billing. Please reopen checkout after Sync.',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    ),
                  for (final item in displayItems)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text('${item['item_name']}'),
                      subtitle: Text(
                        '${item['quantity']} × ${money(item['price_minor'])}',
                      ),
                      trailing: Text(
                        money(
                          number(item['quantity']) *
                              number(item['price_minor']),
                        ),
                      ),
                    ),
                ],
              ),
              const Divider(),
              ExpansionTile(
                title: const Text('Discounts & extra charges (optional)'),
                children: [
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    initialValue: discountType,
                    decoration: const InputDecoration(
                      labelText: 'Bill discount type',
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'percent',
                        child: Text('Percentage'),
                      ),
                      DropdownMenuItem(
                        value: 'fixed',
                        child: Text('Fixed amount'),
                      ),
                      DropdownMenuItem(
                        value: 'minus',
                        child: Text('Minus amount'),
                      ),
                      DropdownMenuItem(
                        value: 'charges_not_applicable',
                        child: Text('Charges not applicable'),
                      ),
                    ],
                    onChanged: (value) => setState(() {
                      // A percentage must never silently become a fixed rupee
                      // discount (or vice versa). The user enters it explicitly.
                      discountType = value!;
                      discount.text = '0';
                      if (chargesNotApplicable) {
                        additionalCharges.clear();
                        paymentMethod = 'cash';
                      }
                    }),
                  ),
                  const SizedBox(height: 12),
                  if (chargesNotApplicable) ...[
                    Text(
                      'No charges will be collected. ${money(chargesNotApplicableDiscount)} is recorded as a complimentary settlement.',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: settlementRemark,
                      maxLines: 2,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(
                        labelText: 'Settlement remark *',
                        hintText: 'For example: Family meal',
                      ),
                    ),
                  ] else
                    TextField(
                      controller: discount,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: discountType == 'percent'
                            ? 'Discount (%)'
                            : discountType == 'minus'
                            ? 'Amount to subtract (₹)'
                            : 'Discount amount',
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  if (discountType == 'minus' && calculationError == null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Builder(
                        builder: (context) {
                          final eligibleAmount =
                              number(calculated['subtotal_minor']) -
                              number(calculated['item_discount_minor']);
                          final reducedAmount = number(
                            calculated['bill_discount_minor'],
                          );
                          final percent = eligibleAmount == 0
                              ? 0.0
                              : reducedAmount * 100 / eligibleAmount;
                          return Text(
                            'You are giving ${money(reducedAmount)} discount '
                            '(${percent.toStringAsFixed(2)}%).',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          );
                        },
                      ),
                    ),
                  if (!chargesNotApplicable) ...[
                    const SizedBox(height: 16),
                    Text(
                      'Add amount to bill (optional)',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        for (final amount in [10, 20, 50, 100])
                          OutlinedButton(
                            onPressed: () => addAdditionalAmount(amount * 100),
                            child: Text('₹$amount'),
                          ),
                        SizedBox(
                          width: 170,
                          child: TextField(
                            controller: additional,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            textInputAction: TextInputAction.done,
                            onSubmitted: (_) => addCustomAdditionalAmount(),
                            decoration: const InputDecoration(
                              labelText: 'Custom ₹',
                            ),
                          ),
                        ),
                        FilledButton(
                          onPressed: addCustomAdditionalAmount,
                          child: const Text('Add'),
                        ),
                      ],
                    ),
                    for (final entry in additionalCharges)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(
                          Icons.add_circle_outline,
                          color: Colors.indigo,
                        ),
                        title: Text(
                          entry['note']?.toString().trim().isNotEmpty == true
                              ? entry['note'].toString()
                              : 'Additional amount',
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              money(entry['amount_minor']),
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            IconButton(
                              tooltip: 'Remove additional amount',
                              onPressed: () => setState(
                                () => additionalCharges.remove(entry),
                              ),
                              icon: const Icon(Icons.close, size: 18),
                            ),
                          ],
                        ),
                      ),
                  ],
                  const SizedBox(height: 8),
                  for (final entry in [
                    ('Subtotal', 'subtotal_minor'),
                    ('Item discounts', 'item_discount_minor'),
                    ('Bill discount', 'bill_discount_minor'),
                    if (effectiveTaxRate(settings) > 0) ('GST', 'tax_minor'),
                    if (number(calculated['additional_amount_minor']) > 0)
                      ('Additional amount', 'additional_amount_minor'),
                    ('Total', 'total_minor'),
                  ])
                    ListTile(
                      dense: true,
                      title: Text(entry.$1),
                      trailing: Text(money(calculated[entry.$2])),
                    ),
                  const SizedBox(height: 16),
                ],
              ),
              ExpansionTile(
                title: const Text('Bill sharing (optional)'),
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: split,
                    decoration: const InputDecoration(labelText: 'Split bill'),
                    items: const [
                      DropdownMenuItem(value: 'none', child: Text('One bill')),
                      DropdownMenuItem(
                        value: 'equal',
                        child: Text('Equal parts'),
                      ),
                      DropdownMenuItem(
                        value: 'custom',
                        child: Text('Custom amounts'),
                      ),
                    ],
                    onChanged: (value) => setState(() => split = value!),
                  ),
                  if (split == 'equal')
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: TextField(
                        controller: count,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Number of parts (2–50)',
                        ),
                      ),
                    ),
                  if (split == 'custom')
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: TextField(
                        controller: custom,
                        decoration: const InputDecoration(
                          labelText: 'Amounts separated by commas',
                          hintText: '200, 300, 150',
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: submitting || !loaded ? null : previewReceipt,
                icon: const Icon(Icons.receipt_long_outlined),
                label: Text('Preview bill'),
              ),
              if (error != null || calculationError != null)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    error ?? calculationError!,
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
              if (!loaded && error != null)
                TextButton(
                  onPressed: load,
                  child: const Text('Retry loading bill'),
                ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Total to pay',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  Text(
                    money(total),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (submitting) const LinearProgressIndicator(),
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  'Completing the bill records payment and closes this order.',
                  style: TextStyle(fontSize: 11, color: secondaryText),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: !canComplete ? null : () => submit(),
                      child: Text(
                        submitting ? 'Completing bill…' : 'Complete bill',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: !canComplete
                          ? null
                          : () => submit(printCopies: 1),
                      icon: const Icon(Icons.print_outlined),
                      label: const Text('Print bill'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: !canComplete
                          ? null
                          : () => submit(printCopies: 2),
                      icon: const Icon(Icons.print_outlined),
                      label: const Text('2 copies'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
