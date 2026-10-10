import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/session.dart';
import '../core/build_info.dart';
import '../core/developer_reset_guard.dart';
import '../features/developer/developer_panel.dart';
import '../features/printing/printer_service.dart'
    if (dart.library.js_interop) '../features/printing/printer_service_web.dart';
import 'shared.dart';
import 'records_page.dart';

/// Local settings editor; reopening never waits for network or creates duplicates.
class SettingsPage extends StatefulWidget {
  final Session session;
  const SettingsPage(this.session, {super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  Json settings = {};
  final controllers = <String, TextEditingController>{};
  bool loading = true, taxEnabled = false, testingPrinter = false;
  String? error;
  static const fields = {
    'restaurant_name': 'Restaurant name',
    'restaurant_address': 'Address',
    'restaurant_phone': 'Phone',
    'tagline': 'Receipt footer',
    'gstin': 'GSTIN',
    'fssai_lic': 'FSSAI licence',
    'timezone': 'Timezone',
    'tax_basis_points': 'GST (%)',
    'default_discount_basis_points': 'Default discount (%)',
    'printer_ip': 'WiFi printer IP / hostname',
    'printer_port': 'Printer port',
  };
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      settings =
          (await widget.session.local!.list(
            'settings',
            limit: 1,
          )).firstOrNull ??
          {};
      for (final entry in fields.entries) {
        final value = settings[entry.key];
        controllers[entry.key] = TextEditingController(
          text: entry.key.contains('basis_points')
              ? (number(value) / 100).toStringAsFixed(2)
              : '${value ?? ''}',
        );
      }
      taxEnabled = enabled(settings['is_tax_enabled']);
    } catch (e) {
      error = '$e';
    }
    if (mounted) setState(() => loading = false);
  }

