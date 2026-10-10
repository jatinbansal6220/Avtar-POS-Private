import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'package:sqflite/sqflite.dart';
import 'package:crypto/crypto.dart';

import '../features/demo/demo_seed.dart';
import 'local_store.dart';
import 'models.dart';
import '../features/analytics/local_reports.dart';
import '../features/billing/billing_calculator.dart';
import 'build_info.dart';
import '../features/banks/upi_qr.dart';
import 'update_platform.dart';
import 'feature_policy.dart';
import '../features/purchases/data/purchase_math.dart';

part 'session_auth.dart';
part 'api_client.dart';
part 'sync_engine.dart';
part 'outbox_service.dart';
part 'inventory_service.dart';
part 'purchase_service.dart';
part 'update_service.dart';
part 'control_service.dart';

class Session extends ChangeNotifier {
  // Debug builds may opt into a local demo. Release builds are online by
  // default; DEMO_MODE=true must be supplied deliberately for a demo kiosk.
  static const offlineDemo = bool.fromEnvironment(
    'DEMO_MODE',
    defaultValue: kDebugMode,
  );
  static late SharedPreferences prefs;
  static const uuid = Uuid();
  static const _terminalIdentityKey = 'terminal_identity_v1';
  final http.Client client;
  final bool demoMode;
  Session({http.Client? client, bool? demoMode})
    : client = client ?? http.Client(),
      demoMode = demoMode ?? (client == null && offlineDemo);
  late final updater = AppUpdateService(client: client, demoMode: demoMode);
  final Map<String, ValueNotifier<int>> _resources = {};
  ValueNotifier<int> watch(String resource) =>
      _resources.putIfAbsent(resource, () => ValueNotifier(0));
  void dataChanged(Iterable<String> resources) {
    for (final resource in resources.toSet()) {
      watch(resource).value++;
    }
  }

  String base = '', token = '';
  Json controlPolicy = {};
  Timer? controlTimer;
  bool _controlFetching = false;
  bool developerPanelVisible = false;
  String? demoDeveloperGrant;
  DateTime? demoDeveloperGrantExpires;
  String? demoDeveloperIdentity;
  bool get appEnabled => controlPolicy['app_enabled'] != false;
  bool policyAllows(String feature) =>
      (controlPolicy['features'] as Map?)?[feature] != false;
  bool featureEnabled(String feature) => appEnabled && policyAllows(feature);
  void requireFeature(String feature) {
    if (!featureEnabled(feature)) {
      throw ApiFailure(
        403,
        appEnabled
            ? '${developerFeatures[feature] ?? feature} is disabled by the developer.'
            : '${controlPolicy['message'] ?? 'App access is paused. Contact the developer.'}',
      );
    }
  }

  Json? user;
  LocalStore? local;
  bool online = true, syncing = false, ready = false, expired = false;
  bool installingUpdate = false;
  bool appLocked = false, appLockConfigured = false, appLockOnMinimize = false;
  String? syncError;
  int queued = 0, conflicts = 0;
  Future<void> refreshOutboxCounts() async {
    if (local == null) return;
    final counts = await local!.db.rawQuery(
      "SELECT SUM(CASE WHEN state='pending' THEN 1 ELSE 0 END) pending, SUM(CASE WHEN state='conflict' THEN 1 ELSE 0 END) conflicts FROM outbox",
    );
    queued = number(counts.first['pending']);
    conflicts = number(counts.first['conflicts']);
  }

  Timer? timer;
  Timer? retryTimer;
  // A user action should attempt an upload immediately, even if a previous
  // connection attempt put the background worker into its retry backoff.
  // This remains separate from the timed retry, so an offline device is not
  // continuously polling the server.
  bool _syncRequestedWhileBusy = false;
  int syncFailures = 0;
  Duration get retryDelay => switch (syncFailures) {
    1 => const Duration(seconds: 10),
    2 => const Duration(seconds: 30),
    3 => const Duration(minutes: 1),
    _ => const Duration(minutes: 5),
  };
  void scheduleRetry() {
    retryTimer?.cancel();
    retryTimer = Timer(retryDelay, () {
      retryTimer = null;
      unawaited(sync());
    });
  }

  /// Queue a foreground save for immediate delivery. Local persistence has
  /// already completed at this point, so an unavailable server never blocks
  /// the cashier. If an upload is in progress, the worker makes one further
  /// pass after it ends; recurring failures still use exponential backoff.
  void requestImmediateSync() {
    if (demoMode || local == null || expired || installingUpdate) return;
    retryTimer?.cancel();
    retryTimer = null;
    if (syncing) {
      _syncRequestedWhileBusy = true;
      return;
    }
    unawaited(sync());
  }

  void syncSucceeded() {
    syncFailures = 0;
    retryTimer?.cancel();
    retryTimer = null;
  }

  void syncFailed() {
    syncFailures = (syncFailures + 1).clamp(1, 4);
    scheduleRetry();
  }

  void changed() => notifyListeners();
  void restoreFailed() {
    ready = true;
    user = null;
    notifyListeners();
  }

  void scheduleUpdateCheck() {
    updater.startAutomaticUpdates(this);
  }

  bool get manager => ['owner', 'manager'].contains(user?['role']);
  bool get cashier => manager || user?['role'] == 'cashier';

