import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/session.dart';
import '../../ui/shared.dart';

class PurchaseHistoryPage extends StatefulWidget {
  final Session session;
  final List<Json> items;
  final List<Json> categories;
  const PurchaseHistoryPage(
    this.session,
    this.items,
    this.categories, {
    super.key,
  });

  @override
  State<PurchaseHistoryPage> createState() => _PurchaseHistoryPageState();
}

class _PurchaseHistoryPageState extends State<PurchaseHistoryPage> {
  final scroll = ScrollController();
  final from = TextEditingController();
  final to = TextEditingController();
  List<Json> rows = [];
  String? categoryId;
  String? itemId;
  bool busy = false;
  bool more = true;
  int generation = 0;
  String? error;

  @override
  void initState() {
    super.initState();
    load(reset: true);
    scroll.addListener(() {
      if (scroll.position.extentAfter < 700 && more && !busy) load();
    });
  }

  @override
  void dispose() {
    scroll.dispose();
    from.dispose();
    to.dispose();
    super.dispose();
  }

  List<String>? get selectedIds {
    if (itemId != null) return [itemId!];
    if (categoryId == null) return null;
    return widget.items
        .where((item) => item['category_id'].toString() == categoryId)
        .map((item) => item['id'].toString())
        .toList();
  }

  Future<void> load({bool reset = false}) async {
    if (busy && !reset) return;
    final start = from.text.trim(), end = to.text.trim();
    if ((start.isNotEmpty &&
            (DateTime.tryParse(start) == null ||
                day(DateTime.parse(start)) != start)) ||
        (end.isNotEmpty &&
            (DateTime.tryParse(end) == null ||
                day(DateTime.parse(end)) != end)) ||
        (start.isNotEmpty && end.isNotEmpty && start.compareTo(end) > 0)) {
      message(context, 'Choose a valid date range.');
      return;
    }
    final gen = reset ? ++generation : generation;
    if (reset) {
      rows = [];
      more = true;
    }
    setState(() => busy = true);
    final ids = selectedIds;
    try {
      final data = ids != null && ids.isEmpty
          ? <Json>[]
          : await widget.session.local!.list(
              'purchases',
              offset: rows.length,
              limit: 50,
              filters: {
                'from': from.text.trim(),
                'to': to.text.trim(),
                if (ids != null) 'purchase_item_ids': ids,
              },
            );
      if (mounted && gen == generation) {
        setState(() {
          rows.addAll(data);
          more = data.length == 50;
          busy = false;
          error = null;
        });
      }
    } catch (e) {
      if (mounted && gen == generation)
        setState(() {
          busy = false;
          error = '$e';
        });
    }
  }

  String time(Json row) {
    final value = indiaDateTime(row['created_at'] ?? row['updated_at']);
    if (value == null) return '';
    final hour = value.hour % 12 == 0 ? 12 : value.hour % 12;
    return hour.toString() +
        ':' +
        value.minute.toString().padLeft(2, '0') +
        (value.hour >= 12 ? ' PM' : ' AM');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Purchase history')),
    body: Column(
      children: [
        if (busy) const LinearProgressIndicator(),
        if (error != null)
          Text(error!, style: const TextStyle(color: Colors.red)),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              SizedBox(
                width: 155,
                child: TextField(
                  controller: from,
                  decoration: const InputDecoration(
                    labelText: 'From date',
                    hintText: 'YYYY-MM-DD',
                  ),
                ),
              ),
              SizedBox(
                width: 155,
                child: TextField(
                  controller: to,
                  decoration: const InputDecoration(
                    labelText: 'To date',
                    hintText: 'YYYY-MM-DD',
                  ),
                ),
              ),
              SizedBox(
                width: 180,
                child: DropdownButtonFormField<String?>(
                  value: categoryId,
                  decoration: const InputDecoration(labelText: 'Category'),
                  items: [
                    const DropdownMenuItem(
                      value: null,
                      child: Text('All categories'),
                    ),
                    ...widget.categories.map(
                      (category) => DropdownMenuItem(
                        value: category['id'].toString(),
                        child: Text(category['name'].toString()),
                      ),
                    ),
                  ],
                  onChanged: (value) => setState(() {
                    categoryId = value;
                    itemId = null;
                  }),
                ),
              ),
              SizedBox(
                width: 190,
                child: DropdownButtonFormField<String?>(
                  value: itemId,
                  decoration: const InputDecoration(labelText: 'Purchase item'),
                  items: [
                    const DropdownMenuItem(
                      value: null,
                      child: Text('All items'),
                    ),
                    ...widget.items
                        .where(
                          (item) =>
                              categoryId == null ||
                              item['category_id'].toString() == categoryId,
                        )
                        .map(
                          (item) => DropdownMenuItem(
                            value: item['id'].toString(),
                            child: Text(item['name'].toString()),
                          ),
                        ),
                  ],
                  onChanged: (value) => setState(() => itemId = value),
                ),
              ),
              FilledButton(
                onPressed: () => load(reset: true),
                child: const Text('Apply'),
              ),
            ],
          ),
        ),
        Expanded(
          child: rows.isEmpty && !busy
              ? const EmptyState(
                  'No purchase history',
                  'Change filters or record a purchase from an item card.',
                )
              : ListView.builder(
                  controller: scroll,
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                  itemCount: rows.length + (more ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (index == rows.length) {
                      return SizedBox(
                        height: 56,
                        child: Center(
                          child: busy
                              ? const CircularProgressIndicator()
                              : const SizedBox.shrink(),
                        ),
                      );
                    }
                    final row = rows[index];
                    final total =
                        row['total_minor'] ??
                        ((double.tryParse(row['quantity'].toString()) ?? 0) *
                            number(row['unit_price_minor']));
                    return Card(
                      elevation: 0,
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 7,
                        ),
                        title: Text(
                          row['item_name'].toString(),
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        subtitle: Text(
                          (row['category'] ?? '').toString() +
                              ' · ' +
                              (row['purchase_date'] ?? '').toString() +
                              ' · ' +
                              time(row) +
                              '\n' +
                              (row['supplier_name'] ?? 'Supplier').toString() +
                              ' · ' +
                              (row['quantity'] ?? '').toString() +
                              ' ' +
                              (row['unit'] ?? '').toString() +
                              ' · ' +
                              (row['payment_mode'] ?? '').toString(),
                        ),
                        isThreeLine: true,
                        trailing: Text(
                          money(total),
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    ),
  );
}
