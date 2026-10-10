import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// Saves the A4 document outside the receipt-printer pipeline. On Windows,
/// Verb=Print is handed to the user's default PDF application/default printer.
class DayReportExporter {
  Future<String> export(
    Uint8List bytes,
    String name, {
    required bool printToDefault,
  }) async {
    final root = await getApplicationDocumentsDirectory();
    final directory = Directory(
      '${root.path}${Platform.pathSeparator}AvtarPOS Reports',
    );
    if (!await directory.exists()) await directory.create(recursive: true);
    final file = File('${directory.path}${Platform.pathSeparator}$name.pdf');
    await file.writeAsBytes(bytes, flush: true);
    if (!Platform.isWindows) return 'A4 PDF saved: ${file.path}';
    final quoted = file.path.replaceAll("'", "''");
    final command = printToDefault
        ? "Start-Process -FilePath '$quoted' -Verb Print"
        : "Start-Process -FilePath '$quoted'";
    final process = await Process.run('powershell', [
      '-NoProfile',
      '-WindowStyle',
      'Hidden',
      '-Command',
      "\$ErrorActionPreference='Stop'; $command",
    ]);
    if (process.exitCode != 0) {
      throw StateError('Could not open the A4 PDF. ${process.stderr}');
    }
    return printToDefault
        ? 'A4 report sent to the Windows default printer.'
        : 'A4 PDF opened: ${file.path}';
  }
}
