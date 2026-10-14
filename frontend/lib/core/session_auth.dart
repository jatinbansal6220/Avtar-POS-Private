part of 'session.dart';

extension SessionAuth on Session {
  static const liveBase = 'https://avtarpos.duckdns.org/api';

  Future<void> _provisionDemoLock() async {
    const password = String.fromEnvironment('DEMO_APP_PASSWORD');
    if (!demoMode || token != 'demo-token' || password.isEmpty) return;
    // Explicit demo builds can provision a lock once without clearing the
    // account's database. Never reset an authenticated production account.
    final marker = 'demo_lock_provisioned_${user!['id']}';
    final fingerprint = _appLockHash(password);
    if (Session.prefs.getString(marker) == fingerprint) return;
    // Startup/login still needs to open SQLite. Publishing an unlocked
    // session here would mount pages that require local before it exists.
    _validateAppLockPassword(password);
    await Session.prefs.setString(_appLockKey, fingerprint);
    appLockConfigured = true;
    await Session.prefs.setString(marker, fingerprint);
  }

  Future<void> register(
    String name,
    String email,
    String password,
    String code,
  ) async {
    if (syncing) throw ApiFailure(409, 'Sync is completing. Please try again.');
    base = liveBase;
    final data = await request(
      'POST',
      'auth/register',
      body: {
        'name': name.trim(),
        'email': email.trim(),
        'password': password,
        'activation_code': code.trim(),
        'device_name': kIsWeb
            ? 'Browser terminal'
            : Platform.isWindows
            ? 'Windows counter'
            : 'Android terminal',
      },
    );
    await _detachLocalAccount();
    token = data['token'];
    user = data['user'];
    expired = false;
    await initialiseAppLockFromLogin(password);
    await cacheAccountLogin(password);
    accountLoginRequired = false;
    await refreshBusinessClock();
    await Session.prefs.setString(
      'session',
      jsonEncode({'base': base, 'token': token, 'user': user}),
    );
    await _open();
    // A new live login is the strongest indication that the device is back
    // online. Start one explicit pass in addition to the background worker,
    // so old pending work does not wait for a timer tick after sign-in.
    await sync();
    changed();
    scheduleUpdateCheck();
  }

  Future<void> reauthenticate(String password) async {
    final data = await request(
      'POST',
      'auth/login',
      body: {
        'email': user!['email'],
        'password': password,
        'device_name': kIsWeb
            ? 'Browser terminal'
            : Platform.isWindows
            ? 'Windows counter'
            : 'Android terminal',
      },
    );
    if (data['user']['id'] != user!['id']) {
      throw ApiFailure(403, 'Sign in with the same restaurant account.');
    }
    token = data['token'];
    user = data['user'];
    expired = false;
    await cacheAccountLogin(password);
    await refreshBusinessClock();
    await Session.prefs.setString(
      'session',
      jsonEncode({'base': base, 'token': token, 'user': user}),
    );
    changed();
    unawaited(sync());
  }

