import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/session.dart';
import '../../ui/shared.dart';
import 'order_workspace_page.dart';

class OpenOrdersPage extends StatefulWidget {
  final Session session;
  const OpenOrdersPage(this.session, {super.key});
  @override
  State<OpenOrdersPage> createState() => _OpenOrdersPageState();
}

class _OpenOrdersPageState extends State<OpenOrdersPage> {
  List<Json> rows = [];
  bool busy = false, more = true;
  @override
  void initState() {
    super.initState();
    widget.session.addListener(refresh);
    load(reset: true);
  }

  void refresh() => load(reset: true);
  @override
  void dispose() {
    widget.session.removeListener(refresh);
    super.dispose();
  }

  Future<void> load({bool reset = false}) async {
    if (busy) return;
    busy = true;
    final saved = await widget.session.local!.list(
      'orders',
      status: 'open',
      offset: reset ? 0 : rows.where((r) => r['_local'] != true).length,
      limit: 50,
    );
    final drafts = reset ? await widget.session.local!.drafts() : <Json>[];
    final merged = <String, Json>{
      if (!reset)
        for (final r in rows) r['id']: r,
      for (final r in saved) r['id']: r,
      for (final r in drafts) r['id']: {...r, '_local': true},
    };
    if (mounted) {
      setState(() {
        rows = merged.values.toList();
        more = saved.length == 50;
        busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Open orders & drafts')),
    body: rows.isEmpty
        ? const EmptyState(
            'No open orders',
            'Select a table or start a takeaway from the floor.',
          )
        : ListView.builder(
            padding: const EdgeInsets.all(20),
            itemCount: rows.length + (more ? 1 : 0),
            itemBuilder: (context, index) {
              if (index == rows.length) {
                return TextButton(
                  onPressed: () => load(),
                  child: const Text('Load more'),
                );
              }
              final order = rows[index];
              return Card(
                elevation: 0,
                child: ListTile(
                  minVerticalPadding: 20,
                  leading: const Icon(
                    Icons.receipt_long_outlined,
                    color: accent,
                  ),
                  title: Text('${order['table_number']}'),
                  subtitle: Text(
                    '${order['order_type']} · ${maps(order['items']).length} items${order['_local'] == true ? ' · Local draft' : ''}',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    await openPage(
                      context,
                      OrderWorkspacePage(widget.session, order),
                    );
                    if (mounted) load(reset: true);
                  },
                ),
              );
            },
          ),
  );
}
