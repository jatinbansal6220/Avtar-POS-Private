import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/session.dart';
import 'billing_calculator.dart';

/// Settlement editing deliberately works from the saved receipt, never from
/// the original order. A finalized table therefore stays finalized while the
/// owner can correct payment/discount details with a mandatory audit remark.
class SettlementPage extends StatefulWidget {
  final Session session;
  final Json bill;
  final String invoiceAccessCodeHash;
  const SettlementPage(
    this.session,
    this.bill, {
    required this.invoiceAccessCodeHash,
    super.key,
  });

  @override
  State<SettlementPage> createState() => _SettlementPageState();
}

class _SettlementPageState extends State<SettlementPage> {
  late final TextEditingController discount;
  final remark = TextEditingController();
  final amounts = {
    for (final mode in ['cash', 'card', 'upi'])
      mode: TextEditingController(text: '0'),
  };
  Json receipt = {};
  Json settings = {};
  List<Json> banks = [];
  String discountType = 'percent';
  String paymentMethod = 'cash';
  String? bankId;
  String? defaultBankId;
  String? qrBankId;
  String? error;
  bool loading = true;
  bool saving = false;

  @override
  void initState() {
    super.initState();
    receipt = widget.bill['receipt'] is Map
        ? Map<String, dynamic>.from(widget.bill['receipt'] as Map)
        : {};
    final value = number(receipt['discount_value']) / 100;
    discount = TextEditingController(text: value.toStringAsFixed(2));
    discountType =
        '${receipt['discount_display_type'] ?? receipt['discount_type'] ?? 'percent'}';
    paymentMethod =
        '${receipt['payment_method'] ?? widget.bill['payment_method'] ?? 'cash'}';
    if (paymentMethod == 'complimentary')
      discountType = 'charges_not_applicable';
    qrBankId = receipt['qr_bank_account_id']?.toString();
    for (final tender in maps(receipt['payments'])) {
      final method = '${tender['method'] ?? ''}';
      if (amounts.containsKey(method)) {
        amounts[method]!.text = (number(tender['amount_minor']) / 100)
            .toStringAsFixed(2);
      }
    }
    load();
  }

  Future<void> load() async {
    try {
      final values = await Future.wait([
        widget.session.local!.list('settings', limit: 1),
        widget.session.local!.list('banks', limit: 500),
      ]);
      final active = values[1]
          .where((bank) => enabled(bank['is_active']))
          .toList();
      final cards = active.where(isCardSettlementAccount).toList();
      final defaultBank = cards.firstOrNull;
      if (!mounted) return;
      setState(() {
        settings = values[0].firstOrNull ?? <String, dynamic>{};
        banks = active;
        defaultBankId = defaultBank?['id']?.toString();
        final receiptBankId = receipt['bank_account_id']?.toString();
        bankId = cards.any((bank) => '${bank['id']}' == receiptBankId)
            ? receiptBankId
            : defaultBankId;
        loading = false;
      });
    } catch (exception) {
      if (mounted)
        setState(() {
          error = '$exception';
          loading = false;
        });
    }
  }

  @override
  void dispose() {
    discount.dispose();
    remark.dispose();
    for (final field in amounts.values) field.dispose();
    super.dispose();
  }

  List<Json> get items => maps(receipt['items'] ?? widget.bill['items']);
  bool get complimentary => discountType == 'charges_not_applicable';
  bool isUpiSettlementAccount(Json bank) =>
      ['upi', 'upi_merchant'].contains('${bank['account_type'] ?? ''}');
  bool isCardSettlementAccount(Json bank) {
    if (bank.containsKey('use_for_card')) return enabled(bank['use_for_card']);
    return [
      'card',
      'current',
      'savings',
      'cash_drawer',
    ].contains('${bank['account_type'] ?? ''}');
  }