  Future<void> restore() async {
    Session.prefs = await SharedPreferences.getInstance();
    if (demoMode) {
      // Local previews open directly. Keep the real restaurant session in
      // its own preference and retain the existing demo SQLite account.
      final cached =
          Session.prefs.getString('demo_session') ??
          Session.prefs.getString('session');
      Json? demoUser;
      if (cached != null) {
        try {
          final data = jsonDecode(cached) as Json;
          if (data['token'] == 'demo-token' &&
              data['user'] is Map &&
              data['user']['id'] != null) {
            demoUser = Map<String, dynamic>.from(data['user']);
          }
        } catch (_) {
          // An invalid session preference never clears business records.
        }
      }
      base = liveBase;
      token = 'demo-token';
      user =
          demoUser ??
          {
            'id': 1,
            'name': 'Demo Owner',
            'email': 'local-demo@example.com',
            'role': 'owner',
            'restaurant_name': 'Avtar Cooks Demo',
          };
      expired = false;
      appLocked = false;
      await _open(syncEnabled: false);
      await seedOfflineDemo(local!);
      await Session.prefs.setString(
        'demo_session',
        jsonEncode({'base': base, 'token': token, 'user': user}),
      );
      ready = true;
      changed();
      return;
    }
    final saved = Session.prefs.getString('session');
    if (saved != null) {
      try {
        final data = jsonDecode(saved) as Json;
        final savedBase = '${data['base'] ?? ''}'.trim();
        final savedToken = '${data['token'] ?? ''}'.trim();
        final savedUser = data['user'];
        final uri = Uri.tryParse(savedBase);
        final validAddress =
            uri != null &&
            uri.hasAuthority &&
            ['http', 'https'].contains(uri.scheme);
        if (savedToken.isEmpty ||
            savedUser is! Map ||
            !validAddress ||
            savedBase.replaceAll(RegExp(r'/+$'), '') != liveBase) {
          // Release builds must never reopen a cached session against the
          // retired InfinityFree endpoint or another manually saved address.
          await _forgetInvalidSession();
        } else {
          base = savedBase.replaceAll(RegExp(r'/+$'), '');
          token = savedToken;
          user = Map<String, dynamic>.from(savedUser);

          if (!demoMode) {
            try {
              // Do not let a stale local demo token open the production POS.
              // A network failure is deliberately allowed: a previously
              // authenticated terminal must remain usable offline.
              final remoteUser = await request('GET', 'auth/me');
              if ('${remoteUser['id']}' != '${user!['id']}') {
                throw ApiFailure(401, 'Saved account is no longer valid.');
              }
              user = remoteUser;
            } on ApiFailure catch (error) {
              if (error.status == 401 || error.status == 403) {
                await _forgetInvalidSession();
              }
            } on SocketException {
              online = false;
            } on TimeoutException {
              online = false;
            } on http.ClientException {
              online = false;
            }
          }
          if (user != null) {
            await _provisionDemoLock();
            await restoreAppLock();
            accountLoginRequired = !demoMode;
            appLocked = false;
            await _open(syncEnabled: demoMode);
            if (demoMode) await seedOfflineDemo(local!);
          }
        }
      } catch (_) {
        await _forgetInvalidSession();
      }
    }
    ready = true;
    changed();
    scheduleUpdateCheck();
  }

  Future<void> _forgetInvalidSession() async {
    demoDeveloperGrant = null;
    demoDeveloperGrantExpires = null;
    demoDeveloperIdentity = null;
    controlTimer?.cancel();
    controlPolicy = {};
    timer?.cancel();
    retryTimer?.cancel();
    await local?.db.close();
    local = null;
    base = '';
    token = '';
    user = null;
    expired = false;
    appLocked = false;
    appLockConfigured = false;
    accountLoginRequired = false;
    appLockOnMinimize = false;
    await Session.prefs.remove('session');
  }

