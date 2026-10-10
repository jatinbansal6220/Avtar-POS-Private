import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/models.dart';
import '../../core/session.dart';
import '../../ui/shared.dart';
import '../analytics/day_report_export.dart';
import 'data/purchase_math.dart';
import 'purchase_bill_editor.dart';

Future<void> exportPurchaseReport(
  BuildContext context,
  Session session,
  String title,
  List<List<String>> data,
  List<String> headers,
) async {
  try {
    session.requireFeature('printing');
    final pdf = pw.Document();
    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        maxPages: 300,
        build: (c) => [
          pw.Text(
            title,
            style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold),
          ),
          pw.Text('Generated ${indiaTimestamp()} IST'),
          pw.SizedBox(height: 16),
          pw.Table.fromTextArray(
            headers: headers,
            data: data,
            cellStyle: const pw.TextStyle(fontSize: 9),
            headerStyle: pw.TextStyle(
              fontSize: 9,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
        ],
      ),
    );
    final result = await DayReportExporter().export(
      await pdf.save(),
      'purchase-${day(indiaNow())}-${DateTime.now().millisecondsSinceEpoch}',
      printToDefault: false,
    );
    if (context.mounted) message(context, result);
  } catch (e) {
    if (context.mounted) message(context, e);
  }
}

Future<Json?> purchaseActionDialog(
  BuildContext context,
  Session session,
  String kind, {
  Json? bill,
  List<Json> items = const [],
  String? itemId,
  String? unit,
}) async {
  final lines = bill == null ? items : maps(bill['lines']);
  final stockAction = ['return', 'opening', 'usage', 'waste'].contains(kind);
  if (stockAction && lines.isEmpty) {
    message(context, 'Create purchase items first.');
    return null;
  }
  final banks = await session.local!.listAll('banks');
  if (!context.mounted) return null;
  Json? selected =
      lines.where((l) => l['id'] == itemId).firstOrNull ?? lines.firstOrNull;
  var amount = '',
      qty = '1',
      note = '',
      date = day(indiaNow()),
      mode = 'cash',
      stockUnit = unit ?? 'kg';
  String? account, error;
  bool saving = false;
  return showDialog<Json>(
    context: context,
    builder: (dialog) => StatefulBuilder(
      builder: (dialog, refresh) => AlertDialog(
        title: Text(switch (kind) {
          'payment' => 'Record supplier payment',
          'refund' => 'Record refund received',
          'return' => 'Return purchased material',
          'opening' => 'Record opening stock',
          'usage' => 'Record kitchen consumption',
          _ => 'Record wastage',
        }),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (stockAction) ...[
                  DropdownButtonFormField<String>(
                    initialValue: '${selected?['id']}',
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Purchase item',
                    ),
                    items: lines
                        .map(
                          (l) => DropdownMenuItem(
                            value: '${l['id']}',
                            child: Text(
                              '${l['item_name'] ?? l['name']}${kind == 'return' ? ' · ${l['unit']}' : ''}',
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: saving
                        ? null
                        : (v) => refresh(
                            () => selected = lines.firstWhere(
                              (l) => l['id'] == v,
                            ),
                          ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    initialValue: qty,
                    decoration: const InputDecoration(labelText: 'Quantity'),
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    onChanged: (v) => qty = v,
                  ),
                  if (kind != 'return') ...[
                    const SizedBox(height: 12),
                    TextFormField(
                      initialValue: stockUnit,
                      decoration: const InputDecoration(
                        labelText: 'Unit (same as purchase unit)',
                      ),
                      onChanged: (v) => stockUnit = v.trim(),
                    ),
                  ],
                  const SizedBox(height: 12),
                  const Text(
                    'Stock decreases for returns, usage and wastage. A return also reduces the supplier balance.',
                  ),
                ] else ...[
                  TextFormField(
                    decoration: const InputDecoration(labelText: 'Amount (₹)'),
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    onChanged: (v) => amount = v,
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: mode,
                    decoration: const InputDecoration(
                      labelText: 'Payment method',
                    ),
                    items: const ['cash', 'upi', 'bank_transfer']
                        .map(
                          (m) => DropdownMenuItem(
                            value: m,
                            child: Text(m.replaceAll('_', ' ').toUpperCase()),
                          ),
                        )
                        .toList(),
                    onChanged: saving ? null : (v) => mode = v ?? 'cash',
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: account,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Payment account (optional)',
                    ),
                    items: [
                      const DropdownMenuItem<String>(
                        value: null,
                        child: Text('No account selected'),
                      ),
                      ...banks.map(
                        (b) => DropdownMenuItem(
                          value: '${b['id']}',
                          child: Text('${b['account_name']}'),
                        ),
                      ),
                    ],
                    onChanged: saving ? null : (v) => account = v,
                  ),
                ],
                const SizedBox(height: 12),
                TextFormField(
                  initialValue: date,
                  decoration: const InputDecoration(
                    labelText: 'Date · YYYY-MM-DD',
                  ),
                  onChanged: (v) => date = v.trim(),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  decoration: InputDecoration(
                    labelText: stockAction
                        ? 'Reason (required)'
                        : 'Payment reference / note',
                  ),
                  onChanged: (v) => note = v.trim(),
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      error!,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: saving ? null : () => Navigator.pop(dialog),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: saving
                ? null
                : () async {
                    refresh(() => saving = true);
                    try {
                      final event = <String, dynamic>{
                        'name':
                            '$kind ${bill?['name'] ?? selected?['name'] ?? ''}',
                        'kind': kind,
                        'bill_id': bill?['id'],
                        'date': date,
                        'note': note,
                        'payment_mode': stockAction ? null : mode,
                        'bank_account_id': account,
                        'amount_minor': stockAction
                            ? 0
                            : purchaseDecimal(amount),
                        'lines': stockAction
                            ? [
                                {
                                  'purchase_item_id': kind == 'return'
                                      ? selected!['purchase_item_id']
                                      : selected!['id'],
                                  'item_name':
                                      selected!['item_name'] ??
                                      selected!['name'],
                                  'line_id': kind == 'return'
                                      ? selected!['id']
                                      : null,
                                  'unit': kind == 'return'
                                      ? selected!['unit']
                                      : stockUnit,
                                  'quantity_milli': purchaseDecimal(
                                    qty,
                                    scale: 1000,
                                  ),
                                },
                              ]
                            : <Json>[],
                      };
                      final saved = await session.recordPurchaseEvent(event);
                      if (dialog.mounted) Navigator.pop(dialog, saved);
                    } catch (e) {
                      if (dialog.mounted) {
                        refresh(() {
                          error = '$e';
                          saving = false;
                        });
                      }
                    }
                  },
            child: Text(saving ? 'Saving...' : 'Save entry'),
          ),
        ],
      ),
    ),
  );
}

class PurchaseBillDetails extends StatefulWidget {
  final Session session;
  final String id;
  const PurchaseBillDetails(this.session, this.id, {super.key});
  @override
  State<PurchaseBillDetails> createState() => _PurchaseBillDetailsState();
}

class _PurchaseBillDetailsState extends State<PurchaseBillDetails> {
  Json? bill;
  List<Json> events = [];
  String? error;
  @override
  void initState() {
    super.initState();
    for (final resource in ['purchase_bills', 'purchase_events']) {
      widget.session.watch(resource).addListener(load);
    }
    load();
  }

  @override
  void dispose() {
    for (final resource in ['purchase_bills', 'purchase_events']) {
      widget.session.watch(resource).removeListener(load);
    }
    super.dispose();
  }

  Future<void> load() async {
    try {
      final value = await widget.session.local!.get(
        'purchase_bills',
        widget.id,
      );
      final history = await widget.session.local!.listAll('purchase_events');
      if (mounted) {
        setState(() {
          bill = value;
          events = history.where((e) => e['bill_id'] == widget.id).toList()
            ..sort(
              (a, b) => '${b['created_at']}'.compareTo('${a['created_at']}'),
            );
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Future<void> action(String kind) async {
    await purchaseActionDialog(context, widget.session, kind, bill: bill);
    await load();
  }

  Future<void> cancel() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Cancel this purchase order?'),
        content: const Text(
          'The record stays in history. No stock or payment will be posted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Back'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Cancel order'),
          ),
        ],
      ),
    );
    if (yes == true) {
      try {
        await widget.session.savePurchaseBill({
          ...bill!,
          'status': 'cancelled',
          'paid_minor': 0,
        });
        await load();
      } catch (e) {
        if (mounted) message(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = bill,
        balance = current == null
            ? <String, dynamic>{}
            : purchaseBalance(current, events);
    return Scaffold(
      appBar: AppBar(title: Text('${current?['name'] ?? 'Purchase details'}')),
      body: current == null
          ? Center(
              child: error == null
                  ? const CircularProgressIndicator()
                  : Text(error!),
            )
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(
                  '${current['supplier_name']}',
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '${current['status']}'.toUpperCase(),
                  style: const TextStyle(
                    color: accent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  'Purchase date ${current['purchase_date']} · Invoice ${current['invoice_number'] ?? '—'}${current['due_date'] == null ? '' : ' · Due ${current['due_date']}'}',
                ),
                const SizedBox(height: 18),
                Wrap(
                  spacing: 24,
                  runSpacing: 12,
                  children: [
                    Text('Total ${money(current['total_minor'])}'),
                    Text('Paid ${money(balance['paid_minor'])}'),
                    Text('Returned ${money(balance['returned_minor'])}'),
                    Text(
                      'Due ${money(balance['due_minor'])}',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (number(balance['credit_minor']) > 0)
                      Text(
                        'Refund pending ${money(balance['credit_minor'])}',
                        style: const TextStyle(
                          color: Colors.teal,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    if (current['status'] == 'received') ...[
                      if (number(balance['due_minor']) > 0)
                        FilledButton.icon(
                          onPressed: () => action('payment'),
                          icon: const Icon(Icons.payments_outlined),
                          label: const Text('Record payment'),
                        ),
                      OutlinedButton.icon(
                        onPressed: () => action('return'),
                        icon: const Icon(Icons.assignment_return_outlined),
                        label: const Text('Return items'),
                      ),
                      if (number(balance['credit_minor']) > 0)
                        OutlinedButton(
                          onPressed: () => action('refund'),
                          child: const Text('Record refund'),
                        ),
                    ],
                    if (['draft', 'ordered'].contains(current['status'])) ...[
                      FilledButton(
                        onPressed: () async {
                          await openPage(
                            context,
                            PurchaseBillEditor(widget.session, bill: current),
                          );
                          await load();
                        },
                        child: const Text('Edit / receive purchase'),
                      ),
                      OutlinedButton(
                        onPressed: cancel,
                        child: const Text('Cancel order'),
                      ),
                    ],
                    OutlinedButton.icon(
                      onPressed: () => exportPurchaseReport(
                        context,
                        widget.session,
                        '${current['name']} · ${current['supplier_name']}',
                        maps(current['lines'])
                            .map(
                              (l) => [
                                '${l['item_name']}',
                                '${purchaseQty(l['quantity_milli'])} ${l['unit']}',
                                '${number(l['unit_price_minor']) / 100}',
                                '${number(l['discount_minor']) / 100}',
                                '${number(l['tax_minor']) / 100}',
                                '${number(l['total_minor']) / 100}',
                              ],
                            )
                            .toList()
                          ..add([
                            'TOTAL',
                            '',
                            '',
                            '',
                            '',
                            '${number(current['total_minor']) / 100}',
                          ]),
                        [
                          'Item',
                          'Quantity',
                          'Rate',
                          'Discount',
                          'GST',
                          'Total (Rs.)',
                        ],
                      ),
                      icon: const Icon(Icons.picture_as_pdf_outlined),
                      label: const Text('Export purchase PDF'),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                for (final line in maps(current['lines']))
                  Card(
                    child: ListTile(
                      title: Text('${line['item_name']}'),
                      subtitle: Text(
                        '${purchaseQty(line['quantity_milli'])} ${line['unit']} × ${money(line['unit_price_minor'])}\nGST ${money(line['tax_minor'])} · Discount ${money(line['discount_minor'])}',
                      ),
                      trailing: Text(money(line['total_minor'])),
                    ),
                  ),
                const SizedBox(height: 14),
                Text(
                  'Freight ${money(current['freight_minor'])} · GST ${money(current['tax_minor'])}',
                ),
                if ('${current['note'] ?? ''}'.isNotEmpty)
                  Text('${current['note']}'),
                const SizedBox(height: 22),
                const Text(
                  'Payment & return ledger',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
                if (number(current['paid_minor']) > 0)
                  ListTile(
                    title: const Text('Initial payment'),
                    subtitle: Text(
                      '${current['purchase_date']} · ${current['payment_mode']}',
                    ),
                    trailing: Text(money(current['paid_minor'])),
                  ),
                if (events.isEmpty && number(current['paid_minor']) == 0)
                  const Padding(
                    padding: EdgeInsets.all(20),
                    child: Text('No payments or returns recorded.'),
                  ),
                for (final event in events)
                  Card(
                    child: ListTile(
                      title: Text('${event['kind']}'.toUpperCase()),
                      subtitle: Text(
                        '${event['date']} · ${event['payment_mode'] ?? ''}\n${event['note'] ?? ''}${maps(event['lines']).isEmpty ? '' : '\n${maps(event['lines']).map((l) => '${l['item_name']}: ${purchaseQty(l['quantity_milli'])} ${l['unit']}').join(', ')}'}',
                      ),
                      trailing: Text(money(event['amount_minor'])),
                    ),
                  ),
              ],
            ),
    );
  }
}
