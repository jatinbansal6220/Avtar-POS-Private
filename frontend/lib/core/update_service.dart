part of 'session.dart';

enum UpdateState {
  idle,
  checking,
  available,
  downloading,
  ready,
  error,
  disabled,
}

class AppUpdate {
  final String version;
  final String notes;
  final Uri asset;
  final String sha256;
  const AppUpdate({
    required this.version,
    required this.notes,
    required this.asset,
    required this.sha256,
  });
}

/// HTTPS release data supplies the SHA-256 checksum for each download.
/// No GitHub credential is ever stored in the POS application.
class AppUpdateService extends ChangeNotifier {
  final http.Client client;
  final bool demoMode;
  bool policyEnabled = true;
  void setPolicyEnabled(bool value) {
    if (policyEnabled == value) return;
    policyEnabled = value;
    notifyListeners();
  }

  AppUpdateService({required this.client, required this.demoMode});

  UpdateState state = UpdateState.idle;
  AppUpdate? update;
  String status = 'Ready to check for updates.';
  int progress = 0;
  String? _downloadedInstaller;
  Timer? _automaticTimer;
  bool _automaticRunning = false;
  bool _installing = false;
  DateTime? _lastAutomaticCheck;

  /// Checks at startup and every five minutes while the app is running.
  /// Thirty-second ticks also apply a ready Windows update at a safe boundary.
  void startAutomaticUpdates(Session session) {
    if (!enabled || _automaticTimer != null) return;
    _automaticTimer = Timer(const Duration(seconds: 15), () {
      unawaited(runAutomaticUpdate(session));
      _automaticTimer = Timer.periodic(const Duration(seconds: 30), (_) {
        unawaited(runAutomaticUpdate(session));
      });
    });
  }

  Future<void> runAutomaticUpdate(Session session) async {
    if (!session.policyAllows('updates')) return;
    if (!enabled || _automaticRunning || isBusy || _installing) return;
    _automaticRunning = true;
    try {
      final now = DateTime.now();
      if (state != UpdateState.ready &&
          (_lastAutomaticCheck == null ||
              now.difference(_lastAutomaticCheck!) >=
                  const Duration(minutes: 5))) {
        _lastAutomaticCheck = now;
        await check(silent: true);
        if (state == UpdateState.available) await download();
      }
      if (!canInstall || updaterPlatform() != 'windows') return;
      if (!await canAutomaticallyRestart(session)) {
        status = 'Update downloaded. It will install at a safe app start or unlock screen; you can also install from Settings.';
        notifyListeners();
        return;
      }
      await installAndRestart(session, automatic: true);
      exit(0);
    } catch (error) {
      state = UpdateState.error;
      status = 'Automatic update will retry: $error';
      notifyListeners();
    } finally {
      _automaticRunning = false;
    }
  }

  /// Never restart an active counter or discard durable offline work.
  Future<bool> canAutomaticallyRestart(Session session) async {
    if (!session.ready ||
        session.syncing ||
        (session.user != null && !session.appLocked)) {
      return false;
    }
    if (session.local == null) return session.user == null;
    await session.refreshOutboxCounts();
    return !session.syncing &&
        session.queued == 0 &&
        session.conflicts == 0 &&
        (await session.local!.drafts()).isEmpty &&
        (session.user == null || session.appLocked);
  }

  bool get enabled =>
      policyEnabled &&
      !kDebugMode &&
      !demoMode &&
      !kIsWeb &&
      ['windows', 'android'].contains(updaterPlatform());
  bool get canInstall => updaterCanInstall() && _downloadedInstaller != null;
  bool get isBusy =>
      state == UpdateState.checking || state == UpdateState.downloading;

  Future<void> check({bool silent = false}) async {
    if (isBusy || state == UpdateState.ready || _installing) return;
    if (!enabled) {
      state = UpdateState.disabled;
      status = !policyEnabled
          ? 'Client updates are disabled by the developer.'
          : kDebugMode
          ? 'Updates are disabled in a debug build.'
          : 'Updates are disabled in demo mode.';
      notifyListeners();
      return;
    }
    state = UpdateState.checking;
    status = 'Checking for updates…';
    notifyListeners();
    try {
      final uri = Uri.parse(appReleaseManifest);
      String body;
      try {
        final response = await client
            .get(uri)
            .timeout(const Duration(seconds: 12));
        if (response.statusCode == 404) {
          state = UpdateState.idle;
          status = 'No published update is available yet.';
          notifyListeners();
          return;
        }
        if (response.statusCode != 200) {
          throw StateError('Update server returned ${response.statusCode}.');
        }
        body = response.body;
      } catch (error) {
        if (!isCertificateTrustError(error)) rethrow;
        // Older Windows installations can expose a smaller CA bundle to
        // Dart/BoringSSL than to Windows. This fallback uses Windows' own
        // trusted store, and the installer is still SHA-256 verified.
        body = await fetchUpdateManifestWithSystemTrust(uri);
      }
      if (body.isEmpty) {
        throw StateError('Update server returned an empty manifest.');
      }
      final json = Map<String, dynamic>.from(jsonDecode(body) as Map);
      final releases = Map<String, dynamic>.from(
        json['platforms'] as Map? ?? {},
      );
      final platform = Map<String, dynamic>.from(
        releases[updaterPlatform()] as Map? ?? {},
      );
      final version = '${json['version'] ?? ''}'.trim();
      final url = '${platform['url'] ?? ''}'.trim();
      final hash = '${platform['sha256'] ?? ''}'.trim().toLowerCase();
      if (!_isVersion(version) ||
          url.isEmpty ||
          Uri.tryParse(url)?.scheme != 'https' ||
          Uri.tryParse(url)?.hasAuthority != true ||
          !_isSha256(hash)) {
        throw StateError('Published update information is invalid.');
      }
      if (_compareVersions(version, appVersion) <= 0) {
        state = UpdateState.idle;
        status = 'You already have the latest version ($appVersion).';
        update = null;
      } else {
        _downloadedInstaller = null;
        update = AppUpdate(
          version: version,
          notes: '${json['notes'] ?? 'A new AvtarPOS update is ready.'}'.trim(),
          asset: Uri.parse(url),
          sha256: hash,
        );
        state = UpdateState.available;
        status = 'Version $version is available.';
      }
    } catch (error) {
      state = UpdateState.error;
      status = silent
          ? 'Update check will retry automatically.'
          : 'Could not check updates: $error';
    }
    notifyListeners();
  }

