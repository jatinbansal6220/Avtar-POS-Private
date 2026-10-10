import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/session.dart';

/// Visible on every screen so Android owners can approve a downloaded update
/// without needing to discover the Settings page.
class UpdateBanner extends StatelessWidget {
  final Session session;
  final GlobalKey<NavigatorState> navigatorKey;
  const UpdateBanner({
    super.key,
    required this.session,
    required this.navigatorKey,
  });

  Future<void> install(BuildContext context) async {
    final android = !kIsWeb && Platform.isAndroid;
    if (!android) {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Install update and restart?'),
          content: const Text(
            'Finish your current work first. Saved orders, bills and offline data will be preserved.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Later'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Install & restart'),
            ),
          ],
        ),
      );
      if (accepted != true) return;
    }
    try {
      await session.updater.installAndRestart(session);
      if (!kIsWeb && Platform.isWindows) {
        exit(0);
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: session.updater,
    builder: (context, _) {
      final updater = session.updater;
      if (!updater.enabled || updater.state != UpdateState.ready) {
        return const SizedBox.shrink();
      }
      return SafeArea(
        bottom: false,
        child: Material(
          color: Theme.of(context).colorScheme.secondaryContainer,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                const Icon(Icons.system_update),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Update ${updater.update?.version} downloaded.'),
                ),
                TextButton(
                  onPressed: () {
                    final overlay = navigatorKey.currentState?.overlay;
                    if (overlay != null) install(overlay.context);
                  },
                  child: const Text('Install update'),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
