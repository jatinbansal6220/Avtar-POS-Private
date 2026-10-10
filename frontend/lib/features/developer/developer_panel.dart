import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/session.dart';
import '../../core/feature_policy.dart';
import '../../ui/shared.dart';

Future<void> openDeveloperPanel(BuildContext context, Session session) async {
  if (session.developerPanelVisible) return;
  if (session.user == null) {
    message(
      context,
      'Sign in to a restaurant account before developer verification.',
    );
    return;
  }
  session.developerPanelVisible = true;
  session.changed();
  try {
    final password = TextEditingController();
    var busy = false;
    String? error;
    final verificationRoute = DialogRoute<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) {
          Future<void> verify() async {
            if (busy) return;
            update(() {
              busy = true;
              error = null;
            });
            try {
              final result = await session.unlockDeveloper(password.text);
              password.clear();
              if (context.mounted) {
                Navigator.pop(
                  dialogContext,
                  result['developer_token'] as String,
                );
              }
            } catch (failure) {
              if (context.mounted) {
                update(() {
                  error = '$failure';
                  busy = false;
                });
              }
            }
          }

          return PopScope(
            canPop: !busy,
            child: AlertDialog(
              scrollable: true,
              title: const Text('Developer verification'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    session.demoMode
                        ? 'Local demo controls affect only this browser. Verify your developer password to continue.'
                        : 'Controls affect live customer apps. Verify your developer password to continue.',
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: password,
                    autofocus: true,
                    obscureText: true,
                    enabled: !busy,
                    enableSuggestions: false,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Developer password',
                    ),
                    onSubmitted: (_) => verify(),
                  ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        error!,
                        style: const TextStyle(color: Colors.red),
                      ),
                    ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: busy ? null : () => Navigator.pop(dialogContext),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: busy ? null : verify,
                  child: Text(busy ? 'Verifying…' : 'Verify'),
                ),
              ],
            ),
          );
        },
      ),
    );
    final grant = await Navigator.of(
      context,
      rootNavigator: true,
    ).push(verificationRoute);
    await verificationRoute.completed;
    password.dispose();
    if (!context.mounted || grant == null) return;
    // Short-lived grant exists only in this page's memory.
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DeveloperPanel(session, grant: grant),
      ),
    );
  } finally {
    session.developerPanelVisible = false;
    session.changed();
  }
}

class DeveloperPanel extends StatefulWidget {
  final Session session;
  final String grant;
  const DeveloperPanel(this.session, {super.key, required this.grant});
  @override
  State<DeveloperPanel> createState() => _DeveloperPanelState();
}

