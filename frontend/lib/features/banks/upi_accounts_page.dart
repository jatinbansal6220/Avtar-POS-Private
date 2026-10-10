import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/session.dart';
import '../../ui/record_editor_page.dart';
import '../../ui/shared.dart';

class UpiAccountsPage extends StatefulWidget {
  final Session session;
  const UpiAccountsPage(this.session, {super.key});

  @override
  State<UpiAccountsPage> createState() => _UpiAccountsPageState();
}

class _UpiAccountsPageState extends State<UpiAccountsPage> {
  List<Json> accounts = [];
  bool loading = true;
  String? error;
  late final VoidCallback listener;

  @override
  void initState() {
    super.initState();
    listener = () => unawaited(load());
    widget.session.watch('banks').addListener(listener);
    unawaited(load());
  }

  @override
  void dispose() {
    widget.session.watch('banks').removeListener(listener);
    super.dispose();
  }

  Future<void> load() async {
    try {
      final rows = await widget.session.local!.list('banks', limit: 500);
      if (!mounted) return;
      setState(() {
        accounts = rows
            .where(
              (row) => ['upi', 'upi_merchant'].contains(row['account_type']),
            )
            .toList();
        error = null;
        loading = false;
      });
    } catch (exception) {
      if (mounted) {
        setState(() {
          error = '$exception';
          loading = false;
        });
      }
    }
  }

  Future<void> edit([Json? account]) async {
    await openPage(
      context,
      RecordEditor(
        widget.session,
        'banks',
        row: account,
        initial: const {'account_type': 'upi', 'is_active': true},
        title: account == null ? 'Add UPI account' : 'Edit UPI account',
        hiddenFields: const {
          'account_type',
          'ifsc_code',
          'initial_balance_minor',
          'use_for_card',
        },
        fieldLabels: const {'account_number': 'UPI ID'},
        showBankQrUpload: false,
      ),
    );
    if (mounted) await load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('UPI Accounts'),
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 16),
          child: FilledButton.icon(
            onPressed: () => edit(),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add'),
          ),
        ),
      ],
    ),
    body: loading
        ? const Center(child: CircularProgressIndicator())
        : error != null
        ? Center(
            child: Text(error!, style: const TextStyle(color: Colors.red)),
          )
        : accounts.isEmpty
        ? const EmptyState(
            'No UPI account configured',
            'Add the restaurant UPI ID used to receive bill payments.',
          )
        : ListView.builder(
            padding: const EdgeInsets.all(20),
            itemCount: accounts.length,
            itemBuilder: (context, index) {
              final account = accounts[index];
              final active = enabled(account['is_active']);
              final isDefault = enabled(account['is_default_qr']);
              return Card(
                child: ListTile(
                  leading: Icon(
                    Icons.account_balance_wallet_outlined,
                    color: active
                        ? Theme.of(context).colorScheme.primary
                        : Colors.grey,
                  ),
                  title: Text('${account['account_name']}'),
                  subtitle: Text(
                    [
                          account['bank_name'],
                          account['account_number'],
                          active ? 'Active' : 'Disabled',
                          if (isDefault) 'Default',
                        ]
                        .where((value) => '${value ?? ''}'.trim().isNotEmpty)
                        .join(' · '),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => edit(account),
                ),
              );
            },
          ),
  );
}
