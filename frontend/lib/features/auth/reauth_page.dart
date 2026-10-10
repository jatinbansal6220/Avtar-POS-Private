import 'package:flutter/material.dart';

import '../../core/session.dart';

class ReauthPage extends StatefulWidget {
  final Session session;
  const ReauthPage(this.session, {super.key});
  @override
  State<ReauthPage> createState() => _ReauthPageState();
}

class _ReauthPageState extends State<ReauthPage> {
  final password = TextEditingController();
  bool busy = false;
  String? error;
  @override
  void dispose() {
    password.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    setState(() => busy = true);
    try {
      await widget.session.reauthenticate(password.text);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Renew sign-in')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              '${widget.session.user?['email']}',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            const Text(
              'Your drafts and pending changes will remain on this device.',
            ),
            const SizedBox(height: 24),
            TextField(
              controller: password,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Password'),
            ),
            const SizedBox(height: 20),
            if (error != null)
              Text(error!, style: const TextStyle(color: Colors.red)),
            FilledButton(
              onPressed: busy ? null : submit,
              child: Text(busy ? 'Signing in…' : 'Continue syncing'),
            ),
          ],
        ),
      ),
    ),
  );
}
