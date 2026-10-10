import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/session.dart';
import '../../ui/shared.dart';
import 'data/purchase_math.dart';
import 'purchase_bill_editor.dart';
import 'purchase_forms.dart';
import 'purchase_ledger_details.dart';
import 'purchases_page.dart';
import 'purchase_history_page.dart';

class PurchaseDashboard extends StatefulWidget {
  final Session session;
  const PurchaseDashboard(this.session, {super.key});
  @override
  State<PurchaseDashboard> createState() => _PurchaseDashboardState();
}

class _PurchaseDashboardState extends State<PurchaseDashboard> {
  static const resources = [
    'purchase_bills',
    'purchase_events',
    'purchase_suppliers',
    'purchase_items',
    'purchase_categories',
    'purchases',
  ];
  List<Json> bills = [],
      events = [],
      suppliers = [],
      items = [],
      categories = [],
      legacy = [];
  final search = TextEditingController(),
      from = TextEditingController(),
      to = TextEditingController();
  bool loading = true;
  int section = 0, generation = 0;
  int visibleLimit = 50;
  Map<String, List<Json>> eventsByBill = {};
  Json balanceOf(Json bill) =>
      purchaseBalance(bill, eventsByBill['${bill['id']}'] ?? []);
  Widget moreButton(int count) => count > visibleLimit
      ? TextButton(
          onPressed: () => setState(() => visibleLimit += 50),
          child: const Text('Show next 50'),
        )
      : const SizedBox.shrink();
  String status = 'all';
  String? supplierId, error;
  @override
  void initState() {
    super.initState();
    for (final resource in resources) {
      widget.session.watch(resource).addListener(load);
    }
    load();
  }

  @override
  void dispose() {
    for (final resource in resources) {
      widget.session.watch(resource).removeListener(load);
    }
    search.dispose();
    from.dispose();
    to.dispose();
    super.dispose();
  }

  Future<void> load() async {
    final gen = ++generation;
    try {
      final values = await Future.wait(
        resources.map(widget.session.local!.listAll),
      );
      if (!mounted || gen != generation) return;
      setState(() {
        bills = values[0]
          ..sort(
            (a, b) => '${b['purchase_date']}|${b['created_at']}'.compareTo(
              '${a['purchase_date']}|${a['created_at']}',
            ),
          );
        events = values[1];
        eventsByBill = {};
        for (final event in events) {
          eventsByBill.putIfAbsent('${event['bill_id']}', () => []).add(event);
        }
        suppliers = values[2];
        items = values[3];
        categories = values[4];
        legacy = values[5];
        loading = false;
        error = null;
      });
    } catch (e) {
      if (mounted && gen == generation) {
        setState(() {
          loading = false;
          error = '$e';
        });
      }
    }
  }

  List<Json> get filtered => bills.where((b) {
    final text =
        '${b['name']} ${b['supplier_name']} ${b['invoice_number'] ?? ''} ${maps(b['lines']).map((l) => l['item_name']).join(' ')}'
            .toLowerCase();
    final date = '${b['purchase_date']}';
    return text.contains(search.text.trim().toLowerCase()) &&
        (status == 'all' || b['status'] == status) &&
        (supplierId == null || b['supplier_id'] == supplierId) &&
        (from.text.isEmpty || date.compareTo(from.text) >= 0) &&
        (to.text.isEmpty || date.compareTo(to.text) <= 0);
  }).toList();
  bool overdue(Json bill) =>
      number(balanceOf(bill)['due_minor']) > 0 &&
      '${bill['due_date'] ?? ''}'.isNotEmpty &&
      '${bill['due_date']}'.compareTo(day(indiaNow())) < 0;
  Future<void> newPurchase() async {
    if (items.where((i) => enabled(i['is_active'])).isEmpty) {
      message(context, 'Create the items you purchase first.');
      await openPage(context, PurchasesPage(widget.session, catalogOnly: true));
      await load();
      if (!mounted || items.where((i) => enabled(i['is_active'])).isEmpty) {
        return;
      }
    }
    await openPage(context, PurchaseBillEditor(widget.session));
    await load();
  }