  @override
  void dispose() {
    for (final controller in controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Json settingsValue() {
    final value = <String, dynamic>{...settings, 'is_tax_enabled': taxEnabled};
    for (final key in fields.keys) {
      final text = controllers[key]!.text.trim();
      if (key.contains('basis_points')) {
        final percent = double.tryParse(text);
        if (percent == null || percent < 0 || percent > 100) {
          throw ApiFailure(422, 'Enter a percentage between 0 and 100.');
        }
        value[key] = (percent * 100).round();
      } else if (key == 'printer_port') {
        if (text.isNotEmpty &&
            (int.tryParse(text) == null ||
                int.parse(text) < 1 ||
                int.parse(text) > 65535)) {
          throw ApiFailure(422, 'Invalid printer port.');
        }
        value[key] = int.tryParse(text) ?? 9100;
      } else {
        value[key] = text;
      }
    }
    // Do not retain a usable GST rate after the owner has switched GST off.
    if (!taxEnabled) value['tax_basis_points'] = 0;
    if ('${value['restaurant_name']}'.isEmpty) {
      throw ApiFailure(422, 'Restaurant name is required.');
    }
    return value;
  }

  Future<void> save() async {
    try {
      final value = settingsValue();
      settings = await widget.session.mutate('settings', value);
      if (mounted) {
        setState(() => error = null);
        message(context, 'Settings saved');
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Future<void> testPrinter() async {
    if (testingPrinter) return;
    setState(() => testingPrinter = true);
    try {
      widget.session.requireFeature('printing');
      await PrinterService().test(settingsValue());
      if (mounted) {
        message(
          context,
          'Test print sent. Check the thermal printer paper, then save settings to keep this configuration.',
        );
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => testingPrinter = false);
    }
  }

  Future<void> installUpdate() async {
    final okay = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Install update?'),
        content: Text(
          !kIsWeb && Platform.isAndroid
              ? 'Android will ask you to approve installation. Your orders, bills and offline data will be preserved.'
              : 'AvtarPOS will close, update itself, then reopen. Your local orders, bills, saved drafts and sync review items will be preserved.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              !kIsWeb && Platform.isAndroid
                  ? 'Install update'
                  : 'Install & restart',
            ),
          ),
        ],
      ),
    );
    if (okay != true) return;
    try {
      await widget.session.updater.installAndRestart(widget.session);
      if (Platform.isWindows) {
        exit(0);
      }
    } catch (error) {
      if (mounted) setState(() => this.error = '$error');
    }
  }

  Future<void> changeAppPassword() async {
    final current = TextEditingController();
    final next = TextEditingController();
    final confirm = TextEditingController();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        scrollable: true,
        title: const Text('Change app password'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: current,
              autofocus: true,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Current app password',
              ),
            ),
            TextField(
              controller: next,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'New app password'),
            ),
            TextField(
              controller: confirm,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Confirm new password',
              ),
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
            child: const Text('Save password'),
          ),
        ],
      ),
    );
    final currentValue = current.text;
    final nextValue = next.text;
    final confirmation = confirm.text;
    current.dispose();
    next.dispose();
    confirm.dispose();
    if (accepted != true) return;
    if (nextValue != confirmation) {
      if (mounted) {
        message(context, 'New password and confirmation do not match.');
      }
      return;
    }
    try {
      await widget.session.changeAppLockPassword(
        currentPassword: currentValue,
        newPassword: nextValue,
      );
      if (mounted) message(context, 'App password changed.');
    } catch (failure) {
      if (mounted) setState(() => error = '$failure');
    }
  }

  Future<void> resetAppPassword() async {
    final developerApproved = await requireDeveloperResetCode(context);
    if (!mounted || !developerApproved) return;
    final email = TextEditingController();
    final account = TextEditingController();
    final next = TextEditingController();
    final confirm = TextEditingController();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        scrollable: true,
        title: const Text('Reset app password'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Internet is required. Verify the restaurant account password to reset the local app password.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: email,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              decoration: const InputDecoration(
                labelText: 'Restaurant login email',
              ),
            ),
            TextField(
              controller: account,
              autofocus: true,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Restaurant account password',
              ),
            ),
            TextField(
              controller: next,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'New app password'),
            ),
            TextField(
              controller: confirm,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Confirm new password',
              ),
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
            child: const Text('Reset password'),
          ),
        ],
      ),
    );
    final accountEmail = email.text;
    final accountPassword = account.text;
    final nextValue = next.text;
    final confirmation = confirm.text;
    email.dispose();
    account.dispose();
    next.dispose();
    confirm.dispose();
    if (accepted != true) return;
    if (nextValue != confirmation) {
      if (mounted) {
        message(context, 'New password and confirmation do not match.');
      }
      return;
    }
    try {
      await widget.session.resetAppLockWithAccountPassword(
        accountEmail: accountEmail,
        accountPassword: accountPassword,
        newPassword: nextValue,
      );
      if (mounted) message(context, 'App password reset.');
    } catch (failure) {
      if (mounted) setState(() => error = '$failure');
    }
  }

  Widget appLockCard() => Card(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('App security', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          const Text(
            'The app password is required whenever Avtar Cooks POS starts. It is stored only as a secure hash on this device.',
            style: TextStyle(color: secondaryText),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Ask for password after minimize'),
            subtitle: const Text(
              'When off, password is required only after the app is closed and opened again.',
            ),
            value: widget.session.appLockOnMinimize,
            onChanged: (value) async {
              await widget.session.setAppLockOnMinimize(value);
              if (mounted) setState(() {});
            },
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: changeAppPassword,
                icon: const Icon(Icons.password_outlined),
                label: const Text('Change app password'),
              ),
              TextButton(
                onPressed: resetAppPassword,
                child: const Text('Reset password'),
              ),
            ],
          ),
        ],
      ),
    ),
  );

  Widget updatesCard() => AnimatedBuilder(
    animation: widget.session.updater,
    builder: (context, _) {
      final updater = widget.session.updater;
      final update = updater.update;
      return Card(
        color: Theme.of(context).colorScheme.surfaceContainerLowest,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  ListTile(
                    leading: const Icon(Icons.developer_mode),
                    title: const Text('Developer controls'),
                    subtitle: const Text(
                      'Ctrl+Shift+F12 · Requires developer verification',
                    ),
                    onTap: () => openDeveloperPanel(context, widget.session),
                  ),
                  const Icon(Icons.system_update_outlined),
                  const SizedBox(width: 8),
                  Text(
                    'App updates',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const Spacer(),
                  Text('v$appVersion'),
                ],
              ),
              const SizedBox(height: 8),
              Text(updater.status),
              if (updater.enabled) ...[
                const SizedBox(height: 6),
                Text(
                  Platform.isAndroid
                      ? 'New releases download automatically. Android asks you to approve installation.'
                      : 'New releases download automatically and install on a safe startup or unlock screen. Active billing is never interrupted.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              if (update != null) ...[
                const SizedBox(height: 6),
                Text(
                  update.notes,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              if (updater.state == UpdateState.downloading) ...[
                const SizedBox(height: 10),
                LinearProgressIndicator(
                  value: updater.progress == 0 ? null : updater.progress / 100,
                ),
              ],
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: updater.isBusy ? null : () => updater.check(),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Check for updates'),
                  ),
                  if (update != null && !updater.canInstall)
                    FilledButton.icon(
                      onPressed: updater.isBusy ? null : updater.download,
                      icon: const Icon(Icons.download),
                      label: const Text('Download update'),
                    ),
                  if (updater.canInstall)
                    FilledButton.icon(
                      onPressed: installUpdate,
                      icon: const Icon(Icons.restart_alt),
                      label: Text(
                        !kIsWeb && Platform.isAndroid
                            ? 'Install update'
                            : 'Install & restart',
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Settings')),
    body: loading
        ? const Center(child: CircularProgressIndicator())
        : Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 800),
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  Text(
                    'Restaurant & billing',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  for (final entry in fields.entries)
                    if (!entry.key.startsWith('printer_') ||
                        (!kIsWeb && !Platform.isWindows))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: TextField(
                          controller: controllers[entry.key],
                          decoration: InputDecoration(labelText: entry.value),
                        ),
                      ),
                  SwitchListTile(
                    title: const Text('Apply GST'),
                    value: taxEnabled,
                    onChanged: (value) => setState(() => taxEnabled = value),
                  ),
                  DropdownButtonFormField<String>(
                    initialValue: settings['printer_paper_width'] ?? '80mm',
                    decoration: const InputDecoration(
                      labelText: 'Receipt paper width',
                    ),
                    items: const [
                      DropdownMenuItem(value: '80mm', child: Text('80 mm')),
                      DropdownMenuItem(value: '58mm', child: Text('58 mm')),
                    ],
                    onChanged: (value) =>
                        settings['printer_paper_width'] = value,
                  ),
                  const SizedBox(height: 14),
                  Text(
                    kIsWeb
                        ? 'Browser receipt preview. Choose 80 mm for RP80US layout checks; use the browser dialog to print or save a PDF.'
                        : Platform.isWindows
                        ? 'Prints through the Windows default printer. Change the default in Windows Settings → Printers & scanners.'
                        : 'For RP80US, connect the phone/tablet through USB-OTG; Android will ask once for printer permission. WiFi IP and port remain available as a fallback.',
                  ),
                  if (error != null)
                    Text(error!, style: const TextStyle(color: Colors.red)),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: save,
                    child: const Text('Save settings'),
                  ),
                  if (!kIsWeb) ...[
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: testingPrinter ? null : testPrinter,
                      icon: const Icon(Icons.print_outlined),
                      label: Text(
                        testingPrinter
                            ? 'Sending test print…'
                            : Platform.isWindows
                            ? 'Test Windows default printer'
                            : 'Test WiFi thermal printer',
                      ),
                    ),
                  ],
                  const Divider(height: 32),
                  appLockCard(),
                  const Divider(height: 32),
                  updatesCard(),
                  const Divider(height: 32),
                  for (final entry in [
                    ('tables', 'Dining tables'),
                    ('banks', 'Payment accounts (UPI / Card)'),
                    ('combos', 'Combos'),
                  ])
                    ListTile(
                      title: Text(entry.$2),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => openPage(
                        context,
                        RecordsPage(widget.session, entry.$1),
                      ),
                    ),
                ],
              ),
            ),
          ),
  );
}
