import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

String updaterPlatform() => 'web';
bool updaterCanInstall() => false;
bool isCertificateTrustError(Object error) => false;
Future<String> fetchUpdateManifestWithSystemTrust(Uri uri) =>
    throw UnsupportedError('Browser builds use the browser trust store.');

Future<String> downloadUpdate(
  http.Client client,
  Uri uri,
  String fileName,
  void Function(int percent) onProgress,
) async {
  await openUpdateLink(uri);
  return '';
}

Future<void> openUpdateLink(Uri uri) async {
  web.window.open(uri.toString(), '_blank');
}

Future<void> installDownloadedUpdate(String installerPath, int parentPid) {
  throw UnsupportedError('Browser builds cannot install an app update.');
}
