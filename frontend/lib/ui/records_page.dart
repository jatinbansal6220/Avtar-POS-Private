import 'dart:async';

import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/session.dart';
import '../core/developer_reset_guard.dart';
import '../features/registry.dart';
import 'receipt.dart';
import 'record_editor_page.dart';
import 'shared.dart';
import 'staff.dart';

abstract class _HistoryEntry {
  const _HistoryEntry();
}

class _HistoryDate extends _HistoryEntry {
  final String label;
  const _HistoryDate(this.label);
}

class _HistoryBill extends _HistoryEntry {
  final Json bill;
  const _HistoryBill(this.bill);
}

class RecordsPage extends StatefulWidget {
  final Session session;
  final String resource;
  final bool picker;
  final Json filters;
  const RecordsPage(
    this.session,
    this.resource, {
    super.key,
    this.picker = false,
    this.filters = const {},
  });
  @override
  State<RecordsPage> createState() => _RecordsPageState();
}

class _RecordsPageState extends State<RecordsPage> {
  static const pageSize = 50;
  final scroll = ScrollController();
  final search = TextEditingController();
  final from = TextEditingController();
  final to = TextEditingController();
  final table = TextEditingController();
  final minAmount = TextEditingController();
  final maxAmount = TextEditingController();
  Timer? debounce;
  List<Json> rows = [];
  String? error;
  bool busy = false;
  bool more = true;
  bool historyLoading = false;
  bool historyMore = true;
  int generation = 0;
  List<Json> invoiceTables = [];
  String? invoiceScope;

  @override
  void initState() {
    super.initState();
    unawaited(
      load(reset: true).then((_) {
        if (mounted && widget.resource == 'bills') {
          unawaited(loadBillHistory());
        }
      }),
    );
    if (widget.resource == 'bills') unawaited(loadInvoiceTables());
    scroll.addListener(() {
      // Start the next lightweight page before the cashier reaches the end.
      if (scroll.position.extentAfter < 800 && more && !busy) load();
      if (widget.resource == 'bills' &&
          scroll.position.extentAfter < 1200 &&
          !more &&
          historyMore &&
          !historyLoading) {
        unawaited(loadBillHistory());
      }
    });
  }

  Future<void> loadInvoiceTables() async {
    try {
      final values = await widget.session.local!.list('tables', limit: 100);
      values.sort((left, right) {
        final leftNumber = '${left['table_number'] ?? ''}';
        final rightNumber = '${right['table_number'] ?? ''}';
        final leftValue = int.tryParse(
          leftNumber.replaceAll(RegExp(r'[^0-9]'), ''),
        );
        final rightValue = int.tryParse(
          rightNumber.replaceAll(RegExp(r'[^0-9]'), ''),
        );
        if (leftValue != null && rightValue != null) {
          return leftValue.compareTo(rightValue);
        }
        return leftNumber.compareTo(rightNumber);
      });
      if (mounted) setState(() => invoiceTables = values);
    } catch (_) {
      // Invoice history remains usable through the typed table filter when
      // the local table catalogue has not arrived yet.
    }
  }

  Future<void> selectInvoiceScope(String? scope, {String? tableNumber}) async {
    setState(() {
      invoiceScope = scope;
      table.text = tableNumber ?? '';
    });
    await load(reset: true);
  }

