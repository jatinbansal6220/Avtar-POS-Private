import 'package:flutter/material.dart';

import '../core/session.dart';
import 'shared.dart';

class LoginPage extends StatefulWidget {
  final Session session;
  const LoginPage(this.session, {super.key});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final form = GlobalKey<FormState>();
  final url = TextEditingController(
    text: const String.fromEnvironment(
      'API_BASE_URL',
      defaultValue: 'https://avtarpos.duckdns.org/api',
    ),
  );
  final email = TextEditingController(), password = TextEditingController();
  final name = TextEditingController(), code = TextEditingController();
  bool busy = false, obscure = true, creating = false;
  String? error;
  @override
  void dispose() {
    url.dispose();
    email.dispose();
    password.dispose();
    name.dispose();
    code.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (!form.currentState!.validate()) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (creating) {
        await widget.session.register(
          name.text,
          email.text,
          password.text,
          code.text,
        );
      } else {
        await widget.session.login(url.text, email.text, password.text);
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: LayoutBuilder(
      builder: (context, box) => Row(
        children: [
          if (box.maxWidth > 900)
            Expanded(
              child: Container(
                color: ink,
                padding: const EdgeInsets.all(64),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.restaurant, color: Colors.white, size: 32),
                        SizedBox(width: 12),
                        Text(
                          'AVTAR / POS',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 21,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 2,
                          ),
                        ),
                      ],
                    ),
                    const Spacer(),
                    const Text(
                      'Service moves fast.\nKeep every order\nin its place.',
                      style: TextStyle(
                        fontSize: 48,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                        height: 1.15,
                      ),
                    ),
                    const SizedBox(height: 30),
                    Text(
                      'Tables · Orders · Billing · Your business',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.6),
                        fontSize: 16,
                      ),
                    ),
                    const Spacer(),
                    const Text(
                      'RESTAURANT OPERATIONS',
                      style: TextStyle(
                        color: Colors.white54,
                        letterSpacing: 2,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(28),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 400),
                  child: Form(
                    key: form,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (box.maxWidth <= 900) ...[
                          const Icon(Icons.restaurant, color: accent, size: 36),
                          const SizedBox(height: 28),
                        ],
                        const Text(
                          'ZELOVIX / AVTAR POS',
                          style: TextStyle(
                            color: accent,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 2,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Sign in to your restaurant',
                          style: Theme.of(context).textTheme.headlineMedium,
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'Use the account provided by your administrator.',
                          style: TextStyle(color: Colors.black54),
                        ),
                        const SizedBox(height: 32),
                        if (creating) ...[
                          TextFormField(
                            controller: name,
                            decoration: const InputDecoration(
                              labelText: 'Restaurant / owner name',
                            ),
                            validator: (s) => s == null || s.trim().isEmpty
                                ? 'Name is required'
                                : null,
                          ),
                          const SizedBox(height: 18),
                        ],
                        TextFormField(
                          controller: email,
                          keyboardType: TextInputType.emailAddress,
                          autofillHints: const [AutofillHints.username],
                          decoration: const InputDecoration(
                            labelText: 'Email address',
                          ),
                          validator: (s) => s != null && s.contains('@')
                              ? null
                              : 'Enter a valid email',
                        ),
                        const SizedBox(height: 18),
                        TextFormField(
                          controller: password,
                          obscureText: obscure,
                          autofillHints: const [AutofillHints.password],
                          onFieldSubmitted: (_) => busy ? null : submit(),
                          decoration: InputDecoration(
                            labelText: 'Password',
                            suffixIcon: IconButton(
                              onPressed: () =>
                                  setState(() => obscure = !obscure),
                              icon: Icon(
                                obscure
                                    ? Icons.visibility_off_outlined
                                    : Icons.visibility_outlined,
                              ),
                            ),
                          ),
                          validator: (s) => s == null || s.isEmpty
                              ? 'Password is required'
                              : null,
                        ),
                        if (creating) ...[
                          const SizedBox(height: 18),
                          TextFormField(
                            controller: code,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Activation code',
                              hintText: '12345',
                            ),
                            validator: (s) =>
                                s == null ||
                                    s.trim().length < 4 ||
                                    s.trim().length > 5
                                ? 'Enter the 4 or 5 digit code'
                                : null,
                          ),
                        ],
                        TextButton(
                          onPressed: busy
                              ? null
                              : () => setState(() => creating = !creating),
                          child: Text(
                            creating
                                ? 'Already have an account? Sign in'
                                : 'Create new account',
                          ),
                        ),
                        if (error != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 16),
                            child: Text(
                              error!,
                              style: const TextStyle(color: Colors.red),
                            ),
                          ),
                        const SizedBox(height: 26),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            onPressed: busy ? null : submit,
                            child: Text(busy ? 'Signing in…' : 'Sign in'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
