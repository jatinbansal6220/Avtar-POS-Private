import 'package:flutter/material.dart';

import '../../core/developer_reset_guard.dart';
import '../../core/session.dart';
import '../../ui/shared.dart';

/// Local terminal lock. It protects an already authenticated POS session
/// without requiring the server to be reachable when a restaurant is offline.
class AppLockPage extends StatefulWidget {
  final Session session;
  const AppLockPage(this.session, {super.key});

  @override
  State<AppLockPage> createState() => _AppLockPageState();
}

class _AppLockPageState extends State<AppLockPage> {
  final password = TextEditingController();
  final confirm = TextEditingController();
  bool busy = false;
  String? error;

  bool get creating => !widget.session.appLockConfigured;

  @override
  void dispose() {
    password.dispose();
    confirm.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (busy) return;
    if (creating && password.text != confirm.text) {
      setState(() => error = 'Password and confirmation do not match.');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (creating) {
        await widget.session.createAppLockPassword(password.text);
      } else {
        await widget.session.unlockApp(password.text);
      }
    } catch (failure) {
      if (mounted) setState(() => error = '$failure');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> resetPassword() async {
    final developerApproved = await requireDeveloperResetCode(context);
    if (!mounted || !developerApproved) return;
    final email = TextEditingController();
    final account = TextEditingController();
    final next = TextEditingController();
    final confirmation = TextEditingController();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        // Four password fields do not fit above an Android keyboard. Keep
        // actions pinned and make the fields independently scrollable.
        scrollable: true,
        title: const Text('Reset app password'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Enter the restaurant account password. Internet is required to reset a forgotten app password.',
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
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Account password'),
            ),
            TextField(
              controller: next,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'New app password'),
            ),
            TextField(
              controller: confirmation,
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
            child: const Text('Back'),
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
    final nextPassword = next.text;
    final confirmationValue = confirmation.text;
    email.dispose();
    account.dispose();
    next.dispose();
    confirmation.dispose();
    if (accepted != true) return;
    if (nextPassword != confirmationValue) {
      if (mounted) {
        setState(() => error = 'Password and confirmation do not match.');
      }
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.session.resetAppLockWithAccountPassword(
        accountEmail: accountEmail,
        accountPassword: accountPassword,
        newPassword: nextPassword,
      );
    } catch (failure) {
      if (mounted) setState(() => error = '$failure');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            24,
            24,
            24,
            24 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Card(
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Icon(Icons.lock_outline, size: 46, color: accent),
                        const SizedBox(height: 14),
                        Text(
                          creating
                              ? 'Create app password'
                              : 'Avtar Cooks POS locked',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          creating
                              ? 'Set a password to protect this POS terminal whenever the app starts.'
                              : '${widget.session.user?['restaurant_name'] ?? 'Restaurant'} — enter the app password to continue.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: secondaryText),
                        ),
                        const SizedBox(height: 22),
                        TextField(
                          controller: password,
                          autofocus: true,
                          obscureText: true,
                          enableSuggestions: false,
                          autocorrect: false,
                          onSubmitted: (_) => submit(),
                          decoration: InputDecoration(
                            labelText: creating
                                ? 'New app password'
                                : 'App password',
                          ),
                        ),
                        if (creating) ...[
                          const SizedBox(height: 12),
                          TextField(
                            controller: confirm,
                            obscureText: true,
                            enableSuggestions: false,
                            autocorrect: false,
                            onSubmitted: (_) => submit(),
                            decoration: const InputDecoration(
                              labelText: 'Confirm password',
                            ),
                          ),
                        ],
                        if (error != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            error!,
                            style: const TextStyle(color: Colors.red),
                          ),
                        ],
                        const SizedBox(height: 20),
                        FilledButton.icon(
                          onPressed: busy ? null : submit,
                          icon: busy
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.lock_open_outlined),
                          label: Text(
                            creating ? 'Save & continue' : 'Unlock app',
                          ),
                        ),
                        if (!creating)
                          TextButton(
                            onPressed: busy ? null : resetPassword,
                            child: const Text('Forgot / reset app password'),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
