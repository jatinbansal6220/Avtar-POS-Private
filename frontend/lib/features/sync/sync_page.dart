import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/session.dart';
import '../../ui/shared.dart';
import 'conflict_page.dart';

class SyncPage extends StatefulWidget {
  final Session session;
  const SyncPage(this.session, {super.key});
  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  List<Json> rows = [];
  @override
  void initState() {
    super.initState();
    widget.session.addListener(load);
    load();
  }

  @override
  void dispose() {
    widget.session.removeListener(load);
    super.dispose();
  }

  Future<void> load() async {
    final data = await widget.session.local!.db.query('outbox', orderBy: 'seq');
    if (mounted) {
      setState(
        () => rows = data.map((r) => Map<String, dynamic>.from(r)).toList(),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Device sync'),
      actions: [
        IconButton(
          tooltip: 'Sync now',
          onPressed: () => widget.session.sync(),
          icon: const Icon(Icons.sync),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          widget.session.expired
              ? 'Sign-in expired'
              : widget.session.online
              ? 'Connected'
              : 'Working offline',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 10),
        const Text(
          'Changes are stored on this device until acknowledged by the server. Conflicts require review.',
          style: TextStyle(color: Colors.black54, height: 1.5),
        ),
        if (widget.session.syncError != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              widget.session.syncError!,
              style: const TextStyle(color: Colors.red),
            ),
          ),
        const SizedBox(height: 20),
        if (rows.isEmpty)
          const EmptyState(
            'All submitted changes synced',
            'Local drafts remain in Open orders until you save them.',
            icon: Icons.cloud_done_outlined,
          ),
        for (final row in rows)
          Card(
            elevation: 0,
            child: ListTile(
              minVerticalPadding: 16,
              leading: Icon(
                row['state'] == 'conflict' ? Icons.warning_amber : Icons.sync,
                color: row['state'] == 'conflict' ? Colors.orange : accent,
              ),
              title: Text('${row['resource']} · ${row['state']}'),
              subtitle: Text(
                row['state'] == 'conflict'
                    ? '${row['error'] ?? row['path']}\nTap to retry or discard this upload.'
                    : '${row['error'] ?? row['path']}',
              ),
              isThreeLine: row['state'] == 'conflict',
              trailing: row['state'] == 'conflict'
                  ? const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [Text('Review'), Icon(Icons.chevron_right)],
                    )
                  : null,
              onTap: row['state'] == 'conflict'
                  ? () async {
                      await openPage(
                        context,
                        ConflictPage(
                          widget.session,
                          row,
                          jsonDecode(row['payload']) as Json,
                        ),
                      );
                      load();
                    }
                  : null,
            ),
          ),
      ],
    ),
  );
}