  Future<void> download() async {
    if (!policyEnabled)
      throw StateError('Client updates are disabled by the developer.');
    final release = update;
    if (release == null ||
        isBusy ||
        state == UpdateState.ready ||
        _installing) {
      return;
    }
    state = UpdateState.downloading;
    progress = 0;
    status = 'Downloading update…';
    notifyListeners();
    try {
      final file = await downloadUpdate(
        client,
        release.asset,
        updaterPlatform() == 'android'
            ? 'AvtarCook-${release.version}.apk'
            : 'AvtarPOS-Setup-${release.version}.exe',
        (value) {
          progress = value;
          status = 'Downloading update… $value%';
          notifyListeners();
        },
      );
      final digest = (await sha256.bind(File(file).openRead()).first)
          .toString();
      if (digest != release.sha256) {
        await File(file).delete();
        throw StateError(
          'Security check failed: downloaded installer hash did not match.',
        );
      }
      _downloadedInstaller = file;
      progress = 100;
      state = UpdateState.ready;
      status = updaterPlatform() == 'android'
          ? 'Update downloaded and verified. Tap Install update and approve the Android prompt.'
          : 'Update is ready to install.';
    } catch (error) {
      state = UpdateState.error;
      status = 'Update download failed: $error';
    }
    notifyListeners();
  }

  Future<void> installAndRestart(
    Session session, {
    bool automatic = false,
  }) async {
    if (!session.policyAllows('updates'))
      throw StateError('Client updates are disabled by the developer.');
    if (!canInstall) throw StateError('Download the update first.');
    if (_installing) {
      throw StateError('An update installation is already starting.');
    }
    _installing = true;
    session.installingUpdate = true;
    session.changed();
    try {
      if (automatic && !await canAutomaticallyRestart(session)) {
        throw StateError('The counter became busy; update deferred.');
      }
      await session.refreshOutboxCounts();
      if (session.syncing) {
        throw StateError(
          'A sync is currently running. Please wait a moment and try again.',
        );
      }
      final hasLocalWork =
          session.queued > 0 ||
          session.conflicts > 0 ||
          (await session.local?.drafts())?.isNotEmpty == true;
      if (hasLocalWork) {
        // Only the runtime is replaced; durable data stays in AppData.
        status = 'Updating safely. Pending sync, review items and drafts are preserved.';
        notifyListeners();
      }
      // Recheck the file immediately before handing it to the OS installer.
      final digest =
          (await sha256.bind(File(_downloadedInstaller!).openRead()).first)
              .toString();
      if (digest != update!.sha256) {
        _downloadedInstaller = null;
        state = UpdateState.error;
        status = 'Installer checksum changed. Download the update again.';
        notifyListeners();
        throw StateError(
          'Installer checksum changed. Download the update again.',
        );
      }
      if (automatic && !await canAutomaticallyRestart(session)) {
        throw StateError('The counter became busy; update deferred.');
      }
      await installDownloadedUpdate(_downloadedInstaller!, pid);
      status = updaterPlatform() == 'android'
          ? 'Approve the Android install prompt. If permission settings opened, allow this app and tap Install update again.'
          : 'Installer started. AvtarPOS will close and reopen after update.';
      notifyListeners();
    } finally {
      _installing = false;
      session.installingUpdate = false;
      session.changed();
    }
  }

  @override
  void dispose() {
    _automaticTimer?.cancel();
    super.dispose();
  }

  static bool _isVersion(String value) =>
      RegExp(r'^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$').hasMatch(value);
  static bool _isSha256(String value) =>
      RegExp(r'^[a-f0-9]{64}$').hasMatch(value);
  static int _compareVersions(String first, String second) {
    List<int> parts(String input) => input
        .split(RegExp(r'[-+]'))
        .first
        .split('.')
        .map((value) => int.parse(value))
        .toList();
    final a = parts(first), b = parts(second);
    for (var i = 0; i < 3; i++) {
      final result = a[i].compareTo(b[i]);
      if (result != 0) return result;
    }
    return 0;
  }
}
