import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'package:esc_pos_utils/esc_pos_utils.dart';
import 'package:image/image.dart' as img;

import '../../core/models.dart';
import 'print_job.dart';

/// Uses raster strips so Hindi/Unicode and the rupee symbol do not depend on
/// the printer's installed character tables. No payment is generated here.
class PrinterService {
  static const _usbPrinter = MethodChannel('avtar_pos/raw_printer');

  String _host(Json settings) {
    final host = '${settings['printer_ip'] ?? ''}'.trim();
    if (host.isEmpty) {
      throw ApiFailure(422, 'Set the WiFi printer IP in restaurant settings.');
    }
    return host;
  }

  int _port(Json settings) {
    final port = number(settings['printer_port']);
    if (port < 1 || port > 65535) {
      throw ApiFailure(422, 'Set a valid WiFi printer port (usually 9100).');
    }
    return port;
  }

  Future<Socket> _connect(Json settings) async {
    final host = _host(settings);
    final port = _port(settings);
    try {
      return await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 5),
      );
    } catch (_) {
      throw ApiFailure(
        503,
        'Cannot reach WiFi printer at $host:$port. Connect the phone and printer to the same WiFi, then verify IP and port.',
      );
    }
  }

  Future<Generator> _generator(Json settings) async => Generator(
    settings['printer_paper_width'] == '58mm' ? PaperSize.mm58 : PaperSize.mm80,
    await CapabilityProfile.load(),
  );

  Future<List<int>> _receiptBytes(
    Json settings,
    Uint8List png,
    PrintJob job,
  ) async {
    final decoded = img.decodePng(png);
    if (decoded == null) {
      throw ApiFailure(422, 'Receipt could not be rendered.');
    }
    final raster = img.copyResize(
      decoded,
      width: settings['printer_paper_width'] == '58mm' ? 384 : 576,
    );
    final generator = await _generator(settings);
    final bytes = <int>[...generator.reset()];
    for (var y = 0; y < raster.height; y += 256) {
      job.check();
      final height = (raster.height - y).clamp(0, 256);
      bytes.addAll(
        generator.imageRaster(img.copyCrop(raster, 0, y, raster.width, height)),
      );
    }
    bytes.addAll(generator.feed(3));
    bytes.addAll(generator.cut());
    return bytes;
  }

  Future<bool> _sendAndroidUsb(List<int> bytes, PrintJob job) async {
    try {
      job.check();
      final sent = await _usbPrinter.invokeMethod<bool>('printUsbRaw', {
        'data': Uint8List.fromList(bytes),
      });
      job.check();
      return sent == true;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (error) {
      // A disconnected USB printer is normal when the user intentionally uses
      // the existing Wi-Fi setup. Other failures should remain visible.
      if (error.code == 'NO_USB_PRINTER') return false;
      throw ApiFailure(
        503,
        'USB printer error: ${error.message ?? error.code}',
      );
    }
  }

  Future<void> receipt(Json settings, Uint8List png, {PrintJob? job}) async {
    job ??= PrintJob();
    job.check();
    final rawBytes = await _receiptBytes(settings, png, job);
    if (Platform.isWindows) {
      await _sendWindowsDefaultPrinter(rawBytes, job);
      return;
    }
    if (Platform.isAndroid && await _sendAndroidUsb(rawBytes, job)) return;
    final decoded = img.decodePng(png);
    if (decoded == null) {
      throw ApiFailure(422, 'Receipt could not be rendered.');
    }
    final raster = img.copyResize(
      decoded,
      width: settings['printer_paper_width'] == '58mm' ? 384 : 576,
    );
    final socket = await _connect(settings);
    final generator = await _generator(settings);
    job.onCancel = () async {
      socket.destroy();
    };
    try {
      socket.add(generator.reset());
      await socket.flush();
      for (var y = 0; y < raster.height; y += 256) {
        job.check();
        final height = (raster.height - y).clamp(0, 256);
        socket.add(
          generator.imageRaster(
            img.copyCrop(raster, 0, y, raster.width, height),
          ),
        );
        // Flush before each next strip. The package's disconnect() destroys
        // queued data, which made Android receipt/KOT delivery unreliable.
        await socket.flush();
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      job.check();
      socket.add(generator.feed(3));
      socket.add(generator.cut());
      await socket.flush();
      await socket.close();
    } finally {
      socket.destroy();
      job.onCancel = null;
    }
  }

  /// RAW mode is deliberate: the RP80US receives ESC/POS commands directly,
  /// while Windows still selects the configured system default printer.
  Future<void> _sendWindowsDefaultPrinter(List<int> bytes, PrintJob job) async {
    final dir = await getTemporaryDirectory();
    final documentName = 'AvtarPOS-${DateTime.now().microsecondsSinceEpoch}';
    final payload = File('${dir.path}\\$documentName.bin');
    final script = File('${dir.path}\\$documentName.ps1');
    await payload.writeAsBytes(bytes, flush: true);
    await script.writeAsString('''
\$ErrorActionPreference='Stop'
Add-Type @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class AvtarRawPrinter {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public class DOCINFO { public string pDocName; public string pOutputFile; public string pDataType; }
  [DllImport("winspool.drv", SetLastError=true, CharSet=CharSet.Unicode)] static extern bool OpenPrinter(string name, out IntPtr handle, IntPtr defaults);
  [DllImport("winspool.drv", SetLastError=true)] static extern bool ClosePrinter(IntPtr handle);
  [DllImport("winspool.drv", SetLastError=true, CharSet=CharSet.Unicode)] static extern int StartDocPrinter(IntPtr handle, int level, [In] DOCINFO info);
  [DllImport("winspool.drv", SetLastError=true)] static extern bool EndDocPrinter(IntPtr handle);
  [DllImport("winspool.drv", SetLastError=true)] static extern bool StartPagePrinter(IntPtr handle);
  [DllImport("winspool.drv", SetLastError=true)] static extern bool EndPagePrinter(IntPtr handle);
  [DllImport("winspool.drv", SetLastError=true)] static extern bool WritePrinter(IntPtr handle, byte[] data, int count, out int written);
  static void Check(bool ok) { if (!ok) throw new Win32Exception(Marshal.GetLastWin32Error()); }
  public static void Send(string printer, string document, byte[] data) {
    IntPtr handle; Check(OpenPrinter(printer, out handle, IntPtr.Zero));
    try {
      var info = new DOCINFO { pDocName=document, pDataType="RAW" };
      if (StartDocPrinter(handle, 1, info) == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
      try {
        Check(StartPagePrinter(handle));
        try { int written; Check(WritePrinter(handle, data, data.Length, out written)); if (written != data.Length) throw new Exception("Incomplete RAW print job."); }
        finally { EndPagePrinter(handle); }
      } finally { EndDocPrinter(handle); }
    } finally { ClosePrinter(handle); }
  }
}
'@
\$printer = Get-CimInstance Win32_Printer | Where-Object { \$_.Default } | Select-Object -First 1 -ExpandProperty Name
if ([string]::IsNullOrWhiteSpace(\$printer)) { throw 'No Windows default printer is available.' }
\$virtualPrinters = @('Microsoft Print to PDF', 'Microsoft XPS Document Writer', 'Fax', 'OneNote (Desktop)', 'OneNote for Windows 10')
if (\$virtualPrinters -contains \$printer) {
  throw "Windows default printer is \$printer. Set RP80US as the Windows default printer before printing bills."
}
[AvtarRawPrinter]::Send(\$printer, '$documentName', [IO.File]::ReadAllBytes(${_quote(payload.path)}))
''');
    final process = await Process.start('powershell', [
      '-NoProfile',
      '-WindowStyle',
      'Hidden',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      script.path,
    ]);
    final output = process.stdout.transform(utf8.decoder).join();
    final errors = process.stderr.transform(utf8.decoder).join();
    job.onCancel = () async => process.kill();
    try {
      late List<Object?> result;
      try {
        result = await Future.wait([process.exitCode, output, errors]).timeout(
          const Duration(seconds: 35),
        );
      } on TimeoutException {
        process.kill();
        throw ApiFailure(
          503,
          'Windows printer did not respond within 35 seconds. The bill is saved; check the default RP80US printer and retry.',
        );
      }
      if ((result[0] as int) != 0) {
        throw ApiFailure(
          503,
          'Windows default printer rejected the RAW ESC/POS job. Check that RP80US is installed and selected as the default printer.',
        );
      }
      job.check();
    } finally {
      job.onCancel = null;
      if (await payload.exists()) await payload.delete();
      if (await script.exists()) await script.delete();
    }
  }

  String _quote(String value) => "'${value.replaceAll("'", "''")}'";

  Future<void> test(Json settings) async {
    final rawTest = <int>[
      0x1b,
      0x40,
      ...ascii.encode('AVTAR POS - PRINTER TEST\\n'),
      ...ascii.encode('RAW ESC/POS connection successful.\\n'),
      ...ascii.encode('This is not a bill.\\n'),
      0x1b,
      0x64,
      0x03,
      0x1d,
      0x56,
      0x00,
    ];
    final job = PrintJob();
    if (Platform.isWindows) {
      await _sendWindowsDefaultPrinter(rawTest, job);
      return;
    }
    if (Platform.isAndroid && await _sendAndroidUsb(rawTest, job)) return;
    final socket = await _connect(settings);
    final generator = await _generator(settings);
    try {
      socket.add(generator.reset());
      socket.add(
        generator.text(
          'AVTAR POS - PRINTER TEST',
          styles: const PosStyles(bold: true),
        ),
      );
      socket.add(generator.text('Connection successful.'));
      socket.add(generator.text('This is not a bill.'));
      socket.add(generator.feed(3));
      socket.add(generator.cut());
      await socket.flush();
      await socket.close();
    } finally {
      socket.destroy();
    }
  }
}
