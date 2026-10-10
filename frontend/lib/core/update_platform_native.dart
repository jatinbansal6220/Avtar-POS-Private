import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

String updaterPlatform() => Platform.isWindows
    ? 'windows'
    : Platform.isAndroid
    ? 'android'
    : 'unsupported';

bool updaterCanInstall() => Platform.isWindows || Platform.isAndroid;

bool isCertificateTrustError(Object error) =>
    error is HandshakeException ||
    error.toString().contains('CERTIFICATE_VERIFY_FAILED');

/// Uses Windows' native certificate store through the Windows-provided curl.
/// TLS verification is never disabled; the installer is also hash-verified.
Future<String> fetchUpdateManifestWithSystemTrust(Uri uri) async {
  if (!Platform.isWindows) {
    throw UnsupportedError('System trust fallback is Windows-only.');
  }
  final result = await Process.run('curl.exe', [
    '--fail',
    '--location',
    '--silent',
    '--show-error',
    '--proto',
    '=https',
    '--tlsv1.2',
    uri.toString(),
  ]).timeout(const Duration(seconds: 20));
  if (result.exitCode != 0) {
    throw StateError(
      'Windows secure update transport failed: ${result.stderr}',
    );
  }
  return '${result.stdout}';
}

/// Download on either native platform; Android still confirms installation.
Future<String> downloadUpdate(
  http.Client client,
  Uri uri,
  String fileName,
  void Function(int percent) onProgress,
) async {
  if (!Platform.isWindows && !Platform.isAndroid) {
    throw UnsupportedError('Unsupported update platform.');
  }
  final temp = await getTemporaryDirectory();
  final root = await Directory('${temp.path}${Platform.pathSeparator}updates')
      .create(recursive: true);
  final destination = File('${root.path}${Platform.pathSeparator}$fileName');
  final partial = File('${destination.path}.part');
  if (await partial.exists()) await partial.delete();
  try {
    final request = http.Request('GET', uri);
    final response = await client
        .send(request)
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw StateError('Update download failed (${response.statusCode}).');
    }
    final total = response.contentLength ?? 0;
    var received = 0;
    final sink = partial.openWrite();
    try {
      await for (final bytes in response.stream.timeout(
        const Duration(seconds: 30),
      )) {
        sink.add(bytes);
        received += bytes.length;
        if (total > 0) onProgress((received * 100 ~/ total).clamp(0, 100));
      }
    } finally {
      await sink.close();
    }
    if (total > 0 && received != total) {
      await partial.delete();
      throw StateError('Update download was incomplete. Please retry.');
    }
  } catch (error) {
    if (!Platform.isWindows || !isCertificateTrustError(error)) rethrow;
    if (await partial.exists()) await partial.delete();
    onProgress(0);
    final result = await Process.run('curl.exe', [
      '--fail',
      '--location',
      '--silent',
      '--show-error',
      '--proto',
      '=https',
      '--tlsv1.2',
      '--output',
      partial.path,
      uri.toString(),
    ]).timeout(const Duration(minutes: 5));
    if (result.exitCode != 0 || !await partial.exists()) {
      throw StateError(
        'Windows secure update download failed: ${result.stderr}',
      );
    }
    onProgress(100);
  }
  if (await destination.exists()) await destination.delete();
  await partial.rename(destination.path);
  return destination.path;
}

Future<void> openUpdateLink(Uri uri) async {
  if (Platform.isAndroid) {
    // Android native code opens the release in the default browser. Installing
    // an APK always remains a system-confirmed action, never a silent update.
    const channel = MethodChannel('avtar_pos/updater');
    await channel.invokeMethod<void>('openUrl', {'url': uri.toString()});
    return;
  }
  await Process.start('cmd', ['/c', 'start', '', uri.toString()]);
}

Future<void> installDownloadedUpdate(
  String installerPath,
  int parentPid,
) async {
  if (Platform.isAndroid) {
    const channel = MethodChannel('avtar_pos/updater');
    await channel.invokeMethod<void>('installApk', {'path': installerPath});
    return;
  }
  if (!Platform.isWindows) {
    throw StateError('Install from the Android download notification.');
  }
  await Process.start(installerPath, [
    '/update',
    '$parentPid',
  ], mode: ProcessStartMode.detached);
}
