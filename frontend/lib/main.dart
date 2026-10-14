import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/session.dart';
import 'ui/shared.dart';
import 'ui/login.dart';
import 'ui/home_page.dart';
import 'features/auth/app_lock_page.dart';
import 'features/auth/reauth_page.dart';
import 'features/updates/update_banner.dart';
import 'features/developer/developer_panel.dart';
import 'features/developer/feature_access.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final session = Session();
  runApp(AvtarApp(session: session));
  try {
    await session.restore();
  } catch (_) {
    session.restoreFailed();
  }
}

class AvtarApp extends StatefulWidget {
  final Session session;
  const AvtarApp({super.key, required this.session});

  @override
  State<AvtarApp> createState() => _AvtarAppState();
}

class _AvtarAppState extends State<AvtarApp> with WidgetsBindingObserver {
  final navigatorKey = GlobalKey<NavigatorState>();
  Session get session => widget.session;
  bool developerOpening = false;
  bool renewingAccount = false;
  bool get showAccessPause =>
      session.user != null &&
      !session.appEnabled &&
      !session.developerPanelVisible &&
      !renewingAccount;
  Future<void> renewAccount() async {
    if (renewingAccount || developerOpening || session.installingUpdate) return;
    final context = navigatorKey.currentContext;
    if (context == null) return;
    setState(() => renewingAccount = true);
    try {
      await Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => ReauthPage(session)));
      await session.refreshControlPolicy();
    } finally {
      if (mounted) setState(() => renewingAccount = false);
    }
  }

  Future<void> developerPanel() async {
    if (developerOpening ||
        renewingAccount ||
        !session.ready ||
        session.accountLoginRequired ||
        session.installingUpdate) {
      return;
    }
    final context = navigatorKey.currentContext;
    if (context == null) return;
    setState(() => developerOpening = true);
    try {
      await openDeveloperPanel(context, session);
    } finally {
      if (mounted) setState(() => developerOpening = false);
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Desktop/window minimization reaches hidden, while some Android and
    // Windows paths reach paused. Lock only when the owner enabled it.
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      widget.session.lockAfterMinimize();
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    navigatorKey: navigatorKey,
    title: 'Avtar POS',
    debugShowCheckedModeBanner: false,
    theme: appTheme(),
    scrollBehavior: const DesktopScrollBehavior(),
    builder: (context, child) => AnimatedBuilder(
      animation: session,
      builder: (context, _) => CallbackShortcuts(
        bindings: {
          const SingleActivator(
            LogicalKeyboardKey.f12,
            control: true,
            shift: true,
          ): developerPanel,
        },
        child: Focus(
          autofocus: true,
          child: ControlScope(
            session: session,
            child: AbsorbPointer(
              absorbing: session.installingUpdate,
              child: Column(
                children: [
                  UpdateBanner(session: session, navigatorKey: navigatorKey),
                  Expanded(
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: ExcludeFocus(
                            excluding: showAccessPause,
                            child: Offstage(
                              offstage: showAccessPause,
                              child: child!,
                            ),
                          ),
                        ),
                        if (showAccessPause)
                          Positioned.fill(
                            child: Material(
                              color: Theme.of(context).scaffoldBackgroundColor,
                              child: Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(24),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(
                                        Icons.pause_circle_outline,
                                        size: 52,
                                      ),
                                      const SizedBox(height: 16),
                                      const Text(
                                        'App access paused',
                                        style: TextStyle(
                                          fontSize: 22,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      const SizedBox(height: 12),
                                      Text(
                                        '${session.controlPolicy['message'] ?? 'Please contact the developer.'}',
                                        textAlign: TextAlign.center,
                                      ),
                                      const SizedBox(height: 24),
                                      OutlinedButton(
                                        onPressed: () =>
                                            session.refreshControlPolicy(),
                                        child: const Text('Check access again'),
                                      ),
                                      TextButton(
                                        onPressed: developerPanel,
                                        child: const Text('Developer access'),
                                      ),
                                      TextButton(
                                        onPressed: renewAccount,
                                        child: const Text('Sign in again'),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
    home: AnimatedBuilder(
      animation: session,
      builder: (context, _) => !session.ready
          ? const Scaffold(
              body: Center(
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          : session.accountLoginRequired ||
                session.user == null ||
                session.local == null
          ? LoginPage(session)
          : session.appLocked
          ? AppLockPage(session)
          : HomePage(session),
    ),
  );
}