class _DeveloperPanelState extends State<DeveloperPanel> {
  Json? snapshot;
  Json policy = {};
  String scope = 'global', query = '';
  int revision = 0;
  int selectorVersion = 0;
  bool loading = true, saving = false, dirty = false;
  String? error;
  final notice = TextEditingController();
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    notice.dispose();
    super.dispose();
  }

  List<Json> get controls => [
    {
      'name': widget.session.demoMode ? 'This local demo only' : 'All customer apps',
      ...Map<String, dynamic>.from(snapshot!['global'] as Map),
    },
    for (final tenant in maps(snapshot!['tenants']))
      {
        'name': '${tenant['name']} (#${tenant['id']})',
        ...Map<String, dynamic>.from(tenant['control'] as Map),
      },
  ];
  void select(String value) {
    final selected = controls.firstWhere((row) => row['scope'] == value);
    scope = value;
    revision = number(selected['revision']);
    policy = clone(Map<String, dynamic>.from(selected['policy'] as Map));
    notice.text = '${policy['message'] ?? ''}';
    dirty = false;
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result = await widget.session.developerRequest(
        'GET',
        'developer/controls',
        grant: widget.grant,
      );
      if (!mounted) return;
      snapshot = result;
      if (!controls.any((row) => row['scope'] == scope)) scope = 'global';
      select(scope);
    } catch (failure) {
      error = '$failure';
    }
    if (mounted) setState(() => loading = false);
  }

  Future<bool> confirmDiscard() async {
    if (!dirty) return true;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Discard unsaved controls?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Keep editing'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Discard'),
              ),
            ],
          ),
        ) ==
        true;
  }

  Future<void> save() async {
    if (saving || !dirty) return;
    final target = controls.firstWhere((row) => row['scope'] == scope)['name'];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(widget.session.demoMode ? 'Apply local demo controls?' : 'Apply live controls?'),
        content: Text(
          widget.session.demoMode
              ? 'Apply these settings to $target? Live customer apps are unaffected. Saved orders and bills are preserved.'
              : 'Apply these settings to $target? Connected updated apps refresh within 30 seconds. Offline apps keep their last settings. Existing bills and pending saves are preserved.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || saving) return;
    setState(() {
      saving = true;
      error = null;
    });
    try {
      policy['message'] = notice.text.trim();
      await widget.session.developerRequest(
        'PUT',
        'developer/controls/$scope',
        grant: widget.grant,
        body: {'revision': revision, 'policy': policy},
      );
      dirty = false;
      await widget.session.refreshControlPolicy();
      if (mounted) {
        message(context, 'Developer controls saved.');
        await load();
      }
    } catch (failure) {
      if (mounted) setState(() => error = '$failure');
    }
    if (mounted) setState(() => saving = false);
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !saving && !dirty,
    onPopInvokedWithResult: (didPop, result) async {
      if (didPop || saving) return;
      if (await confirmDiscard() && mounted) {
        setState(() => dirty = false);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.pop(context);
        });
      }
    },
    child: Scaffold(
      appBar: AppBar(
        title: const Text('Developer controls'),
        actions: [
          IconButton(
            tooltip: 'Reload controls',
            onPressed: saving || loading
                ? null
                : () async {
                    if (await confirmDiscard() && mounted) await load();
                  },
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(
                  widget.session.demoMode
                      ? 'LOCAL DEMO: switches apply only to this browser, not customer EXE/APK apps. Access expires after 10 minutes.'
                      : 'Global controls apply to every restaurant. A restaurant switch cannot override a disabled global switch. Access expires after 10 minutes.',
                ),
                const SizedBox(height: 16),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      error!,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
                if (snapshot != null) ...[
                  DropdownButtonFormField<String>(
                    key: ValueKey('$scope:$selectorVersion'),
                    initialValue: scope,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Apply to'),
                    items: [
                      for (final row in controls)
                        DropdownMenuItem(
                          value: '${row['scope']}',
                          child: Text(
                            '${row['name']}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: saving
                        ? null
                        : (value) async {
                            if (value == null || value == scope) return;
                            final allowed = await confirmDiscard();
                            if (mounted) {
                              setState(() {
                                selectorVersion++;
                                if (allowed) select(value);
                              });
                            }
                          },
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    title: const Text('App access'),
                    subtitle: const Text(
                      'Off pauses POS access; it keeps saved data and developer access.',
                    ),
                    value: policy['app_enabled'] == true,
                    onChanged: saving
                        ? null
                        : (value) => setState(() {
                            policy['app_enabled'] = value;
                            dirty = true;
                          }),
                  ),
                  TextField(
                    controller: notice,
                    enabled: !saving,
                    maxLength: 240,
                    decoration: const InputDecoration(
                      labelText: 'Message shown when app is paused',
                    ),
                    onChanged: (_) => setState(() => dirty = true),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    decoration: const InputDecoration(
                      labelText: 'Find a feature',
                      prefixIcon: Icon(Icons.search),
                    ),
                    onChanged: (value) =>
                        setState(() => query = value.toLowerCase()),
                  ),
                  Wrap(
                    spacing: 12,
                    children: [
                      for (final value in [true, false])
                        TextButton(
                          onPressed: saving
                              ? null
                              : () => setState(() {
                                  policy['features'] = {
                                    for (final key in developerFeatures.keys)
                                      key: value,
                                  };
                                  dirty = true;
                                }),
                          child: Text(
                            value
                                ? 'Enable all features'
                                : 'Disable all features',
                          ),
                        ),
                    ],
                  ),
                  for (final entry in developerFeatures.entries)
                    if (entry.value.toLowerCase().contains(query))
                      SwitchListTile(
                        title: Text(entry.value),
                        value: (policy['features'] as Map)[entry.key] != false,
                        subtitle: entry.key == 'sync'
                            ? const Text(
                                'Off keeps new saves in the durable local queue.',
                              )
                            : null,
                        onChanged: saving
                            ? null
                            : (value) => setState(() {
                                (policy['features'] as Map)[entry.key] = value;
                                dirty = true;
                              }),
                      ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: saving || !dirty || notice.text.trim().isEmpty
                        ? null
                        : save,
                    child: Text(
                      saving ? 'Applying controls…' : 'Apply controls',
                    ),
                  ),
                ],
              ],
            ),
    ),
  );
}
