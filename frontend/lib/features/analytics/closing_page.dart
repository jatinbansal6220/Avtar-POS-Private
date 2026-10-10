import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/session.dart';
import 'day_report_export.dart';
import 'day_report_pdf.dart';
import 'local_reports.dart';

/// Filterable, invoice-backed daily cashbook. It intentionally reads only
/// when this report is opened; POS/table screens never load ledger history.
class ClosingPage extends StatefulWidget {
  final Session session;
  final bool accessVerified;
  const ClosingPage(this.session, {super.key, this.accessVerified = false});

  @override
  State<ClosingPage> createState() => _ClosingPageState();
}

class _ClosingPageState extends State<ClosingPage> {
  final from = TextEditingController(text: day(indiaNow()));
  final to = TextEditingController(text: day(indiaNow()));
  Json? report;
  String? error;
  bool busy = false;
  bool loadingMore = false;
  bool exporting = false;
  String paymentScope = 'all';
  bool authorized = false;
  void refresh() {
    if (authorized) load();
  }

  @override
  void initState() {
    super.initState();
    widget.session.watch('bills').addListener(refresh);
    widget.session.watch('orders').addListener(refresh);
    authorized = widget.accessVerified && widget.session.manager;
    if (authorized) {
      load();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => verifyAccess());
    }
  }

  Future<void> verifyAccess() async {
    if (!mounted || !widget.session.manager) return;
    var entered = '';
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Verify owner code'),
        content: TextField(
          autofocus: true,
          obscureText: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Invoice deletion/edit code',
          ),
          onChanged: (value) => entered = value,
          onSubmitted: (_) => Navigator.pop(dialogContext, true),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Back'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Open day closing'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    try {
      await widget.session.verifyInvoiceAccessCode(entered);
      if (!mounted) return;
      setState(() {
        authorized = true;
        error = null;
      });
      await load();
    } catch (failure) {
      if (mounted) setState(() => error = '$failure');
    }
  }

  @override
  void dispose() {
    widget.session.watch('bills').removeListener(refresh);
    widget.session.watch('orders').removeListener(refresh);
    from.dispose();
    to.dispose();
    super.dispose();
  }

  Future<void> load({bool more = false}) async {
    if (!authorized) return;
    if (more ? loadingMore : busy) {
      return;
    }
    setState(() {
      if (more) {
        loadingMore = true;
      } else {
        busy = true;
      }
    });
    try {
      final result = await LocalReports(widget.session.local!).dayReport(
        from.text.trim(),
        to.text.trim(),
        offset: more ? number(report?['next_offset']) : 0,
        paymentScope: paymentScope,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        if (more && report != null) {
          report = {
            ...result,
            'ledger': [...maps(report!['ledger']), ...maps(result['ledger'])],
          };
        } else {
          report = result;
        }
        error = null;
      });
    } catch (exception) {
      if (mounted) setState(() => error = '$exception');
    } finally {
      if (mounted)
        setState(() {
          busy = false;
          loadingMore = false;
        });
    }
  }

  void period(String value) {
    final now = indiaNow();
    final start = switch (value) {
      'Today' => now,
      'Yesterday' => now.subtract(const Duration(days: 1)),
      'This week' => now.subtract(Duration(days: now.weekday - 1)),
      _ => DateTime(now.year, now.month),
    };
    from.text = day(start);
    to.text = day(value == 'Yesterday' ? start : now);
    load();
  }

  Future<void> selectPaymentScope(String scope) async {
    if (paymentScope == scope) return;
    setState(() => paymentScope = scope);
    await load();
  }

  Future<void> exportA4({required bool printToDefault}) async {
    if (report == null || exporting) return;
    setState(() => exporting = true);
    try {
      final bytes = await DayReportPdf.build(report!);
      final name =
          'AvtarPOS_${paymentScope}_${from.text.trim()}_to_${to.text.trim()}';
      final result = await DayReportExporter().export(
        bytes,
        name,
        printToDefault: printToDefault,
      );
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(result)));
      }
    } catch (exception) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not create A4 report: $exception')),
        );
      }
    } finally {
      if (mounted) setState(() => exporting = false);
    }
  }

  Future<void> confirmA4Print() async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Print A4 day report?'),
        content: const Text(
          'This sends the PDF to the Windows default printer. Confirm an A4-capable printer is default. Do not send this report directly to the RP80US thermal receipt printer.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(Icons.print_outlined),
            label: const Text('Print A4'),
          ),
        ],
      ),
    );
    if (accepted == true && mounted) await exportA4(printToDefault: true);
  }

  Widget metric(String label, dynamic value, IconData icon, Color color) =>
      SizedBox(
        width: 210,
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(15),
            child: Row(
              children: [
                CircleAvatar(
                  backgroundColor: color.withValues(alpha: .12),
                  foregroundColor: color,
                  child: Icon(icon),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label, style: const TextStyle(fontSize: 12)),
                      const SizedBox(height: 3),
                      Text(
                        '$value',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );

  Widget scopeCard(
    String scope,
    String label,
    IconData icon,
    Color color,
    Json totals,
  ) => SizedBox(
    width: 180,
    child: Card(
      clipBehavior: Clip.antiAlias,
      color: paymentScope == scope ? color.withValues(alpha: .12) : null,
      child: InkWell(
        onTap: busy ? null : () => selectPaymentScope(scope),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: color),
              const SizedBox(height: 9),
              Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 3),
              Text(
                money(totals['amount_minor']),
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                '${number(totals['orders'])} invoice${number(totals['orders']) == 1 ? '' : 's'}',
                style: const TextStyle(fontSize: 11, color: Colors.black54),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  String when(dynamic raw) {
    final time = indiaDateTime(raw);
    if (time == null) {
      return '${raw ?? ''}';
    }
    final hour = time.hour % 12 == 0 ? 12 : time.hour % 12;
    return '${time.day.toString().padLeft(2, '0')}-${time.month.toString().padLeft(2, '0')}-${time.year}  $hour:${time.minute.toString().padLeft(2, '0')} ${time.hour >= 12 ? 'PM' : 'AM'}';
  }

  String methodLabel(Json row) {
    final parts = maps(row['payments']);
    if (parts.length > 1) {
      return parts.map((part) => '${part['method']}'.toUpperCase()).join(' + ');
    }
    return '${row['payment_method'] ?? 'cash'}'
        .replaceAll('_', ' ')
        .toUpperCase();
  }

  Widget paymentCards(List<Json> rows) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Collection by payment method',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          if (rows.isEmpty) const Text('No finalized invoices in this period.'),
          for (final row in rows)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                row['method'] == 'Cash'
                    ? Icons.payments_outlined
                    : row['method'] == 'Charges not applicable'
                    ? Icons.volunteer_activism_outlined
                    : Icons.account_balance_outlined,
              ),
              title: Text('${row['method']}'),
              subtitle: Text(
                '${number(row['orders'])} invoice${number(row['orders']) == 1 ? '' : 's'}',
              ),
              trailing: Text(
                money(row['amount_minor']),
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
        ],
      ),
    ),
  );

  Widget accountCards(List<Json> rows) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Bank / UPI account collection',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          if (rows.isEmpty)
            const Text('No electronic collection in this period.'),
          for (final row in rows)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.account_balance_wallet_outlined),
              title: Text('${row['account_name']}'),
              subtitle: Text(
                '${number(row['orders'])} invoice${number(row['orders']) == 1 ? '' : 's'}',
              ),
              trailing: Text(
                money(row['amount_minor']),
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
        ],
      ),
    ),
  );

  Widget invoiceLedger(List<Json> rows) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            paymentScope == 'all'
                ? 'All invoice history'
                : '${paymentScope == 'split' ? 'Split-payment' : paymentScope.toUpperCase()} invoice history',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          const Text(
            'Open each card for payment, bank and settlement-edit details.',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 8),
          for (final row in rows)
            Card(
              margin: const EdgeInsets.only(top: 8),
              child: ExpansionTile(
                leading: const Icon(Icons.receipt_long_outlined),
                title: Text(
                  '${row['bill_number'] ?? 'Invoice'}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text(
                  '${when(row['generated_at'])} - ${row['table_number'] ?? 'POS / Takeaway'}',
                ),
                trailing: Text(
                  money(row['total_minor']),
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Payment: ${methodLabel(row)}'),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Collected in this report: ${money(row['report_amount_minor'] ?? row['total_minor'])}',
                    ),
                  ),
                  if ('${row['bank_account_name'] ?? ''}'.trim().isNotEmpty)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text('Bank / UPI: ${row['bank_account_name']}'),
                    ),
                  if (number(row['discount_minor']) > 0)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Discount: ${money(row['discount_minor'])} (${row['discount_display_type'] ?? 'discount'})',
                      ),
                    ),
                  if ('${row['settlement_remark'] ?? ''}'.trim().isNotEmpty)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Latest settlement remark: ${row['settlement_remark']}',
                      ),
                    ),
                  if (maps(row['settlement_edits']).isNotEmpty) ...[
                    const Divider(),
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Settlement edit audit',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    for (final edit in maps(row['settlement_edits']))
                      Padding(
                        padding: const EdgeInsets.only(top: 5),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            '${when(edit['edited_at'])} - ${edit['edited_by'] ?? 'Owner'}: ${edit['remark'] ?? ''}',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (!authorized) {
      return Scaffold(
        appBar: AppBar(title: const Text('Day closing')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Day closing is protected by the owner code.'),
                if (error != null)
                  Text(error!, style: const TextStyle(color: Colors.red)),
                if (widget.session.manager)
                  FilledButton(
                    onPressed: verifyAccess,
                    child: const Text('Enter owner code'),
                  ),
              ],
            ),
          ),
        ),
      );
    }
    final summary = report?['summary'] is Map
        ? Map<String, dynamic>.from(report!['summary'] as Map)
        : <String, dynamic>{};
    final paymentRows = report == null ? <Json>[] : maps(report!['payments']);
    final scopeTotals = report?['scope_totals'] is Map
        ? Map<String, dynamic>.from(report!['scope_totals'] as Map)
        : <String, dynamic>{};
    Json totalsFor(String scope) => scopeTotals[scope] is Map
        ? Map<String, dynamic>.from(scopeTotals[scope] as Map)
        : <String, dynamic>{};
    return Scaffold(
      appBar: AppBar(
        title: const Text('Day closing / cashbook'),
        actions: [
          IconButton(
            tooltip: 'Save A4 PDF',
            onPressed: report == null || exporting
                ? null
                : () => exportA4(printToDefault: false),
            icon: const Icon(Icons.picture_as_pdf_outlined),
          ),
          IconButton(
            tooltip: 'Print A4 report',
            onPressed: report == null || exporting ? null : confirmA4Print,
            icon: const Icon(Icons.print_outlined),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final value in [
                'Today',
                'Yesterday',
                'This week',
                'This month',
              ])
                OutlinedButton(
                  onPressed: () => period(value),
                  child: Text(value),
                ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: from,
                  decoration: const InputDecoration(
                    labelText: 'From (YYYY-MM-DD)',
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: to,
                  decoration: const InputDecoration(
                    labelText: 'To (YYYY-MM-DD)',
                  ),
                ),
              ),
              const SizedBox(width: 10),
              IconButton.filled(
                onPressed: busy ? null : load,
                icon: const Icon(Icons.filter_alt_outlined),
              ),
            ],
          ),
          const SizedBox(height: 18),
          if (busy) const LinearProgressIndicator(),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(error!, style: const TextStyle(color: Colors.red)),
            ),
          if (report != null) ...[
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                metric(
                  'Final sales',
                  money(summary['revenue_minor']),
                  Icons.currency_rupee,
                  Colors.indigo,
                ),
                metric(
                  'Invoices',
                  '${number(summary['bills'])}',
                  Icons.receipt_long_outlined,
                  Colors.teal,
                ),
                metric(
                  'Cash / galla',
                  money(
                    paymentRows
                        .where((row) => row['method'] == 'Cash')
                        .fold<int>(
                          0,
                          (sum, row) => sum + number(row['amount_minor']),
                        ),
                  ),
                  Icons.payments_outlined,
                  Colors.green,
                ),
                for (final method in ['UPI', 'Card'])
                  metric(
                    method,
                    money(
                      paymentRows
                          .where((row) => row['method'] == method)
                          .fold<int>(
                            0,
                            (sum, row) => sum + number(row['amount_minor']),
                          ),
                    ),
                    method == 'UPI' ? Icons.qr_code : Icons.credit_card,
                    Colors.indigo,
                  ),
                metric(
                  'Open orders now',
                  '${number((report!['open_orders_now'] as Map?)?['orders'])}',
                  Icons.pending_actions,
                  Colors.orange,
                ),
                metric(
                  'Unbilled items now',
                  money(
                    (report!['open_orders_now']
                        as Map?)?['items_subtotal_minor'],
                  ),
                  Icons.restaurant_outlined,
                  Colors.orange,
                ),
                metric(
                  'Charges not applicable',
                  money(summary['complimentary_minor']),
                  Icons.volunteer_activism_outlined,
                  Colors.orange,
                ),
                metric(
                  'Discounts',
                  money(summary['discount_minor']),
                  Icons.sell_outlined,
                  Colors.red,
                ),
                metric(
                  'GST',
                  money(summary['tax_minor']),
                  Icons.account_balance_outlined,
                  Colors.blueGrey,
                ),
              ],
            ),
            const SizedBox(height: 18),
            Text(
              'Payment report',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            const Text(
              'Tap a card to filter its full history. Settlement edits use the latest saved payment details.',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                scopeCard(
                  'all',
                  'All history',
                  Icons.receipt_long_outlined,
                  Colors.indigo,
                  totalsFor('all'),
                ),
                scopeCard(
                  'cash',
                  'Cash',
                  Icons.payments_outlined,
                  Colors.green,
                  totalsFor('cash'),
                ),
                scopeCard(
                  'upi',
                  'UPI',
                  Icons.qr_code_2_outlined,
                  Colors.purple,
                  totalsFor('upi'),
                ),
                scopeCard(
                  'card',
                  'Card',
                  Icons.credit_card_outlined,
                  Colors.blue,
                  totalsFor('card'),
                ),
                scopeCard(
                  'online',
                  'Online payment',
                  Icons.language_outlined,
                  Colors.teal,
                  totalsFor('online'),
                ),
                scopeCard(
                  'split',
                  'Split payment',
                  Icons.call_split_outlined,
                  Colors.orange,
                  totalsFor('split'),
                ),
              ],
            ),
            const SizedBox(height: 18),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: Text(
                'Open orders are current carts, including earlier days. Their items subtotal is separate from finalized sales; checkout applies final discounts, tax and charges.',
                style: TextStyle(fontSize: 12, color: Colors.black54),
              ),
            ),
            paymentCards(paymentRows),
            const SizedBox(height: 14),
            accountCards(maps(report!['accounts'])),
            if (maps(report!['audit']).isNotEmpty) ...[
              const SizedBox(height: 14),
              Card(
                child: ExpansionTile(
                  leading: const Icon(Icons.history_outlined),
                  title: Text(
                    'Settlement edit log (${maps(report!['audit']).length})',
                  ),
                  subtitle: const Text(
                    'All edited invoices in the selected period',
                  ),
                  childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                  children: [
                    for (final edit in maps(report!['audit']))
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          '${edit['bill_number']} - ${edit['table_number'] ?? 'Invoice'}',
                        ),
                        subtitle: Text(
                          '${when(edit['edited_at'])}\n${edit['edited_by'] ?? 'Owner'}: ${edit['remark'] ?? ''}',
                        ),
                        isThreeLine: true,
                        trailing: Text(money(edit['new_total_minor'])),
                      ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 14),
            invoiceLedger(maps(report!['ledger'])),
            if (report!['next_offset'] != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: OutlinedButton.icon(
                  onPressed: loadingMore ? null : () => load(more: true),
                  icon: const Icon(Icons.expand_more),
                  label: Text(
                    loadingMore
                        ? 'Loading invoices...'
                        : 'Load more invoice history',
                  ),
                ),
              ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: exporting
                      ? null
                      : () => exportA4(printToDefault: false),
                  icon: const Icon(Icons.picture_as_pdf_outlined),
                  label: Text(
                    exporting ? 'Preparing A4 report...' : 'Save A4 PDF',
                  ),
                ),
                FilledButton.icon(
                  onPressed: exporting ? null : confirmA4Print,
                  icon: const Icon(Icons.print_outlined),
                  label: const Text('Print A4 report'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
