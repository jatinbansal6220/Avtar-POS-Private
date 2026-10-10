import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/session.dart';
import '../orders/order_workspace_page.dart';

class ConflictPage extends StatefulWidget {
  final Session session;
  final Json mutation, payload;
  const ConflictPage(this.session, this.mutation, this.payload, {super.key});
  @override
  State<ConflictPage> createState() => _ConflictPageState();
}

class _ConflictPageState extends State<ConflictPage> {
  Json? server, local;
  String? error;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final draft = await widget.session.local!.readDraft(
        widget.mutation['entity'],
      );
      Json? result;
      try {
        result = await widget.session.request(
          'GET',
          'orders/${widget.mutation['entity']}',
        );
      } on ApiFailure catch (e) {
        if (e.status != 404) rethrow;
        if (widget.payload['table_id'] != null) {
          final table = await widget.session.request(
            'GET',
            'tables/${widget.payload['table_id']}',
          );
          if (table['current_order_id'] != null) {
            result = await widget.session.request(
              'GET',
              'orders/${table['current_order_id']}',
            );
          }
        }
      }
      if (mounted) {
        setState(() {
          server = result;
          local = draft;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  Future<void> resolve(bool keepLocal) async {
    setState(() => busy = true);
    try {
      if (keepLocal && server != null && server!['status'] != 'open') {
        throw ApiFailure(
          409,
          'The order is finalized. You can only keep the server result.',
        );
      }
      final draft = clone(
        keepLocal ? (local ?? widget.payload) : server ?? widget.payload,
      );
      draft['version'] = server?['version'] ?? 0;
      draft['id'] = server?['id'] ?? widget.mutation['entity'];
      draft.removeWhere((key, _) => key.startsWith('_'));
      await widget.session.discardSyncReview(widget.mutation);
      if (keepLocal) {
        if (draft['id'] != widget.mutation['entity']) {
          await widget.session.local!.db.delete(
            'drafts',
            where: 'id=?',
            whereArgs: [widget.mutation['entity']],
          );
        }
        await widget.session.local!.draft(draft);
      } else {
        await widget.session.local!.db.delete(
          'drafts',
          where: 'id=?',
          whereArgs: [widget.mutation['entity']],
        );
      }
      await widget.session.sync();
      if (mounted) {
        if (keepLocal) {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              builder: (_) => OrderWorkspacePage(widget.session, draft),
            ),
          );
        } else {
          Navigator.pop(context);
        }
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> retry() async {
    setState(() => busy = true);
    try {
      await widget.session.retrySyncReview(widget.mutation);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> discard() async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Discard this upload?'),
        content: const Text(
          'Only this blocked server upload will be removed. The local order or invoice will remain visible on this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Discard upload'),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    setState(() => busy = true);
    try {
      await widget.session.discardSyncReview(widget.mutation);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget summary(String title, Json? value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title, style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 12),
      if (value != null)
        for (final item in maps(value['items']))
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              '${item['item_name'] ?? item['menu_item_id'] ?? item['combo_id']}',
            ),
            trailing: Text('× ${item['quantity']}'),
          ),
    ],
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Review conflicting change')),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          widget.mutation['error'] ?? 'The order changed on another device.',
        ),
        const SizedBox(height: 24),
        summary('Your device', local ?? widget.payload),
        const Divider(),
        const SizedBox(height: 24),
        summary('Current server order', server),
        const SizedBox(height: 24),
        if (error != null)
          Text(error!, style: const TextStyle(color: Colors.red)),
        const SizedBox(height: 20),
        if (server != null) ...[
          FilledButton(
            onPressed: busy ? null : () => resolve(false),
            child: const Text(
              'Keep server order · discard this submitted change',
            ),
          ),
          const SizedBox(height: 12),
          if (widget.mutation['resource'] == 'orders' &&
              server!['status'] == 'open')
            OutlinedButton(
              onPressed: busy ? null : () => resolve(true),
              child: const Text('Review my draft against this server version'),
            ),
        ],
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: busy ? null : retry,
          icon: const Icon(Icons.cloud_upload_outlined),
          label: const Text('Retry upload'),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
          onPressed: busy ? null : discard,
          icon: const Icon(Icons.delete_outline),
          label: const Text('Discard this upload only'),
        ),
        const SizedBox(height: 16),
        const Text(
          'Retry keeps the same idempotency key, so it cannot duplicate a bill. Discard keeps the local data and removes only this blocked upload.',
          style: TextStyle(color: Colors.black54),
        ),
      ],
    ),
  );
}