  String get _appLockKey => 'app_lock_hash_v1_${user?['id'] ?? 'unknown'}';
  String get _appLockMinimizeKey =>
      'app_lock_on_minimize_v1_${user?['id'] ?? 'unknown'}';

  String _appLockHash(String password) => sha256
      .convert(utf8.encode('avtar-pos-app-lock-v1:${user?['id']}:$password'))
      .toString();

  void _validateAppLockPassword(String password) {
    if (password.trim().length < 4 || password.length > 128) {
      throw ApiFailure(
        422,
        'App password must be between 4 and 128 characters.',
      );
    }
  }

  /// Called after a successful account login. New terminals use the account
  /// password as their first local lock password; a customised lock is never
  /// overwritten by a later login.
  Future<void> initialiseAppLockFromLogin(String password) async {
    final saved = prefs.getString(_appLockKey) ?? '';
    if (saved.isEmpty) {
      _validateAppLockPassword(password);
      await prefs.setString(_appLockKey, _appLockHash(password));
    }
    appLockConfigured = true;
    appLockOnMinimize = prefs.getBool(_appLockMinimizeKey) ?? false;
    appLocked = false;
  }

  /// A cached production session must always unlock after a fresh app launch.
  /// Older installs without a saved lock hash are routed to the one-time setup
  /// screen rather than opening the POS unprotected.
  Future<void> restoreAppLock() async {
    if (user == null) return;
    appLockConfigured = (prefs.getString(_appLockKey) ?? '').isNotEmpty;
    appLockOnMinimize = prefs.getBool(_appLockMinimizeKey) ?? false;
    appLocked = true;
  }

  Future<void> unlockApp(String password) async {
    if (!appLockConfigured) {
      throw ApiFailure(422, 'Create an app password first.');
    }
    if (_appLockHash(password) != (prefs.getString(_appLockKey) ?? '')) {
      throw ApiFailure(403, 'App password is incorrect.');
    }
    appLocked = false;
    notifyListeners();
  }

  Future<void> createAppLockPassword(String password) async {
    _validateAppLockPassword(password);
    await prefs.setString(_appLockKey, _appLockHash(password));
    appLockConfigured = true;
    appLocked = false;
    notifyListeners();
  }

  Future<void> changeAppLockPassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    if (appLockConfigured &&
        _appLockHash(currentPassword) != (prefs.getString(_appLockKey) ?? '')) {
      throw ApiFailure(403, 'Current app password is incorrect.');
    }
    await createAppLockPassword(newPassword);
  }

  /// Forgot-password recovery requires the genuine restaurant account
  /// password online. It renews the session token and never stores that raw
  /// account password.
  Future<void> resetAppLockWithAccountPassword({
    required String accountEmail,
    required String accountPassword,
    required String newPassword,
  }) async {
    final expectedEmail = '${user?['email'] ?? ''}'.trim().toLowerCase();
    if (accountEmail.trim().toLowerCase() != expectedEmail) {
      throw ApiFailure(
        403,
        'Enter the same restaurant login email for this app.',
      );
    }
    await reauthenticate(accountPassword);
    await createAppLockPassword(newPassword);
  }

  Future<void> setAppLockOnMinimize(bool value) async {
    appLockOnMinimize = value;
    await prefs.setBool(_appLockMinimizeKey, value);
    notifyListeners();
  }

  void lockAfterMinimize() {
    if (user == null || !appLockConfigured || !appLockOnMinimize) return;
    appLocked = true;
    notifyListeners();
  }

  /// Stable for one app installation, including after a local SQLite reset.
  /// It lets the server preserve normal daily bill numbers made by separate
  /// offline terminals without treating them as the same receipt.
  Future<String> terminalId() async {
    final saved = prefs.getString(_terminalIdentityKey)?.trim() ?? '';
    if (RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
      caseSensitive: false,
    ).hasMatch(saved)) {
      return saved;
    }
    final created = uuid.v4();
    await prefs.setString(_terminalIdentityKey, created);
    return created;
  }

  String get terminalLabel => kIsWeb
      ? 'Browser terminal'
      : Platform.isWindows
      ? 'Windows counter'
      : 'Android terminal';
  Future<void> logout() async {
    if (syncing) {
      throw ApiFailure(
        409,
        'Sync is completing. Try signing out again in a moment.',
      );
    }
    if (queued > 0 || conflicts > 0 || (await local!.drafts()).isNotEmpty) {
      throw ApiFailure(409, 'Sync or review local drafts before signing out.');
    }
    await request('POST', 'auth/logout');
    timer?.cancel();
    retryTimer?.cancel();
    controlTimer?.cancel();
    controlPolicy = {};
    await prefs.remove('session');
    demoDeveloperGrant = null;
    demoDeveloperGrantExpires = null;
    demoDeveloperIdentity = null;
    await local?.db.close();
    local = null;
    user = null;
    token = '';
    appLocked = false;
    appLockConfigured = false;
    appLockOnMinimize = false;
    notifyListeners();
  }

  @override
  void dispose() {
    controlTimer?.cancel();
    timer?.cancel();
    retryTimer?.cancel();
    updater.dispose();
    client.close();
    super.dispose();
  }
}
