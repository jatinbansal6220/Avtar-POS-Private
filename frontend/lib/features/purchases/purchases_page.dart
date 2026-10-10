import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/session.dart';
import '../../ui/shared.dart';
import 'purchase_entry_dialog.dart';
import 'purchase_history_page.dart';

class PurchasesPage extends StatefulWidget {
  final Session session;
  final bool catalogOnly;
  const PurchasesPage(this.session, {super.key, this.catalogOnly = false});

  @override
  State<PurchasesPage> createState() => _PurchasesPageState();
}

class _PurchasesPageState extends State<PurchasesPage> {
  List<Json> categories = [];
  List<Json> items = [];
  String? categoryId;
  bool busy = true;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final values = await Future.wait([
      widget.session.local!.listAll('purchase_categories'),
      widget.session.local!.listAll('purchase_items'),
    ]);
    if (mounted) {
      setState(() {
        categories = values[0];
        items = values[1]
            .where((item) => widget.catalogOnly || enabled(item['is_active']))
            .toList();
        busy = false;
      });
    }
  }

  Future<Json?> createCategory() async {
    var categoryName = '';
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create purchase category'),
        content: TextField(
          onChanged: (value) => categoryName = value,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Category name',
            hintText: 'For example: Vegetables',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, categoryName.trim()),
            child: const Text('Create category'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return null;
    final existing = categories
        .where(
          (row) => row['name'].toString().toLowerCase() == name.toLowerCase(),
        )
        .firstOrNull;
    if (existing != null) return existing;
    final category = await widget.session.mutate('purchase_categories', {
      'name': name,
    });
    await load();
    return category;
  }

  Future<void> addItem() async {
    if (categories.isEmpty) {
      await createCategory();
      if (categories.isEmpty || !mounted) return;
    }
    var itemName = '';
    Json selected = categories.first;
    final draft = await showDialog<Json>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Create purchase item'),
          content: SizedBox(
            width: 370,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  onChanged: (value) => itemName = value,
                  autofocus: true,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Purchase item name',
                    hintText: 'For example: Tomato',
                  ),
                ),
                const SizedBox(height: 14),
                DropdownButtonFormField<String>(
                  value: selected['id'].toString(),
                  decoration: const InputDecoration(labelText: 'Category'),
                  items: categories
                      .map(
                        (category) => DropdownMenuItem(
                          value: category['id'].toString(),
                          child: Text(category['name'].toString()),
                        ),
                      )
                      .toList(),
                  onChanged: (value) => setDialogState(
                    () => selected = categories.firstWhere(
                      (category) => category['id'].toString() == value,
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () async {
                      final category = await createCategory();
                      if (category != null && dialogContext.mounted) {
                        setDialogState(() => selected = category);
                      }
                    },
                    icon: const Icon(Icons.add, size: 17),
                    label: const Text('Create another category'),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, {
                'name': itemName.trim(),
                'category': selected,
              }),
              child: const Text('Create item'),
            ),
          ],
        ),
      ),
    );
    if (draft == null || draft['name'].toString().isEmpty || !mounted) return;
    final category = Map<String, dynamic>.from(draft['category'] as Map);
    final duplicate = items
        .where(
          (item) =>
              item['name'].toString().toLowerCase() ==
                  draft['name'].toString().toLowerCase() &&
              item['category_id'].toString() == category['id'].toString(),
        )
        .isNotEmpty;
    if (duplicate) {
      if (mounted) {
        message(context, 'This item already exists in the selected category.');
      }
      return;
    }
    await widget.session.mutate('purchase_items', {
      'name': draft['name'],
      'category_id': category['id'],
      'category_name': category['name'],
      'is_active': true,
    });
    await load();
  }

  Future<void> openItem(Json item) async {
    if (widget.catalogOnly) {
      await editItem(item);
      return;
    }
    final saved = await openPurchaseEntryDialog(context, widget.session, item);
    if (saved != null && mounted) message(context, 'Purchase saved.');
  }

  Future<void> editItem(Json item) async {
    var name = '${item['name']}';
    var category = '${item['category_id']}';
    var active = enabled(item['is_active']);
    bool saving = false;
    String? error;
    await showDialog<void>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (dialog, refresh) => AlertDialog(
          title: const Text('Edit purchase item'),
          content: SizedBox(
            width: 400,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    initialValue: name,
                    decoration: const InputDecoration(labelText: 'Item name'),
                    onChanged: (v) => name = v.trim(),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: category,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Category'),
                    items: categories
                        .map(
                          (c) => DropdownMenuItem(
                            value: '${c['id']}',
                            child: Text('${c['name']}'),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => category = v ?? category,
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Available for new purchases'),
                    value: active,
                    onChanged: saving ? null : (v) => refresh(() => active = v),
                  ),
                  const Text(
                    'Making an item inactive keeps its purchase and stock history.',
                  ),
                  if (error != null)
                    Text(error!, style: const TextStyle(color: Colors.red)),
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
                        if (name.isEmpty || name.length > 160)
                          throw ApiFailure(
                            422,
                            'Enter an item name up to 160 characters.',
                          );
                        if (items.any(
                          (i) =>
                              i['id'] != item['id'] &&
                              i['category_id'] == category &&
                              '${i['name']}'.toLowerCase() ==
                                  name.toLowerCase(),
                        ))
                          throw ApiFailure(
                            422,
                            'Item already exists in this category.',
                          );
                        final selected = categories.firstWhere(
                          (c) => c['id'] == category,
                        );
                        await widget.session.mutate('purchase_items', {
                          ...item,
                          'name': name,
                          'category_id': category,
                          'category_name': selected['name'],
                          'is_active': active,
                        });
                        if (dialog.mounted) Navigator.pop(dialog);
                      } catch (e) {
                        if (dialog.mounted)
                          refresh(() {
                            saving = false;
                            error = '$e';
                          });
                      }
                    },
              child: Text(saving ? 'Saving...' : 'Save item'),
            ),
          ],
        ),
      ),
    );
    await load();
  }

  @override
  Widget build(BuildContext context) {
    final visible = categoryId == null
        ? items
        : items
              .where((item) => item['category_id'].toString() == categoryId)
              .toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.catalogOnly ? 'Purchase items' : 'Purchases'),
        actions: [
          TextButton.icon(
            onPressed: () => openPage(
              context,
              PurchaseHistoryPage(widget.session, items, categories),
            ),
            icon: const Icon(Icons.history, size: 18),
            label: const Text('History'),
          ),
          TextButton.icon(
            onPressed: createCategory,
            icon: const Icon(Icons.category_outlined, size: 18),
            label: const Text('Category'),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: FilledButton.icon(
              onPressed: addItem,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add item'),
            ),
          ),
        ],
      ),
      body: busy
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (categories.isNotEmpty)
                  SizedBox(
                    height: 62,
                    child: ListView(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                      scrollDirection: Axis.horizontal,
                      children: [
                        ChoiceChip(
                          label: const Text('All items'),
                          selected: categoryId == null,
                          onSelected: (_) => setState(() => categoryId = null),
                        ),
                        for (final category in categories)
                          Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: ChoiceChip(
                              label: Text(category['name'].toString()),
                              selected: categoryId == category['id'].toString(),
                              onSelected: (_) => setState(
                                () => categoryId = category['id'].toString(),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                Expanded(
                  child: visible.isEmpty
                      ? EmptyState(
                          'No purchase items',
                          categories.isEmpty
                              ? 'Create a category first, then create the items you buy daily.'
                              : 'Create an item in this category. Its card is saved immediately.',
                          icon: Icons.inventory_2_outlined,
                          action: FilledButton.icon(
                            onPressed: categories.isEmpty
                                ? createCategory
                                : addItem,
                            icon: const Icon(Icons.add),
                            label: Text(
                              categories.isEmpty
                                  ? 'Create category'
                                  : 'Create item',
                            ),
                          ),
                        )
                      : GridView.builder(
                          padding: const EdgeInsets.all(20),
                          gridDelegate:
                              const SliverGridDelegateWithMaxCrossAxisExtent(
                                maxCrossAxisExtent: 230,
                                mainAxisExtent: 128,
                                crossAxisSpacing: 12,
                                mainAxisSpacing: 12,
                              ),
                          itemCount: visible.length,
                          itemBuilder: (context, index) {
                            final item = visible[index];
                            return Card(
                              color: Colors.white,
                              surfaceTintColor: Colors.white,
                              elevation: 2,
                              shadowColor: accent.withValues(alpha: 0.16),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                                side: const BorderSide(color: line),
                              ),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(12),
                                onTap: () => openItem(item),
                                child: Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const Icon(
                                        Icons.inventory_2_outlined,
                                        color: accent,
                                      ),
                                      const Spacer(),
                                      Text(
                                        item['name'].toString(),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        item['category_name'].toString(),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
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
                        ),
                ),
              ],
            ),
    );
  }
}