  /// A source/table selection is a drill-down within the same invoice page.
  /// This makes the history use the complete screen and gives the cashier one
  /// predictable way to return to the invoice dashboard.
  Future<void> backToInvoiceDashboard() async {
    setState(() {
      invoiceScope = null;
      table.clear();
    });
    await load(reset: true);
    if (scroll.hasClients) {
      await scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> clearInvoiceFilters() async {
    setState(() {
      invoiceScope = null;
      search.clear();
      from.clear();
      to.clear();
      table.clear();
      minAmount.clear();
      maxAmount.clear();
    });
    await load(reset: true);
  }

  @override
  void dispose() {
    debounce?.cancel();
    scroll.dispose();
    search.dispose();
    for (final controller in [from, to, table, minAmount, maxAmount]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> load({bool reset = false}) async {
    if (busy && !reset) return;
    final request = reset ? ++generation : generation;
    if (reset) {
      rows = [];
      more = true;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final filters = <String, dynamic>{
        ...widget.filters,
        'from': from.text,
        'to': to.text,
        'table_number': table.text,
        if (invoiceScope != null) 'invoice_scope': invoiceScope,
        if (minAmount.text.isNotEmpty)
          'min_amount': ((double.tryParse(minAmount.text) ?? 0) * 100).round(),
        if (maxAmount.text.isNotEmpty)
          'max_amount': ((double.tryParse(maxAmount.text) ?? 0) * 100).round(),
      };
      final data = await widget.session.local!.list(
        widget.resource,
        query: search.text,
        offset: rows.length,
        limit: pageSize,
        filters: filters,
      );
      if (mounted && request == generation) {
        setState(() {
          rows.addAll(data);
          more = data.length == pageSize;
        });
      }
    } catch (exception) {
      if (mounted && request == generation) {
        setState(() => error = exception.toString());
      }
    } finally {
      if (mounted && request == generation) {
        setState(() => busy = false);
      }
    }
  }

  /// The first page is fetched on open; later pages are fetched only near the
  /// end of the invoice list. Rendering always reads SQLite, never waits for
  /// the network, so the history remains smooth on a slow connection.
  Future<void> loadBillHistory() async {
    if (historyLoading || !historyMore) return;
    historyLoading = true;
    final hasMore = await widget.session.hydrateBillsHistoryPage();
    if (mounted && hasMore != null) {
      setState(() => historyMore = hasMore);
      if (!busy) await load();
    }
    historyLoading = false;
  }

  Future<void> tap(Json row) async {
    if (widget.picker) {
      Navigator.pop(context, row);
      return;
    }
    if (widget.resource == 'bills') {
      await openPage(context, ReceiptPage(widget.session, row));
    } else if (widget.resource == 'staff') {
      await openPage(context, StaffPage(widget.session, row));
    } else {
      await openPage(
        context,
        RecordEditor(widget.session, widget.resource, row: row),
      );
    }
    if (mounted) load(reset: true);
  }

  String billDate(Json bill) {
    final receipt = bill['receipt'];
    final raw =
        (receipt is Map ? receipt['generated_at'] : null) ??
        bill['generated_at'] ??
        bill['created_at'] ??
        bill['date'] ??
        '';
    return raw.toString();
  }

  String dateKey(Json bill) {
    final value = billDate(bill);
    return value.length >= 10 ? value.substring(0, 10) : 'Unknown date';
  }

  String dateLabel(String key) {
    if (key == 'Unknown date') return key;
    final value = DateTime.tryParse(key);
    if (value == null) return key;
    final today = indiaNow();
    final onlyDate = DateTime(value.year, value.month, value.day);
    final todayDate = DateTime(today.year, today.month, today.day);
    if (onlyDate == todayDate) return 'Today';
    if (onlyDate == todayDate.subtract(const Duration(days: 1))) {
      return 'Yesterday';
    }
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${value.day} ${months[value.month - 1]} ${value.year}';
  }

  String timeLabel(Json bill) {
    final value = indiaDateTime(billDate(bill));
    if (value == null) return billDate(bill);
    final hour = value.hour % 12 == 0 ? 12 : value.hour % 12;
    final minute = value.minute.toString().padLeft(2, '0');
    return '$hour:$minute${value.hour >= 12 ? ' PM' : ' AM'}';
  }

  List<_HistoryEntry> get historyEntries {
    final result = <_HistoryEntry>[];
    String previous = '';
    for (final bill in rows) {
      final key = dateKey(bill);
      if (key != previous) {
        result.add(_HistoryDate(dateLabel(key)));
        previous = key;
      }
      result.add(_HistoryBill(bill));
    }
    return result;
  }

  String billSource(Json bill) {
    final receipt = bill['receipt'];
    final orderType =
        bill['order_type'] ?? (receipt is Map ? receipt['order_type'] : null);
    final terminal =
        '${bill['source_terminal_label'] ?? (receipt is Map ? receipt['source_terminal_label'] : '')}'
            .trim();
    String withTerminal(String source) =>
        terminal.isEmpty ? source : '$source · $terminal';
    if (orderType == 'online') {
      return withTerminal(
        (bill['online_platform_name'] ??
                (receipt is Map ? receipt['online_platform_name'] : null) ??
                bill['online_platform'] ??
                (receipt is Map ? receipt['online_platform'] : null) ??
                'Online order')
            .toString(),
      );
    }
    if (orderType == 'dine_in') {
      return withTerminal('Table ${bill['table_number'] ?? '—'}');
    }
    if (orderType == 'pos') return withTerminal('Menu POS');
    return withTerminal('Takeaway');
  }

  String itemSummary(Json bill) {
    final receipt = bill['receipt'];
    final items = maps(receipt is Map ? receipt['items'] : bill['items']);
    if (items.isEmpty) return 'No item detail saved';
    final labels = items.take(2).map((item) {
      return '${item['item_name']} × ${number(item['quantity'])}';
    }).toList();
    if (items.length > labels.length) {
      labels.add('+${items.length - labels.length} more');
    }
    return labels.join(', ');
  }

  Future<void> resetInvoiceDeleteCode() async {
    final settings =
        (await widget.session.local!.list('settings', limit: 1)).firstOrNull ??
        <String, dynamic>{};
    final hasExisting =
        '${settings['invoice_delete_code_hash'] ?? ''}'.isNotEmpty;
    if (!mounted) return;
    // First-time setup must be reachable before a recovery code is needed.
    if (hasExisting && !await requireDeveloperResetCode(context)) return;
    if (!mounted) return;
    final current = TextEditingController();
    final next = TextEditingController();
    final confirm = TextEditingController();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          hasExisting ? 'Reset owner access code' : 'Set owner access code',
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'This code unlocks Analytics, Day Closing and invoice edit/delete.',
            ),
            const SizedBox(height: 12),
            if (hasExisting)
              TextField(
                controller: current,
                obscureText: true,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Current code'),
              ),
            TextField(
              controller: next,
              obscureText: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'New 4 to 8 digit code',
              ),
            ),
            TextField(
              controller: confirm,
              obscureText: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Confirm new code'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Save code'),
          ),
        ],
      ),
    );
    final currentValue = current.text;
    final nextValue = next.text;
    final confirmValue = confirm.text;
    current.dispose();
    next.dispose();
    confirm.dispose();
    if (accepted != true) return;
    if (nextValue != confirmValue) {
      if (mounted)
        message(context, 'New deletion code and confirmation do not match.');
      return;
    }
    try {
      await widget.session.setInvoiceDeleteCode(
        currentCode: currentValue,
        newCode: nextValue,
      );
      if (mounted)
        message(context, 'Invoice deletion code saved for this restaurant.');
    } catch (error) {
      if (mounted) message(context, error);
    }
  }

  Future<void> deleteBill(Json bill) async {
    final code = TextEditingController();
    final action = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete invoice?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'This removes the invoice from history. The settled order and table status will not reopen.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: code,
              autofocus: true,
              obscureText: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Invoice deletion code',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, 'reset'),
            child: const Text('Set / reset code'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(dialogContext, 'delete'),
            icon: const Icon(Icons.delete_outline),
            label: const Text('Delete invoice'),
          ),
        ],
      ),
    );
    final entered = code.text;
    code.dispose();
    if (action == 'reset') {
      await resetInvoiceDeleteCode();
      return;
    }
    if (action != 'delete') return;
    try {
      await widget.session.deleteInvoice(bill, entered);
      if (!mounted) return;
      await load(reset: true);
      if (mounted) message(context, 'Invoice deleted from history.');
    } catch (error) {
      if (mounted) message(context, error);
    }
  }

  Widget billTile(Json bill) => Card(
    elevation: 0,
    margin: const EdgeInsets.only(bottom: 8),
    child: ListTile(
      dense: true,
      minVerticalPadding: 10,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      title: Text(
        billSource(bill),
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${timeLabel(bill)} • ${bill['bill_number'] ?? 'Invoice'}'),
            const SizedBox(height: 3),
            Text(
              itemSummary(bill),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            money(bill['total_minor']),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          if (!widget.picker && widget.session.manager)
            IconButton(
              tooltip: 'Delete invoice',
              onPressed: () => deleteBill(bill),
              icon: const Icon(Icons.delete_outline, color: Colors.red),
            ),
          const SizedBox(width: 8),
          const Icon(Icons.chevron_right),
        ],
      ),
      onTap: () => tap(bill),
    ),
  );

  Widget genericTile(Json row) => Card(
    elevation: 0,
    margin: const EdgeInsets.only(bottom: 8),
    child: ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      title: Text(
        recordTitle(widget.resource, row),
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        [
          row['category'],
          row['role'],
          row['date'],
          row['supplier_name'],
          row['status'],
          if (row['is_active'] != null)
            !enabled(row['is_active']) ? 'Disabled' : 'Available',
        ].where((value) => value != null).join(' · '),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (row['price_minor'] != null ||
              row['total_minor'] != null ||
              row['amount_minor'] != null)
            Text(
              money(
                row['price_minor'] ?? row['total_minor'] ?? row['amount_minor'],
              ),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          const SizedBox(width: 12),
          const Icon(Icons.chevron_right),
        ],
      ),
      onTap: () => tap(row),
    ),
  );

  Widget invoiceScopeCard({
    required String label,
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
  }) => SizedBox(
    width: 132,
    child: Card(
      clipBehavior: Clip.antiAlias,
      color: selected ? Theme.of(context).colorScheme.primaryContainer : null,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 21),
              const SizedBox(height: 6),
              Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget invoiceSourceCards() => Padding(
    padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Invoice history', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        const Text(
          'Choose a source or table to see only its invoice history.',
          style: TextStyle(fontSize: 12, color: Colors.black54),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 2,
          children: [
            invoiceScopeCard(
              label: 'All invoices',
              icon: Icons.receipt_long_outlined,
              selected: invoiceScope == null && table.text.isEmpty,
              onTap: () => selectInvoiceScope(null),
            ),
            invoiceScopeCard(
              label: 'Online orders',
              icon: Icons.delivery_dining_outlined,
              selected: invoiceScope == 'online',
              onTap: () => selectInvoiceScope('online'),
            ),
            invoiceScopeCard(
              label: 'Takeaway',
              icon: Icons.takeout_dining_outlined,
              selected: invoiceScope == 'takeaway',
              onTap: () => selectInvoiceScope('takeaway'),
            ),
            invoiceScopeCard(
              label: 'Menu POS',
              icon: Icons.restaurant_menu_outlined,
              selected: invoiceScope == 'pos',
              onTap: () => selectInvoiceScope('pos'),
            ),
            invoiceScopeCard(
              label: 'Settlements',
              icon: Icons.price_check_outlined,
              selected: invoiceScope == 'settlement',
              onTap: () => selectInvoiceScope('settlement'),
            ),
          ],
        ),
        if (invoiceTables.isNotEmpty) ...[
          const SizedBox(height: 12),
          const Text(
            'Table-wise history',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 2,
            children: [
              for (final row in invoiceTables)
                invoiceScopeCard(
                  label: 'Table ${row['table_number']}',
                  icon: Icons.table_restaurant_outlined,
                  selected: table.text == '${row['table_number']}',
                  onTap: () => selectInvoiceScope(
                    null,
                    tableNumber: '${row['table_number']}',
                  ),
                ),
            ],
          ),
        ],
      ],
    ),
  );

  Widget invoiceScrollableBody(List<_HistoryEntry> entries, int length) {
    return CustomScrollView(
      controller: scroll,
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: TextField(
              controller: search,
              decoration: const InputDecoration(
                hintText: 'Bill number, name, phone, table or date',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (_) {
                debounce?.cancel();
                debounce = Timer(
                  const Duration(milliseconds: 250),
                  () => load(reset: true),
                );
              },
            ),
          ),
        ),
        SliverToBoxAdapter(child: invoiceSourceCards()),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final entry in [
                  (from, 'From YYYY-MM-DD'),
                  (to, 'To YYYY-MM-DD'),
                  (table, 'Table number'),
                  (minAmount, 'Min amount'),
                  (maxAmount, 'Max amount'),
                ])
                  SizedBox(
                    width: 170,
                    child: TextField(
                      controller: entry.$1,
                      decoration: InputDecoration(labelText: entry.$2),
                    ),
                  ),
                FilledButton(
                  onPressed: () => load(reset: true),
                  child: const Text('Apply filters'),
                ),
                OutlinedButton(
                  onPressed: clearInvoiceFilters,
                  child: const Text('Clear filters'),
                ),
              ],
            ),
          ),
        ),
        if (error != null)
          SliverToBoxAdapter(
            child: MaterialBanner(
              content: Text(error!),
              actions: [
                TextButton(
                  onPressed: () => load(reset: true),
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        if (length == 0 && !busy)
          SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyState(
              search.text.isNotEmpty ||
                      from.text.isNotEmpty ||
                      to.text.isNotEmpty ||
                      table.text.isNotEmpty
                  ? 'No matching bills'
                  : 'No bills yet',
              'Try another bill number, customer phone, table or date.',
              action: TextButton(
                onPressed: clearInvoiceFilters,
                child: const Text('Clear filters'),
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            sliver: SliverList.builder(
              itemCount: length + (more ? 1 : 0),
              itemBuilder: (context, index) {
                if (index == length) {
                  return SizedBox(
                    height: 56,
                    child: Center(
                      child: busy
                          ? const CircularProgressIndicator()
                          : const SizedBox.shrink(),
                    ),
                  );
                }
                final entry = entries[index];
                if (entry is _HistoryDate) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(2, 18, 2, 8),
                    child: Text(
                      entry.label,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  );
                }
                return billTile((entry as _HistoryBill).bill);
              },
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final bills = widget.resource == 'bills';
    final entries = bills ? historyEntries : const <_HistoryEntry>[];
    final length = bills ? entries.length : rows.length;
    final invoiceDrillDown =
        bills && (invoiceScope != null || table.text.trim().isNotEmpty);
    return Scaffold(
      appBar: AppBar(
        title: Text(titles[widget.resource] ?? widget.resource),
        leading: invoiceDrillDown
            ? IconButton(
                tooltip: 'Back to invoice dashboard',
                onPressed: backToInvoiceDashboard,
                icon: const Icon(Icons.arrow_back),
              )
            : null,
        actions: [
          if (bills && !widget.picker && widget.session.manager)
            IconButton(
              tooltip: 'Set or reset invoice deletion code',
              onPressed: resetInvoiceDeleteCode,
              icon: const Icon(Icons.password_outlined),
            ),
          if (!widget.picker && specs.containsKey(widget.resource))
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: FilledButton.icon(
                onPressed: () async {
                  await openPage(
                    context,
                    RecordEditor(
                      widget.session,
                      widget.resource,
                      initial: widget.filters,
                      hiddenFields:
                          widget.filters['staff_id'] != null &&
                              [
                                'payments',
                                'attendance',
                              ].contains(widget.resource)
                          ? const {'staff_id'}
                          : const {},
                    ),
                  );
                  if (mounted) load(reset: true);
                },
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add'),
              ),
            ),
        ],
      ),
      body: bills
          ? invoiceScrollableBody(entries, length)
          : Column(
              children: [
                if (bills) invoiceSourceCards(),
                if (bills)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final entry in [
                          (from, 'From YYYY-MM-DD'),
                          (to, 'To YYYY-MM-DD'),
                          (table, 'Table number'),
                          (minAmount, 'Min amount'),
                          (maxAmount, 'Max amount'),
                        ])
                          SizedBox(
                            width: 170,
                            child: TextField(
                              controller: entry.$1,
                              decoration: InputDecoration(labelText: entry.$2),
                            ),
                          ),
                        FilledButton(
                          onPressed: () => load(reset: true),
                          child: const Text('Apply filters'),
                        ),
                        OutlinedButton(
                          onPressed: clearInvoiceFilters,
                          child: const Text('Clear filters'),
                        ),
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: TextField(
                    controller: search,
                    decoration: const InputDecoration(
                      hintText: 'Search records',
                      prefixIcon: Icon(Icons.search),
                    ),
                    onChanged: (_) {
                      debounce?.cancel();
                      debounce = Timer(
                        const Duration(milliseconds: 250),
                        () => load(reset: true),
                      );
                    },
                  ),
                ),
                if (error != null)
                  MaterialBanner(
                    content: Text(error!),
                    actions: [
                      TextButton(
                        onPressed: () => load(reset: true),
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                Expanded(
                  child: length == 0 && !busy
                      ? const EmptyState(
                          'No records yet',
                          'Add your restaurant’s real data to get started.',
                        )
                      : ListView.builder(
                          controller: scroll,
                          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                          itemCount: length + (more ? 1 : 0),
                          itemBuilder: (context, index) {
                            if (index == length) {
                              return SizedBox(
                                height: 56,
                                child: Center(
                                  child: busy
                                      ? const CircularProgressIndicator()
                                      : const SizedBox.shrink(),
                                ),
                              );
                            }
                            if (!bills) return genericTile(rows[index]);
                            final entry = entries[index];
                            if (entry is _HistoryDate) {
                              return Padding(
                                padding: const EdgeInsets.fromLTRB(2, 18, 2, 8),
                                child: Text(
                                  entry.label,
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium,
                                ),
                              );
                            }
                            return billTile((entry as _HistoryBill).bill);
                          },
                        ),
                ),
              ],
            ),
    );
  }
}
