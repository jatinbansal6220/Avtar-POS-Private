import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/session.dart';
import '../../ui/shared.dart';
import 'dish_photo.dart';

class MenuPanel extends StatefulWidget {
  final Session session;
  final void Function(Json, bool) onAdd;
  const MenuPanel(this.session, {super.key, required this.onAdd});
  @override
  State<MenuPanel> createState() => _MenuPanelState();
}

class _MenuPanelState extends State<MenuPanel> {
  final search = TextEditingController(), scroll = ScrollController();
  Timer? debounce;
  List<Json> items = [];
  String category = 'All';
  bool combos = false, busy = false, more = true;
  int generation = 0;
  @override
  void initState() {
    super.initState();
    load(reset: true);
    widget.session.watch('menu_items').addListener(refresh);
    widget.session.watch('combos').addListener(refresh);
    widget.session.watch('control_policy').addListener(policyChanged);
    scroll.addListener(() {
      if (scroll.position.extentAfter < 250 && !busy && more) load();
    });
  }

  void refresh() => load(reset: true);
  void policyChanged() {
    if (!mounted) return;
    if (combos && !widget.session.featureEnabled('combos')) {
      setState(() {
        combos = false;
        category = 'All';
      });
      load(reset: true);
    } else {
      setState(() {});
    }
  }

  @override
  void dispose() {
    widget.session.watch('menu_items').removeListener(refresh);
    widget.session.watch('combos').removeListener(refresh);
    widget.session.watch('control_policy').removeListener(policyChanged);
    debounce?.cancel();
    search.dispose();
    scroll.dispose();
    super.dispose();
  }

  Future<void> load({bool reset = false}) async {
    if (busy && !reset) return;
    final gen = reset ? ++generation : generation;
    setState(() => busy = true);
    final result = await widget.session.local!.listAll(
      combos ? 'combos' : 'menu_items',
      // Search is deliberately applied below: SQLite's generic name lookup
      // cannot see short codes or tolerate a small spelling mistake.
    );
    if (!mounted || gen != generation) return;
    setState(() {
      items = result;
      more = false;
      busy = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final categories = [
      'All',
      ...items.map((i) => i['category'] ?? 'Combos').toSet().cast<String>(),
    ];
    final visible = items
        .where(
          (i) =>
              enabled(i['is_active']) &&
              matchesMenuSearch(i, search.text) &&
              (category == 'All' || i['category'] == category),
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (busy) const LinearProgressIndicator(),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: TextField(
            controller: search,
            decoration: const InputDecoration(
              hintText: 'Find an item',
              prefixIcon: Icon(Icons.search),
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
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              ChoiceChip(
                label: const Text('Menu'),
                selected: !combos,
                onSelected: (_) {
                  setState(() {
                    combos = false;
                    category = 'All';
                  });
                  load(reset: true);
                },
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                label: const Text('Combos'),
                selected: combos,
                onSelected: !widget.session.featureEnabled('combos')
                    ? null
                    : (_) {
                        setState(() {
                          combos = true;
                          category = 'All';
                        });
                        load(reset: true);
                      },
              ),
            ],
          ),
        ),
        SizedBox(
          height: 62,
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            scrollDirection: Axis.horizontal,
            itemCount: categories.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, i) => FilterChip(
              label: Text(categories[i]),
              selected: category == categories[i],
              onSelected: (_) => setState(() => category = categories[i]),
            ),
          ),
        ),
        Expanded(
          child: visible.isEmpty && !more
              ? const EmptyState(
                  'No available items',
                  'Add menu items in restaurant settings, or change your search.',
                  icon: Icons.restaurant_menu,
                )
              : LayoutBuilder(
                  builder: (context, box) => GridView.builder(
                    controller: scroll,
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: box.maxWidth > 900
                          ? 4
                          : box.maxWidth > 650
                          ? 3
                          : 2,
                      mainAxisExtent: combos ? 132 : 220,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                    ),
                    itemCount: visible.length + (more ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index == visible.length) {
                        return TextButton(
                          onPressed: busy ? null : () => load(),
                          child: Text(busy ? 'Loading…' : 'More items'),
                        );
                      }
                      final item = visible[index];
                      final comboCard = combos;
                      return Material(
                        color: comboCard
                            ? const Color(0xFFFFFAE8)
                            : Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(
                            color: comboCard ? const Color(0xFFFFC107) : line,
                          ),
                        ),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: !widget.session.featureEnabled('order_edit')
                              ? null
                              : () => widget.onAdd(item, combos),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (!comboCard) ...[
                                  DishPhoto(
                                    name: '${item['name']}',
                                    width: double.infinity,
                                    height: 88,
                                    veg: enabled(item['is_veg']),
                                  ),
                                  const SizedBox(height: 8),
                                ],
                                Row(
                                  children: [
                                    Icon(
                                      Icons.circle,
                                      size: 10,
                                      color: combos
                                          ? accent
                                          : enabled(item['is_veg'])
                                          ? accent
                                          : Colors.red,
                                    ),
                                    const Spacer(),
                                    const Icon(
                                      Icons.add,
                                      size: 19,
                                      color: accent,
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 7),
                                Expanded(
                                  child: Text(
                                    item['name'],
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                Text(
                                  money(item['price_minor']),
                                  style: const TextStyle(
                                    color: accent,
                                    fontWeight: FontWeight.w700,
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
        ),
      ],
    );
  }
}