  List<Json> get cardBanks => banks.where(isCardSettlementAccount).toList();
  List<Json> get qrBanks => banks
      .where(
        (bank) =>
            isUpiSettlementAccount(bank) &&
            '${bank['qr_image_base64'] ?? ''}'.trim().isNotEmpty,
      )
      .toList();
  bool get needsCardAccount =>
      paymentMethod == 'card' ||
      (paymentMethod == 'mixed' &&
          amounts.entries.any(
            (entry) =>
                entry.key == 'card' &&
                (double.tryParse(entry.value.text) ?? 0) > 0,
          ));
  bool get needsQr =>
      paymentMethod == 'upi' ||
      (paymentMethod == 'mixed' &&
          (double.tryParse(amounts['upi']!.text) ?? 0) > 0);
  String? get selectedBankId => paymentMethod == 'upi'
      ? qrBankId
      : needsCardAccount
      ? bankId
      : needsQr
      ? qrBankId
      : null;

  int get complimentaryDiscount {
    var eligible = 0;
    for (final item in items) {
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

  Json payment() => {
    'discount_type': ['minus', 'charges_not_applicable'].contains(discountType)
        ? 'fixed'
        : discountType,
    'discount_display_type': discountType,
    'discount_value': complimentary
        ? complimentaryDiscount
        : ((double.tryParse(discount.text) ?? 0) * 100).round(),
    'discount_basis_points': discountType == 'percent'
        ? ((double.tryParse(discount.text) ?? 0) * 100).round()
        : 0,
    'payment_method': complimentary ? 'complimentary' : paymentMethod,
    'settlement_remark': remark.text.trim(),
    if (!complimentary && selectedBankId != null)
      'bank_account_id': selectedBankId,
    if (!complimentary && qrBankId != null) 'qr_bank_account_id': qrBankId,
  };

  Json calculation() =>
      BillingCalculator.calculate(items, payment(), effectiveTaxRate(settings));

  Future<void> save({int printCopies = 0}) async {
    if (saving) return;
    setState(() {
      saving = true;
      error = null;
    });
    try {
      if (remark.text.trim().isEmpty) {
        throw ApiFailure(
          422,
          'Settlement remark is required for every invoice edit.',
        );
      }
      if (!complimentary && needsCardAccount && bankId == null) {
        throw ApiFailure(422, 'Select an active Card settlement account.');
      }
      if (!complimentary &&
          needsQr &&
          !qrBanks.any((bank) => '${bank['id']}' == qrBankId)) {
        throw ApiFailure(
          422,
          'Select an active UPI account with an uploaded QR.',
        );
      }
      final tender = payment();
      final total = number(calculation()['total_minor']);
      if (paymentMethod == 'mixed' && !complimentary) {
        tender['payments'] = [
          for (final entry in amounts.entries)
            {
              'method': entry.key,
              'amount_minor': ((double.tryParse(entry.value.text) ?? -1) * 100)
                  .round(),
            },
        ];
      }
      final saved = await widget.session.updateBillSettlement(
        widget.bill,
        tender,
        invoiceAccessCodeHash: widget.invoiceAccessCodeHash,
      );
      if (mounted) {
        Navigator.pop(context, {
          'bill': saved,
          'printCopies': printCopies,
          'total': total,
        });
      }
    } catch (exception) {
      if (mounted) setState(() => error = '$exception');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    Json totals = {};
    try {
      totals = calculation();
    } catch (exception) {
      error ??= '$exception';
    }
    return Scaffold(
      appBar: AppBar(
        title: Text('Edit settlement - ${receipt['bill_number'] ?? 'Invoice'}'),
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                'Final invoice settlement',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 4),
              const Text(
                'Items and bill number remain unchanged. Every save is recorded in invoice history.',
              ),
              const SizedBox(height: 14),
              for (final item in items)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text('${item['item_name']}'),
                  subtitle: Text(
                    '${item['quantity']} x ${money(item['price_minor'])}',
                  ),
                  trailing: Text(
                    money(
                      number(item['quantity']) * number(item['price_minor']),
                    ),
                  ),
                ),
              const Divider(),
              DropdownButtonFormField<String>(
                key: ValueKey(discountType),
                initialValue: discountType,
                decoration: const InputDecoration(
                  labelText: 'Bill discount type',
                ),
                items: const [
                  DropdownMenuItem(value: 'percent', child: Text('Percentage')),
                  DropdownMenuItem(value: 'fixed', child: Text('Fixed amount')),
                  DropdownMenuItem(value: 'minus', child: Text('Minus amount')),
                  DropdownMenuItem(
                    value: 'charges_not_applicable',
                    child: Text('Charges not applicable'),
                  ),
                ],
                onChanged: (value) => setState(() {
                  discountType = value!;
                  discount.text = '0';
                  if (complimentary || paymentMethod == 'complimentary') {
                    paymentMethod = 'cash';
                  }
                }),
              ),
              const SizedBox(height: 12),
              if (complimentary)
                Text(
                  'No charges will be collected. ${money(complimentaryDiscount)} is recorded as complimentary.',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                )
              else
                TextField(
                  controller: discount,
                  keyboardType: TextInputType.number,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: discountType == 'percent'
                        ? 'Discount (%)'
                        : 'Discount amount',
                  ),
                ),
              const SizedBox(height: 12),
              TextField(
                controller: remark,
                autofocus: true,
                maxLines: 2,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Settlement remark *',
                  hintText: 'Why was this invoice edited?',
                ),
              ),
              const SizedBox(height: 16),
              if (!complimentary) ...[
                Wrap(
                  spacing: 8,
                  children: [
                    for (final mode in ['cash', 'upi', 'card', 'mixed'])
                      ChoiceChip(
                        label: Text(
                          mode == 'mixed'
                              ? 'Split payment'
                              : mode.toUpperCase(),
                        ),
                        selected: paymentMethod == mode,
                        onSelected: (_) => setState(() => paymentMethod = mode),
                      ),
                  ],
                ),
                if (needsQr)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: DropdownButtonFormField<String>(
                      key: ValueKey(qrBankId),
                      initialValue: qrBankId,
                      decoration: const InputDecoration(
                        labelText: 'UPI QR account',
                      ),
                      items: qrBanks
                          .map(
                            (bank) => DropdownMenuItem(
                              value: '${bank['id']}',
                              child: Text('${bank['account_name']}'),
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
                              value: '${bank['id']}',
                              child: Text(
                                '${bank['account_name']} - ${bank['bank_name']}',
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (value) => setState(() => bankId = value),
                    ),
                  ),
                if (needsQr && qrBanks.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: Text(
                      'Add an active UPI account with QR in Settings.',
                      style: TextStyle(color: Colors.red),
                    ),
                  ),
                if (paymentMethod == 'mixed')
                  for (final entry in amounts.entries)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: TextField(
                        controller: entry.value,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: '${entry.key.toUpperCase()} amount',
                        ),
                      ),
                    ),
              ],
              const SizedBox(height: 16),
              for (final line in [
                ('Subtotal', 'subtotal_minor'),
                ('Discount', 'discount_minor'),
                if (number(totals['tax_minor']) > 0) ('GST', 'tax_minor'),
                ('Total', 'total_minor'),
              ])
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    line.$1,
                    style: line.$1 == 'Total'
                        ? const TextStyle(fontWeight: FontWeight.w800)
                        : null,
                  ),
                  trailing: Text(
                    money(totals[line.$2]),
                    style: line.$1 == 'Total'
                        ? const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                          )
                        : null,
                  ),
                ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    error!,
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: saving || loading ? null : () => save(),
                      child: const Text('Save settlement'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: saving || loading
                          ? null
                          : () => save(printCopies: 1),
                      icon: const Icon(Icons.print_outlined),
                      label: const Text('Print bill'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: saving || loading
                          ? null
                          : () => save(printCopies: 2),
                      icon: const Icon(Icons.print_outlined),
                      label: const Text('Print double bill'),
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
