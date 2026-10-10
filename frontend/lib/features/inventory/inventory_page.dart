import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/session.dart';
import '../../ui/shared.dart';

class InventoryPage extends StatefulWidget {
  final Session session;
  const InventoryPage(this.session, {super.key});

  @override
  State<InventoryPage> createState() => _InventoryPageState();
}

class _InventoryPageState extends State<InventoryPage> {
  List<Json> items = [];
  List<Json> expenses = [];
  bool busy = true;
  int section = 0;
  DateTime? expenseDate;

  @override
  void initState() {
    super.initState();
    widget.session.watch('inventory_items').addListener(load);
    widget.session.watch('expenses').addListener(load);
    load();
  }

  @override
  void dispose() {
    widget.session.watch('inventory_items').removeListener(load);
    widget.session.watch('expenses').removeListener(load);
    super.dispose();
  }

  Future<void> load() async {
    final values = await Future.wait([
      widget.session.local!.list('inventory_items', limit: 1000),
      widget.session.local!.list('expenses', limit: 1000),
    ]);
    if (!mounted) return;
    setState(() {
      items = values[0]..sort(_newestFirst);
      expenses = values[1]..sort(_newestFirst);
      busy = false;
    });
  }

  int _newestFirst(Json a, Json b) => _recordedAt(b).compareTo(_recordedAt(a));