  Widget metric(
    String title,
    String value,
    IconData icon, {
    Color color = accent,
  }) => SizedBox(
    width: 230,
    child: Card(
      elevation: 0,
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color),
            const SizedBox(height: 14),
            Text(
              value,
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
            ),
            Text(title, style: const TextStyle(color: secondaryText)),
          ],
        ),
      ),
    ),
  );
  Widget billCard(Json b) {
    final balance = balanceOf(b);
    return Card(
      elevation: 0,
      child: InkWell(
        onTap: () async {
          await openPage(
            context,
            PurchaseBillDetails(widget.session, '${b['id']}'),
          );
          await load();
        },
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${b['supplier_name']}',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 17,
                      ),
                    ),
                  ),
                  Text(
                    money(b['total_minor']),
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      color: accent,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '${b['purchase_date']} · ${b['invoice_number'] ?? b['name']} · ${maps(b['lines']).length} items',
                style: const TextStyle(color: secondaryText),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 14,
                runSpacing: 6,
                children: [
                  Text(
                    '${b['status']}'.toUpperCase(),
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (b['status'] == 'received')
                    Text(
                      number(balance['due_minor']) > 0
                          ? 'Due ${money(balance['due_minor'])}'
                          : 'Paid',
                      style: TextStyle(
                        color: number(balance['due_minor']) > 0
                            ? Colors.deepOrange
                            : Colors.teal,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  if (overdue(b))
                    const Text(
                      'OVERDUE',
                      style: TextStyle(
                        color: Colors.red,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  if (number(balance['credit_minor']) > 0)
                    Text(
                      'Refund pending ${money(balance['credit_minor'])}',
                      style: const TextStyle(color: Colors.teal),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget overview() {
    final month = day(indiaNow()).substring(0, 7);
    final received = bills.where((b) => b['status'] == 'received').toList();
    final total = received
        .where((b) => '${b['purchase_date']}'.startsWith(month))
        .fold<int>(0, (s, b) => s + number(b['total_minor']));
    final returns = events
        .where((e) => e['kind'] == 'return' && '${e['date']}'.startsWith(month))
        .fold<int>(0, (s, e) => s + number(e['amount_minor']));
    final due = received.fold<int>(
      0,
      (s, b) => s + number(balanceOf(b)['due_minor']),
    );
    final credit = received.fold<int>(
      0,
      (s, b) => s + number(balanceOf(b)['credit_minor']),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: const LinearGradient(
              colors: [Color(0xFF24205A), Color(0xFF5145CD)],
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Add a purchase in 3 simple steps',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 25,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Choose supplier → Add items → Save received stock. Payment can be full, partial or udhaar.',
                style: TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 18),
              FilledButton.tonalIcon(
                onPressed: newPurchase,
                icon: const Icon(Icons.add),
                label: const Text('New purchase bill'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: () async {
                await editPurchaseSupplier(context, widget.session);
                await load();
              },
              icon: const Icon(Icons.person_add_alt),
              label: const Text('Add supplier'),
            ),
            OutlinedButton.icon(
              onPressed: () => setState(() => section = 2),
              icon: const Icon(Icons.account_balance_wallet_outlined),
              label: const Text('Supplier dues'),
            ),
            OutlinedButton.icon(
              onPressed: () => setState(() => section = 3),
              icon: const Icon(Icons.inventory_2_outlined),
              label: const Text('Check stock'),
            ),
          ],
        ),
        const SizedBox(height: 18),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            metric(
              'Net purchases · this month',
              money(total - returns),
              Icons.shopping_bag_outlined,
            ),
            metric(
              'Supplier dues · all dates',
              money(due),
              Icons.account_balance_wallet_outlined,
              color: Colors.deepOrange,
            ),
            metric(
              'Refunds to collect',
              money(credit),
              Icons.assignment_return_outlined,
              color: Colors.teal,
            ),
            metric(
              'Open purchase orders',
              '${bills.where((b) => b['status'] == 'ordered').length}',
              Icons.local_shipping_outlined,
            ),
          ],
        ),
        if (legacy.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Text(
              'Your ${legacy.length} older single-item purchase entries are preserved in Legacy history. Their credit balances are not included in the new supplier ledger.',
              style: const TextStyle(color: secondaryText),
            ),
          ),
        const SizedBox(height: 20),
        Row(
          children: [
            const Expanded(
              child: Text(
                'Needs attention',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              ),
            ),
            TextButton(
              onPressed: () => setState(() => section = 1),
              child: const Text('All purchases'),
            ),
          ],
        ),
        if (received.where(overdue).isEmpty &&
            bills.where((b) => b['status'] == 'ordered').isEmpty)
          const Padding(
            padding: EdgeInsets.all(20),
            child: Text('No overdue purchases or pending deliveries.'),
          ),
        for (final b in [
          ...received.where(overdue),
          ...bills.where((b) => b['status'] == 'ordered'),
        ].take(8))
          billCard(b),
        const SizedBox(height: 20),
        const Text(
          'Recent purchases',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
        for (final b in bills.take(5)) billCard(b),
      ],
    );
  }

  Widget purchaseList() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      TextField(
        controller: search,
        decoration: const InputDecoration(
          hintText: 'Search supplier, invoice or item',
          prefixIcon: Icon(Icons.search),
        ),
        onChanged: (_) => setState(() {}),
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          SizedBox(
            width: 180,
            child: DropdownButtonFormField<String>(
              key: ValueKey(status),
              initialValue: status,
              decoration: const InputDecoration(labelText: 'Status'),
              items: const ['all', 'draft', 'ordered', 'received', 'cancelled']
                  .map(
                    (s) => DropdownMenuItem(
                      value: s,
                      child: Text(s.toUpperCase()),
                    ),
                  )
                  .toList(),
              onChanged: (v) => setState(() => status = v ?? 'all'),
            ),
          ),
          SizedBox(
            width: 230,
            child: DropdownButtonFormField<String>(
              key: ValueKey(supplierId),
              initialValue: supplierId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Supplier'),
              items: [
                const DropdownMenuItem<String>(
                  value: null,
                  child: Text('All suppliers'),
                ),
                ...suppliers.map(
                  (s) => DropdownMenuItem(
                    value: '${s['id']}',
                    child: Text(
                      '${s['name']}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
              onChanged: (v) => setState(() => supplierId = v),
            ),
          ),
          SizedBox(
            width: 180,
            child: TextField(
              controller: from,
              decoration: const InputDecoration(labelText: 'From · YYYY-MM-DD'),
            ),
          ),
          SizedBox(
            width: 180,
            child: TextField(
              controller: to,
              decoration: const InputDecoration(labelText: 'To · YYYY-MM-DD'),
            ),
          ),
          OutlinedButton(
            onPressed: () {
              final a = from.text.trim(), b = to.text.trim();
              if ((a.isNotEmpty &&
                      (DateTime.tryParse(a) == null ||
                          day(DateTime.parse(a)) != a)) ||
                  (b.isNotEmpty &&
                      (DateTime.tryParse(b) == null ||
                          day(DateTime.parse(b)) != b)) ||
                  (a.isNotEmpty && b.isNotEmpty && a.compareTo(b) > 0)) {
                message(context, 'Choose a valid date range.');
                return;
              }
              setState(() {});
            },
            child: const Text('Apply dates'),
          ),
          TextButton(
            onPressed: () => setState(() {
              search.clear();
              from.clear();
              to.clear();
              status = 'all';
              supplierId = null;
            }),
            child: const Text('Clear filters'),
          ),
        ],
      ),
      const SizedBox(height: 14),
      Text('${filtered.length} purchases'),
      if (filtered.isEmpty)
        const Padding(
          padding: EdgeInsets.all(30),
          child: Text('No matching purchases. Start with New purchase.'),
        ),
      for (final b in filtered.take(visibleLimit)) billCard(b),
      moreButton(filtered.length),
    ],
  );
  Widget supplierList() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Align(
        alignment: Alignment.centerRight,
        child: FilledButton.icon(
          onPressed: () async {
            await editPurchaseSupplier(context, widget.session);
            await load();
          },
          icon: const Icon(Icons.person_add_alt),
          label: const Text('Add supplier'),
        ),
      ),
      if (suppliers.isEmpty)
        const Padding(
          padding: EdgeInsets.all(30),
          child: Text(
            'Save supplier contact details, then select them on purchase bills.',
          ),
        ),
      for (final s in suppliers.take(visibleLimit))
        Builder(
          builder: (context) {
            final ledger = bills
                .where(
                  (b) =>
                      b['supplier_id'] == s['id'] && b['status'] == 'received',
                )
                .toList();
            final due = ledger.fold<int>(
              0,
              (sum, b) => sum + number(balanceOf(b)['due_minor']),
            );
            final credit = ledger.fold<int>(
              0,
              (sum, b) => sum + number(balanceOf(b)['credit_minor']),
            );
            return Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${s['name']}',
                      style: const TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text('${s['phone'] ?? ''} ${s['gstin'] ?? ''}'),
                    if ('${s['address'] ?? ''}'.isNotEmpty)
                      Text('${s['address']}'),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 18,
                      runSpacing: 8,
                      children: [
                        Text(
                          'Due ${money(due)}',
                          style: const TextStyle(
                            color: Colors.deepOrange,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text('Refund pending ${money(credit)}'),
                        Text('${ledger.length} posted purchases'),
                        if (!enabled(s['is_active'])) const Text('INACTIVE'),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 10,
                      children: [
                        TextButton.icon(
                          onPressed: () => setState(() {
                            supplierId = '${s['id']}';
                            status = 'all';
                            search.clear();
                            from.clear();
                            to.clear();
                            section = 1;
                          }),
                          icon: const Icon(Icons.receipt_long_outlined),
                          label: const Text('View supplier ledger'),
                        ),
                        TextButton(
                          onPressed: () async {
                            await editPurchaseSupplier(
                              context,
                              widget.session,
                              supplier: s,
                            );
                            await load();
                          },
                          child: const Text('Edit contact'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      moreButton(suppliers.length),
    ],
  );
  List<Json> get stockRows {
    final keys = <String, Json>{};
    final quantities = <String, int>{};
    for (final b in bills.where((b) => b['status'] == 'received')) {
      for (final l in maps(b['lines'])) {
        keys['${l['purchase_item_id']}|${l['unit']}'] = l;
        quantities.update(
          '${l['purchase_item_id']}|${l['unit']}',
          (q) => q + number(l['quantity_milli']),
          ifAbsent: () => number(l['quantity_milli']),
        );
      }
    }
    for (final e in events) {
      for (final l in maps(e['lines'])) {
        keys['${l['purchase_item_id']}|${l['unit']}'] = l;
        final sign = e['kind'] == 'opening' ? 1 : -1;
        quantities.update(
          '${l['purchase_item_id']}|${l['unit']}',
          (q) => q + sign * number(l['quantity_milli']),
          ifAbsent: () => sign * number(l['quantity_milli']),
        );
      }
    }
    return keys.values
        .map(
          (l) => {
            ...l,
            'stock_milli':
                quantities['${l['purchase_item_id']}|${l['unit']}'] ?? 0,
          },
        )
        .toList()
      ..sort((a, b) => '${a['item_name']}'.compareTo('${b['item_name']}'));
  }

  int reorderLevel(Json row) {
    final item = items
        .where((i) => i['id'] == row['purchase_item_id'])
        .firstOrNull;
    final levels = item?['reorder_levels'];
    return levels is Map ? number(levels[row['unit']]) : 0;
  }

  Future<void> setReorderLevel(Json row) async {
    var text = purchaseQty(reorderLevel(row));
    String? error;
    bool saving = false;
    await showDialog<void>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (dialog, refresh) => AlertDialog(
          title: Text('Low-stock alert · ${row['item_name']}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                initialValue: text,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: 'Alert when stock reaches (${row['unit']})',
                ),
                onChanged: (v) => text = v,
              ),
              const SizedBox(height: 12),
              const Text('Set 0 to show only out-of-stock alerts.'),
              if (error != null)
                Text(error!, style: const TextStyle(color: Colors.red)),
            ],
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
                        final level = purchaseDecimal(text, scale: 1000);
                        if (level > 100000000) {
                          throw ApiFailure(422, 'Reorder level is too large.');
                        }
                        final item = items.firstWhere(
                          (i) => i['id'] == row['purchase_item_id'],
                        );
                        final levels = <String, dynamic>{
                          if (item['reorder_levels'] is Map)
                            ...Map<String, dynamic>.from(
                              item['reorder_levels'] as Map,
                            ),
                          '${row['unit']}': level,
                        };
                        await widget.session.mutate('purchase_items', {
                          ...item,
                          'reorder_levels': levels,
                        });
                        if (dialog.mounted) Navigator.pop(dialog);
                      } catch (e) {
                        if (dialog.mounted) {
                          refresh(() {
                            error = '$e';
                            saving = false;
                          });
                        }
                      }
                    },
              child: Text(saving ? 'Saving...' : 'Save alert'),
            ),
          ],
        ),
      ),
    );
  }

  Widget stockList() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'Raw-material stock',
        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: 8),
      const Text(
        'Received purchases + opening stock − returns − kitchen consumption − wastage. Units are tracked separately; record consumption to keep the balance accurate.',
      ),
      const SizedBox(height: 18),
      Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          for (final action in [
            ('opening', 'Opening stock'),
            ('usage', 'Kitchen consumption'),
            ('waste', 'Wastage'),
          ])
            OutlinedButton(
              onPressed: () async {
                await purchaseActionDialog(
                  context,
                  widget.session,
                  action.$1,
                  items: items,
                );
                await load();
              },
              child: Text(action.$2),
            ),
        ],
      ),
      const SizedBox(height: 18),
      if (stockRows.isEmpty)
        const Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Receive a purchase or record opening stock to start the material ledger.',
          ),
        ),
      for (final row in stockRows.take(visibleLimit))
        Card(
          child: ListTile(
            onTap: () => setReorderLevel(row),
            leading: Icon(
              Icons.inventory_2_outlined,
              color: number(row['stock_milli']) <= reorderLevel(row)
                  ? Colors.deepOrange
                  : accent,
            ),
            title: Text('${row['item_name']}'),
            subtitle: Text(
              number(row['stock_milli']) == 0
                  ? 'OUT OF STOCK · Tap to set alert'
                  : number(row['stock_milli']) <= reorderLevel(row)
                  ? 'LOW STOCK · Reorder level ${purchaseQty(reorderLevel(row))} ${row['unit']}'
                  : 'Available · Tap to set low-stock alert',
            ),
            trailing: Text(
              '${purchaseQty(row['stock_milli'])} ${row['unit']}',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ),
      moreButton(stockRows.length),
    ],
  );
  Widget activity() => Column(
    children: [
      if (events.isEmpty)
        const Padding(
          padding: EdgeInsets.all(30),
          child: Text(
            'Your purchase payments, returns and stock actions appear here.',
          ),
        ),
      for (final e
          in (events.toList()..sort(
                (a, b) => '${b['created_at']}'.compareTo('${a['created_at']}'),
              ))
              .take(visibleLimit))
        Card(
          child: ListTile(
            title: Text('${e['kind']}'.toUpperCase()),
            subtitle: Text(
              '${e['date']} · ${e['note'] ?? ''}\n${maps(e['lines']).map((l) => '${l['item_name']}: ${purchaseQty(l['quantity_milli'])} ${l['unit']}').join(', ')}',
            ),
            trailing: Text(money(e['amount_minor'])),
            onTap: e['bill_id'] == null
                ? null
                : () => openPage(
                    context,
                    PurchaseBillDetails(widget.session, '${e['bill_id']}'),
                  ),
          ),
        ),
      moreButton(events.length),
    ],
  );
  Future<void> report() async {
    if (section == 3) {
      await exportPurchaseReport(
        context,
        widget.session,
        'Raw-material stock',
        stockRows
            .map(
              (r) => [
                '${r['item_name']}',
                (purchaseQty(r['stock_milli'])),
                '${r['unit']}',
              ],
            )
            .toList(),
        ['Material', 'Available quantity', 'Unit'],
      );
      return;
    }
    final data = (section == 1 ? filtered : bills).map((b) {
      final balance = balanceOf(b);
      return [
        '${b['purchase_date']}',
        '${b['supplier_name']}',
        '${b['invoice_number'] ?? ''}',
        '${b['status']}',
        '${number(b['total_minor']) / 100}',
        '${number(balance['due_minor']) / 100}',
        '${number(balance['credit_minor']) / 100}',
      ];
    }).toList();
    await exportPurchaseReport(
      context,
      widget.session,
      'Purchases & supplier balances',
      data,
      [
        'Date',
        'Supplier',
        'Invoice',
        'Status',
        'Total (Rs.)',
        'Due (Rs.)',
        'Refund pending (Rs.)',
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Purchasing'),
      actions: [
        IconButton(
          tooltip: 'Refresh purchases',
          onPressed: load,
          icon: const Icon(Icons.refresh),
        ),
        IconButton(
          tooltip: 'Export purchase report',
          onPressed: loading ? null : report,
          icon: const Icon(Icons.picture_as_pdf_outlined),
        ),
        if (MediaQuery.sizeOf(context).width < 600)
          IconButton(
            tooltip: 'New purchase',
            onPressed: loading ? null : newPurchase,
            icon: const Icon(Icons.add_circle_outline),
          )
        else
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton.icon(
              onPressed: loading ? null : newPurchase,
              icon: const Icon(Icons.add),
              label: const Text('New purchase'),
            ),
          ),
      ],
    ),
    body: loading
        ? const Center(child: CircularProgressIndicator())
        : Column(
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Row(
                  children: [
                    for (final entry in [
                      (0, 'Overview'),
                      (1, 'Purchase bills'),
                      (2, 'Suppliers'),
                      (3, 'Material stock'),
                      (4, 'Activity'),
                    ])
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(entry.$2),
                          selected: section == entry.$1,
                          onSelected: (_) => setState(() => section = entry.$1),
                        ),
                      ),
                    TextButton(
                      onPressed: () async {
                        await openPage(
                          context,
                          PurchasesPage(widget.session, catalogOnly: true),
                        );
                        await load();
                      },
                      child: const Text('Items & categories'),
                    ),
                    TextButton(
                      onPressed: () => openPage(
                        context,
                        PurchaseHistoryPage(widget.session, items, categories),
                      ),
                      child: const Text('Legacy history'),
                    ),
                  ],
                ),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    error!,
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    switch (section) {
                      0 => overview(),
                      1 => purchaseList(),
                      2 => supplierList(),
                      3 => stockList(),
                      _ => activity(),
                    },
                  ],
                ),
              ),
            ],
          ),
  );
}
