import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/session.dart';
import '../../ui/record_editor_page.dart';
import '../../ui/shared.dart';
import '../../ui/records_page.dart';
import 'dish_photo.dart';

class MenuCatalogPage extends StatefulWidget {
  final Session session;
  const MenuCatalogPage(this.session, {super.key});
  @override
  State<MenuCatalogPage> createState() => _MenuCatalogPageState();
}

class _MenuCatalogPageState extends State<MenuCatalogPage> {
  final search = TextEditingController();
  Timer? debounce;
  List<Json> rows = [];
  String category = 'All';
  bool loading = true;

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    debounce?.cancel();
    search.dispose();
    super.dispose();
  }

  Future<void> load() async {
    setState(() => loading = true);
    try {
      rows = await widget.session.local!.list(
        'menu_items',
        query: search.text,
        limit: 100,
      );
    } catch (_) {
      rows =
          await widget.session.local?.list(
            'menu_items',
            query: search.text,
            limit: 500,
          ) ??
          [];
    }
    if (mounted) setState(() => loading = false);
  }

  List<Json> get filtered {
    final q = search.text.trim().toLowerCase();
    return rows.where((r) {
      final text = '${r['name']} ${r['category']}'.toLowerCase();
      return (q.isEmpty || text.contains(q)) &&
          (category == 'All' || '${r['category']}' == category);
    }).toList();
  }

  Future<void> edit([Json? row]) async {
    await openPage(
      context,
      RecordEditor(widget.session, 'menu_items', row: row),
    );
    await load();
  }

  Widget itemCard(Json row) {
    final active = enabled(row['is_active']);
    final veg = row['is_veg'] != false;
    return Card(
      elevation: 0,
      child: InkWell(
        onTap: () => edit(row),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              DishPhoto(name: '${row['name']}', veg: veg),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      '${row['name']}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '${row['category'] ?? 'Other'}',
                      style: const TextStyle(color: Colors.black54),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Text(
                          money(row['price_minor'] ?? row['price'] ?? 0),
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(width: 10),
                        StatusPill(active ? 'available' : 'disabled'),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final categories = [
      'All',
      ...{for (final r in rows) '${r['category'] ?? 'Other'}'},
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Catalog'),
        actions: [
          TextButton(
            onPressed: () =>
                openPage(context, RecordsPage(widget.session, 'combos')),
            child: const Text('Combos'),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: FilledButton.icon(
              onPressed: () => edit(),
              icon: const Icon(Icons.add),
              label: const Text('Add Item'),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
            child: TextField(
              controller: search,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search menu items',
              ),
              onChanged: (_) {
                debounce?.cancel();
                debounce = Timer(
                  const Duration(milliseconds: 180),
                  () => setState(() {}),
                );
              },
            ),
          ),
          SizedBox(
            height: 54,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
              itemCount: categories.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (_, i) => ChoiceChip(
                label: Text(categories[i]),
                selected: category == categories[i],
                onSelected: (_) => setState(() => category = categories[i]),
              ),
            ),
          ),
          Expanded(
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : filtered.isEmpty
                ? const EmptyState(
                    'No menu items',
                    'Add real dishes from the catalog.',
                  )
                : LayoutBuilder(
                    builder: (context, c) {
                      final count = c.maxWidth > 1100
                          ? 3
                          : c.maxWidth > 700
                          ? 2
                          : 1;
                      return GridView.builder(
                        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: count,
                          crossAxisSpacing: 14,
                          mainAxisSpacing: 14,
                          childAspectRatio: 2.7,
                        ),
                        itemCount: filtered.length,
                        itemBuilder: (_, i) => itemCard(filtered[i]),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