  Future<void> addItem() async {
    var title = '';
    var quantity = '';
    var unit = 'pcs';
    var note = '';
    final draft = await showDialog<Json>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Add kitchen item'),
          content: SizedBox(
            width: 390,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    autofocus: true,
                    textCapitalization: TextCapitalization.words,
                    onChanged: (value) => title = value,
                    decoration: const InputDecoration(
                      labelText: 'Item title',
                      hintText: 'For example: Steel serving spoon',
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    keyboardType: TextInputType.number,
                    onChanged: (value) => quantity = value,
                    decoration: const InputDecoration(
                      labelText: 'Opening quantity',
                      hintText: 'For example: 24',
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    textCapitalization: TextCapitalization.words,
                    initialValue: unit,
                    onChanged: (value) => unit = value,
                    decoration: const InputDecoration(labelText: 'Unit'),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    maxLines: 2,
                    textCapitalization: TextCapitalization.sentences,
                    onChanged: (value) => note = value,
                    decoration: const InputDecoration(
                      labelText: 'Opening note (optional)',
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, {
                'title': title.trim(),
                'quantity': quantity.trim(),
                'unit': unit.trim(),
                'note': note.trim(),
              }),
              child: const Text('Save item'),
            ),
          ],
        ),
      ),
    );
    if (draft == null || !mounted) return;
    final count = int.tryParse(draft['quantity'].toString());
    if (draft['title'].toString().isEmpty || count == null || count < 0) {
      message(context, 'Enter an item title and a valid quantity.');
      return;
    }
    final duplicate = items.any(
      (item) =>
          item['name'].toString().toLowerCase() ==
          draft['title'].toString().toLowerCase(),
    );
    if (duplicate) {
      message(
        context,
        'This kitchen item already exists. Open its card to record a new count.',
      );
      return;
    }
    try {
      await widget.session.createInventoryItem(
        name: draft['title'].toString(),
        quantity: count,
        unit: draft['unit'].toString(),
        note: draft['note'].toString(),
      );
      if (mounted) message(context, 'Kitchen item saved.');
    } catch (error) {
      if (mounted) message(context, error);
    }
  }

  Future<void> addExpense() async {
    var title = '';
    var amount = '';
    var note = '';
    final draft = await showDialog<Json>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Record general expense'),
        content: SizedBox(
          width: 390,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  autofocus: true,
                  textCapitalization: TextCapitalization.sentences,
                  onChanged: (value) => title = value,
                  decoration: const InputDecoration(
                    labelText: 'Expense title',
                    hintText: 'For example: Gas cylinder refill',
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  onChanged: (value) => amount = value,
                  decoration: const InputDecoration(
                    labelText: 'Amount (₹)',
                    hintText: 'For example: 850',
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  maxLines: 2,
                  textCapitalization: TextCapitalization.sentences,
                  onChanged: (value) => note = value,
                  decoration: const InputDecoration(
                    labelText: 'Note (optional)',
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, {
              'title': title.trim(),
              'amount': amount.trim(),
              'note': note.trim(),
            }),
            child: const Text('Save expense'),
          ),
        ],
      ),
    );
    if (draft == null || !mounted) return;
    final parsedAmount = double.tryParse(draft['amount'].toString());
    final amountMinor = parsedAmount == null
        ? -1
        : (parsedAmount * 100).round();
    if (draft['title'].toString().isEmpty || amountMinor < 0) {
      message(context, 'Enter an expense title and valid amount.');
      return;
    }
    try {
      await widget.session.mutate('expenses', {
        'title': draft['title'],
        'amount_minor': amountMinor,
        'expense_date': day(indiaNow()),
        if (draft['note'].toString().isNotEmpty) 'notes': draft['note'],
      });
      if (mounted) message(context, 'Expense saved.');
    } catch (error) {
      if (mounted) message(context, error);
    }
  }

  Future<void> pickExpenseDate() async {
    final selected = await showDatePicker(
      context: context,
      initialDate: expenseDate ?? indiaNow(),
      firstDate: DateTime(2020),
      lastDate: indiaNow().add(const Duration(days: 365)),
    );
    if (selected != null && mounted) setState(() => expenseDate = selected);
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 620;
    final action = section == 0 ? addItem : addExpense;
    final label = section == 0 ? 'Add kitchen item' : 'Add expense';
    return Scaffold(
      appBar: AppBar(
        title: const Text('Inventory'),
        actions: [
          if (compact)
            IconButton(
              tooltip: label,
              onPressed: action,
              icon: const Icon(Icons.add),
            )
          else
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: FilledButton.icon(
                onPressed: action,
                icon: const Icon(Icons.add, size: 18),
                label: Text(label),
              ),
            ),
        ],
      ),
      body: busy
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(
                        value: 0,
                        icon: Icon(Icons.kitchen_outlined),
                        label: Text('Kitchen items'),
                      ),
                      ButtonSegment(
                        value: 1,
                        icon: Icon(Icons.receipt_long_outlined),
                        label: Text('General expenses'),
                      ),
                    ],
                    selected: {section},
                    onSelectionChanged: (value) =>
                        setState(() => section = value.first),
                  ),
                ),
                Expanded(
                  child: section == 0
                      ? _InventoryItems(
                          items: items,
                          onAdd: addItem,
                          onOpen: (item) async {
                            await openPage(
                              context,
                              InventoryItemPage(widget.session, item),
                            );
                            if (mounted) await load();
                          },
                        )
                      : _Expenses(
                          expenses: expenseDate == null
                              ? expenses
                              : expenses
                                    .where(
                                      (expense) =>
                                          expense['expense_date'].toString() ==
                                          day(expenseDate!),
                                    )
                                    .toList(),
                          hasSavedExpenses: expenses.isNotEmpty,
                          selectedDate: expenseDate,
                          onPickDate: pickExpenseDate,
                          onClearDate: () => setState(() => expenseDate = null),
                          onAdd: addExpense,
                        ),
                ),
              ],
            ),
    );
  }
}