  Future<void> login(String apiAddress, String email, String password) async {
    if (syncing) {
      throw ApiFailure(409, 'Sync is completing. Please try signing in again.');
    }
    // Temporary local UI demo bypass. Remove before deployment.
    final demoAuthBypass = demoMode;
    if (demoAuthBypass) {
      base = liveBase;
      token = 'demo-token';
      user = {
        'id': 1,
        'name': email.trim().isEmpty ? 'Demo Owner' : email.trim(),
        'email': email.trim(),
        'role': 'owner',
        'restaurant_name': 'Avtar Cooks Demo',
      };
      expired = false;
      await _provisionDemoLock();
      appLocked = false;
      await _open(syncEnabled: false);
      await seedOfflineDemo(local!);
      await Session.prefs.setString(
        'demo_session',
        jsonEncode({'base': base, 'token': token, 'user': user}),
      );
      changed();
      scheduleUpdateCheck();
      return;
    }
    // The app has a fixed production endpoint. This avoids stale local
    // settings sending an owner login to the retired server.
    base = liveBase;
    Json data;
    try {
      data = await request(
        'POST',
        'auth/login',
        body: {
          'email': email.trim(),
          'password': password,
          'device_name': kIsWeb
              ? 'Browser terminal'
              : Platform.isWindows
              ? 'Windows counter'
              : 'Android terminal',
        },
      );
    } catch (error) {
      final networkUnavailable =
          error is SocketException ||
          error is TimeoutException ||
          error is http.ClientException;
      final sameAccount =
          email.trim().toLowerCase() ==
          '${user?['email'] ?? ''}'.trim().toLowerCase();
      if (!networkUnavailable ||
          !accountLoginRequired ||
          !sameAccount ||
          local == null ||
          expired ||
          token.isEmpty)
        rethrow;
      final cached = Session.prefs.getString(_accountLoginKey) ?? '';
      if (!await verifyCachedLogin(cached, password)) {
        throw ApiFailure(
          403,
          cached.isEmpty
              ? 'Connect to the internet once to verify this account for offline sign-in.'
              : 'Email or password is incorrect.',
        );
      }
      accountLoginRequired = false;
      appLocked = false;
      online = false;
      await startControlPolicy();
      _startAccountSyncTimer();
      await sync();
      changed();
      return;
    }
    await _detachLocalAccount();
    token = data['token'];
    user = data['user'];
    expired = false;
    await initialiseAppLockFromLogin(password);
    await cacheAccountLogin(password);
    await refreshBusinessClock();
    await Session.prefs.setString(
      'session',
      jsonEncode({'base': base, 'token': token, 'user': user}),
    );
    await _open();
    accountLoginRequired = false;
    // Local save never waits for the network, but a successful login should
    // flush the durable queue before the owner starts a new billing session.
    await sync();
    changed();
    scheduleUpdateCheck();
  }

  Future<void> _open({bool syncEnabled = true}) async {
    local = await LocalStore.open('$base/${user!['id']}');
    // Older clients accepted an unrelated 200 JSON response as an empty bill
    // page and stored `complete`, which prevented historical invoices from
    // being requested again. Reset only that paging cursor once; existing
    // local bills and pending outbox work remain untouched.
    if (await local!.meta('bills_history_contract') != '2') {
      await local!.setMeta('bills_history_cursor', '');
      await local!.setMeta('bills_history_contract', '2');
    }
    await refreshOutboxCounts();
    if (!syncEnabled && !demoMode) return;
    await startControlPolicy();
    if (!syncEnabled || demoMode) return;
    unawaited(refreshBusinessClock());
    _startAccountSyncTimer();
  }

  String get _accountLoginKey => 'account_login_pbkdf2_v1_$base/${user!['id']}';

  Future<void> _detachLocalAccount() async {
    timer?.cancel();
    retryTimer?.cancel();
    controlTimer?.cancel();
    await local?.db.close();
    local = null;
    controlPolicy = {};
    syncError = null;
    syncFailures = 0;
    queued = 0;
    conflicts = 0;
    _syncRequestedWhileBusy = false;
    demoDeveloperGrant = null;
    demoDeveloperGrantExpires = null;
    demoDeveloperIdentity = null;
  }

  Future<void> cacheAccountLogin(String password) async {
    if (demoMode || user == null) return;
    await Session.prefs.setString(
      _accountLoginKey,
      await createCachedLogin(password),
    );
  }

  void _startAccountSyncTimer() {
    timer?.cancel();
    // Pull remote changes while connected; failed writes use the backoff scheduler.
    timer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (online) unawaited(sync());
    });
  }

  /// Health is intentionally public and tiny. It is used only to align the
  /// local business clock; a failed probe never blocks local/offline work.
  Future<void> refreshBusinessClock() async {
    if (demoMode || base.isEmpty) return;
    try {
      final health = await request('GET', 'health');
      updateIndiaClock(health['timestamp']);
    } catch (_) {
      // Offline-first fallback: indiaNow() continues from the device clock.
    }
  }
}
