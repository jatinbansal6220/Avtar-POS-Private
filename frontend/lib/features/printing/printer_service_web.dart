import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../../core/models.dart';
import 'print_job.dart';

/// Browser layout preview only. Dispatch and cancellation belong to the browser
/// print dialog; this never sends raw commands or confirms physical printing.
class PrinterService {
  static web.HTMLIFrameElement? _preview;

  Future<void> receipt(Json settings, Uint8List png, {PrintJob? job}) async {
    job ??= PrintJob();
    job.check();
    _preview?.remove();
    final width = settings['printer_paper_width'] == '58mm' ? 58 : 80;
    final header = ByteData.sublistView(png);
    final height = (header.getUint32(20) * width / header.getUint32(16)).ceil();
    final frame = web.HTMLIFrameElement()
      ..title = 'Avtar POS receipt print preview'
      ..style.position = 'fixed'
      ..style.left = '-10000px'
      ..style.width = '${width * 96 / 25.4}px'
      ..style.height = '1px'
      ..style.border = '0';
    _preview = frame;
    final loaded = Completer<void>();
    frame.addEventListener(
      'load',
      ((web.Event _) {
        if (!loaded.isCompleted) loaded.complete();
      }).toJS,
    );
    frame.srcdoc =
        '''<!DOCTYPE html>
<html><head><meta charset="UTF-8"><title>Avtar POS receipt</title>
<style>
@page { size: ${width}mm ${height}mm; margin: 0; }
html, body { margin: 0; padding: 0; width: ${width}mm; background: white; }
img { display: block; width: ${width}mm; height: auto; }
</style></head><body>
<img alt="Saved Avtar POS receipt" src="data:image/png;base64,${base64Encode(png)}">
</body></html>'''
            .toJS;
    job.onCancel = () async {
      frame.remove();
    };
    web.document.body!.appendChild(frame);
    try {
      await loaded.future.timeout(const Duration(seconds: 15));
      job.check();
      frame.contentWindow!.focus();
      frame.contentWindow!.print();
    } catch (_) {
      frame.remove();
      rethrow;
    }
  }

  Future<void> test(Json settings) async {
    throw ApiFailure(
      422,
      'Printer test is available in the Windows app or Android app, not browser preview.',
    );
  }
}
