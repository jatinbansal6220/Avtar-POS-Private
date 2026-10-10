import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Browsers cannot send raw jobs to a printer. They open/download the A4 PDF,
/// from where the browser's normal print dialog selects the default printer.
class DayReportExporter {
  Future<String> export(
    Uint8List bytes,
    String name, {
    required bool printToDefault,
  }) async {
    final blob = web.Blob(
      [bytes.toJS].toJS,
      web.BlobPropertyBag(type: 'application/pdf'),
    );
    final url = web.URL.createObjectURL(blob);
    if (printToDefault) {
      web.window.open(url, '_blank');
      return 'A4 PDF opened in the browser. Use the print dialog to print it.';
    }
    final link = web.HTMLAnchorElement()
      ..href = url
      ..download = '$name.pdf'
      ..style.display = 'none';
    web.document.body?.appendChild(link);
    link.click();
    link.remove();
    return 'A4 PDF download started.';
  }
}