class _InventoryItems extends StatelessWidget {
  final List<Json> items;
  final VoidCallback onAdd;
  final ValueChanged<Json> onOpen;
  const _InventoryItems({
    required this.items,
    required this.onAdd,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) => items.isEmpty
      ? EmptyState(
          'No kitchen items',
          'Add utensils, serving items and kitchen equipment. Each count you save will remain in its history.',
          icon: Icons.inventory_2_outlined,
          action: FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add),
            label: const Text('Add kitchen item'),
          ),
        )
      : GridView.builder(
          padding: const EdgeInsets.all(20),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 290,
            mainAxisExtent: 158,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
          ),
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            return Card(
              color: Colors.white,
              surfaceTintColor: Colors.white,
              elevation: 1,
              shadowColor: accent.withValues(alpha: 0.16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: const BorderSide(color: line),
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => onOpen(item),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.kitchen_outlined, color: accent),
                      const Spacer(),
                      Text(
                        item['name'].toString(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        'Current: ${item['current_quantity'] ?? 0} ${item['unit'] ?? 'pcs'}',
                        style: const TextStyle(
                          color: darkIndigo,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'Updated ${_shortDate(_recordedAt(item))}',
                        style: const TextStyle(
                          color: secondaryText,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
}

class _Expenses extends StatelessWidget {
  final List<Json> expenses;
  final bool hasSavedExpenses;
  final DateTime? selectedDate;
  final Future<void> Function() onPickDate;
  final VoidCallback onClearDate;
  final VoidCallback onAdd;
  const _Expenses({
    required this.expenses,
    required this.hasSavedExpenses,
    required this.selectedDate,
    required this.onPickDate,
    required this.onClearDate,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    final total = expenses.fold<int>(
      0,
      (value, row) => value + number(row['amount_minor']),
    );
    if (!hasSavedExpenses) {
      return EmptyState(
        'No general expenses',
        'Record any non-purchase expense here, such as gas, repairs or supplies.',
        icon: Icons.receipt_long_outlined,
        action: FilledButton.icon(
          onPressed: onAdd,
          icon: const Icon(Icons.add),
          label: const Text('Add expense'),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton.icon(
              onPressed: onPickDate,
              icon: const Icon(Icons.calendar_today_outlined, size: 17),
              label: Text(
                selectedDate == null
                    ? 'Filter by date'
                    : _shortDate(selectedDate!),
              ),
            ),
            if (selectedDate != null)
              TextButton.icon(
                onPressed: onClearDate,
                icon: const Icon(Icons.clear, size: 17),
                label: const Text('All dates'),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Card(
          color: lightIndigo,
          surfaceTintColor: lightIndigo,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                const Icon(
                  Icons.account_balance_wallet_outlined,
                  color: accent,
                ),
                const SizedBox(width: 12),
                const Expanded(child: Text('Total recorded expenses')),
                Text(
                  money(total),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (expenses.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: Text('No expenses were recorded on this date.'),
            ),
          ),
        for (final expense in expenses)
          Card(
            elevation: 0,
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 6,
              ),
              leading: const CircleAvatar(
                backgroundColor: lightIndigo,
                foregroundColor: accent,
                child: Icon(Icons.receipt_long_outlined),
              ),
              title: Text(
                expense['title'].toString(),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(
                '${expense['expense_date'] ?? _shortDate(_recordedAt(expense))}${expense['notes'].toString().trim().isEmpty ? '' : '\n${expense['notes']}'}',
              ),
              isThreeLine: expense['notes'].toString().trim().isNotEmpty,
              trailing: Text(
                money(expense['amount_minor']),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ),
      ],
    );
  }
}

class InventoryItemPage extends StatefulWidget {
  final Session session;
  final Json item;
  const InventoryItemPage(this.session, this.item, {super.key});

  @override
  State<InventoryItemPage> createState() => _InventoryItemPageState();
}

class _InventoryItemPageState extends State<InventoryItemPage> {
  List<Json> history = [];
  Json? item;
  bool busy = true;

  @override
  void initState() {
    super.initState();
    item = widget.item;
    widget.session.watch('inventory_items').addListener(load);
    widget.session.watch('inventory_entries').addListener(load);
    load();
  }

  @override
  void dispose() {
    widget.session.watch('inventory_items').removeListener(load);
    widget.session.watch('inventory_entries').removeListener(load);
    super.dispose();
  }

  Future<void> load() async {
    final id = widget.item['id'].toString();
    final values = await Future.wait([
      widget.session.local!.get('inventory_items', id),
      widget.session.local!.list(
        'inventory_entries',
        limit: 1000,
        filters: {'inventory_item_id': id},
      ),
    ]);
    if (!mounted) return;
    final current = values[0] as Json?;
    final rows = values[1] as List<Json>;
    setState(() {
      item = current ?? item;
      history = rows..sort((a, b) => _recordedAt(b).compareTo(_recordedAt(a)));
      busy = false;
    });
  }

  Future<void> recordCount() async {
    var quantity = '';
    var note = '';
    final draft = await showDialog<Json>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Record current quantity'),
        content: SizedBox(
          width: 380,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Saving a count now creates a dated history entry for ${item?['name'] ?? ''}.',
                ),
                const SizedBox(height: 14),
                TextField(
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  onChanged: (value) => quantity = value,
                  decoration: InputDecoration(
                    labelText: 'Current quantity (${item?['unit'] ?? 'pcs'})',
                    hintText: 'For example: ${item?['current_quantity'] ?? 0}',
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  maxLines: 2,
                  textCapitalization: TextCapitalization.sentences,
                  onChanged: (value) => note = value,
                  decoration: const InputDecoration(
                    labelText: 'Note (optional)',
                    hintText: 'For example: After dinner service',
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, {
              'quantity': quantity.trim(),
              'note': note.trim(),
            }),
            child: const Text('Save now'),
          ),
        ],
      ),
    );
    if (draft == null || !mounted) return;
    final count = int.tryParse(draft['quantity'].toString());
    if (count == null || count < 0) {
      message(context, 'Enter a valid quantity.');
      return;
    }
    try {
      await widget.session.recordInventoryQuantity(
        item!,
        quantity: count,
        note: draft['note'].toString(),
      );
      if (mounted) message(context, 'Current quantity recorded.');
    } catch (error) {
      if (mounted) message(context, error);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(item?['name'].toString() ?? 'Kitchen item')),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: busy || item == null ? null : recordCount,
      icon: const Icon(Icons.add_chart_outlined),
      label: const Text('Record now'),
    ),
    body: busy
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Card(
                color: lightIndigo,
                surfaceTintColor: lightIndigo,
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Current quantity',
                        style: TextStyle(color: secondaryText),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${item?['current_quantity'] ?? 0} ${item?['unit'] ?? 'pcs'}',
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                      const SizedBox(height: 7),
                      Text(
                        'Last recorded ${_longDate(_recordedAt(item ?? {}))}',
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Quantity history',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 10),
              if (history.isEmpty)
                const EmptyState(
                  'No count history',
                  'Record the quantity to create the first history entry.',
                )
              else
                for (final entry in history)
                  Card(
                    elevation: 0,
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      leading: const CircleAvatar(
                        backgroundColor: lightIndigo,
                        foregroundColor: accent,
                        child: Icon(Icons.history),
                      ),
                      title: Text(
                        '${entry['quantity']} ${item?['unit'] ?? 'pcs'}',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      subtitle: Text(
                        '${_longDate(_recordedAt(entry))}${entry['note'].toString().trim().isEmpty ? '' : '\n${entry['note']}'}',
                      ),
                      isThreeLine: entry['note'].toString().trim().isNotEmpty,
                    ),
                  ),
              const SizedBox(height: 84),
            ],
          ),
  );
}

DateTime _recordedAt(Json row) =>
    indiaDateTime(
      row['recorded_at'] ??
          row['last_recorded_at'] ??
          row['expense_date'] ??
          row['created_at'] ??
          row['updated_at'],
    ) ??
    DateTime.fromMillisecondsSinceEpoch(0);

String _shortDate(DateTime value) =>
    '${value.day.toString().padLeft(2, '0')} ${_month(value.month)} ${value.year}';

String _longDate(DateTime value) {
  final hour = value.hour % 12 == 0 ? 12 : value.hour % 12;
  return '${_shortDate(value)} · $hour:${value.minute.toString().padLeft(2, '0')} ${value.hour >= 12 ? 'PM' : 'AM'}';
}

String _month(int month) => const [
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
][month - 1];
