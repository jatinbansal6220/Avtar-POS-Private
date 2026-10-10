import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/session.dart';

List<String> _savedPlatformNames(Json settings) {
  final raw = settings['online_platforms'];
  if (raw is! List) return const [];
  return raw
      .map((value) => value.toString().trim())
      .where((value) => value.isNotEmpty)
      .toSet()
      .toList();
}

/// Stores owner-added marketplaces once in restaurant settings. The same list
/// is then available for every later online order on this device.
Future<void> rememberOnlinePlatform(Session session, String name) async {
  final value = name.trim();
  if (value.isEmpty) return;
  final settings =
      (await session.local!.list('settings', limit: 1)).firstOrNull ??
      <String, dynamic>{};
  final saved = _savedPlatformNames(settings);
  if (saved.any((item) => item.toLowerCase() == value.toLowerCase())) return;
  settings['online_platforms'] = [...saved, value];
  await session.mutate('settings', settings);
}

/// Returns the API-safe code plus the display name used in order history/KOT.
Future<Json?> pickOnlinePlatform(BuildContext context, Session session) async {
  final settings =
      (await session.local!.list('settings', limit: 1)).firstOrNull ??
      <String, dynamic>{};
  final saved = _savedPlatformNames(settings)
      .where(
        (name) => ![
          'zomato',
          'swiggy',
          'direct online order',
        ].contains(name.toLowerCase()),
      )
      .toList();
  final choices = <(String, String)>[
    ('zomato', 'Zomato'),
    ('swiggy', 'Swiggy'),
    ('direct', 'Direct online order'),
    for (final name in saved) ('saved:$name', name),
    ('new', 'Add another platform'),
  ];
  String selected = 'zomato';
  final custom = TextEditingController();
  if (!context.mounted) {
    custom.dispose();
    return null;
  }
  final answer = await showDialog<Json>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Select online platform'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final choice in choices)
                    ChoiceChip(
                      label: Text(choice.$2),
                      selected: selected == choice.$1,
                      onSelected: (_) => setState(() => selected = choice.$1),
                    ),
                ],
              ),
              if (selected == 'new') ...[
                const SizedBox(height: 16),
                TextField(
                  controller: custom,
                  autofocus: true,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Platform name',
                    hintText: 'e.g. Magicpin',
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final entered = custom.text.trim();
              if (selected == 'new' && entered.isEmpty) return;
              final savedName = selected.startsWith('saved:')
                  ? selected.substring(6)
                  : '';
              final name = selected == 'new'
                  ? entered
                  : savedName.isNotEmpty
                  ? savedName
                  : switch (selected) {
                      'zomato' => 'Zomato',
                      'swiggy' => 'Swiggy',
                      'direct' => 'Direct online order',
                      _ => selected,
                    };
              Navigator.pop(dialogContext, {
                'online_platform':
                    ['zomato', 'swiggy', 'direct'].contains(selected)
                    ? selected
                    : 'other',
                'online_platform_name': name,
                if (selected == 'new') '_remember_platform': name,
              });
            },
            child: const Text('Start online order'),
          ),
        ],
      ),
    ),
  );
  // The dialog is still mounted briefly during its exit animation.
  await Future<void>.delayed(const Duration(milliseconds: 350));
  custom.dispose();
  return answer;
}

String onlinePlatformLabel(Json order) {
  final custom = (order['online_platform_name'] ?? '').toString().trim();
  if (custom.isNotEmpty) return custom;
  return switch (order['online_platform']) {
    'zomato' => 'Zomato',
    'swiggy' => 'Swiggy',
    'direct' => 'Direct online order',
    'other' => 'Other online platform',
    _ => 'Online order',
  };
}
