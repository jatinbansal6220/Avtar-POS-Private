import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/models.dart';

/// A4 payment-ledger document. This is deliberately separate from the 80 mm
/// ESC/POS receipt painter: a day report belongs on a normal A4 printer/PDF.
class DayReportPdf {
  static String amount(dynamic value) =>
      'Rs. ${(number(value) / 100).toStringAsFixed(2)}';

  static String dateTime(dynamic raw) {
    final value = indiaDateTime(raw);
    if (value == null) return '${raw ?? ''}';
    final hour = value.hour % 12 == 0 ? 12 : value.hour % 12;
    return '${value.day.toString().padLeft(2, '0')}-${value.month.toString().padLeft(2, '0')}-${value.year} '
        '$hour:${value.minute.toString().padLeft(2, '0')} ${value.hour >= 12 ? 'PM' : 'AM'}';
  }

  static String paymentLabel(Json row) {
    final payments = maps(row['payments']);
    if (payments.length > 1) {
      return payments
          .map((payment) => '${payment['method']}'.toUpperCase())
          .join(' + ');
    }
    return '${row['payment_method'] ?? 'cash'}'
        .replaceAll('_', ' ')
        .toUpperCase();
  }

  static Future<Uint8List> build(Json report) async {
    final summary = report['summary'] is Map
        ? Map<String, dynamic>.from(report['summary'] as Map)
        : <String, dynamic>{};
    final ledger = maps(report['export_ledger']);
    final payments = maps(report['payments']);
    final scope = '${report['payment_scope'] ?? 'all'}';
    final title = switch (scope) {
      'cash' => 'Cash collection report',
      'upi' => 'UPI collection report',
      'card' => 'Card collection report',
      'online' => 'Online payment report',
      'split' => 'Split-payment report',
      _ => 'All invoice collection report',
    };
    final document = pw.Document(
      title: title,
      author: 'AvtarPOS / ZELOVIX',
      creator: 'AvtarPOS',
    );
    final bold = pw.TextStyle(fontWeight: pw.FontWeight.bold);
    document.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(24),
        header: (context) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(
              'AVTAR COOKS - VAISHNU DHABA',
              style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 3),
            pw.Text(
              title,
              style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold),
            ),
            pw.Text(
              'Period: ${report['from']} to ${report['to']}  |  Generated: ${dateTime(indiaTimestamp())} IST',
              style: const pw.TextStyle(fontSize: 9),
            ),
            pw.SizedBox(height: 8),
            pw.Divider(),
          ],
        ),
        footer: (context) => pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text('Powered by ZELOVIX', style: pw.TextStyle(fontSize: 8)),
            pw.Text(
              'Page ${context.pageNumber} of ${context.pagesCount}',
              style: const pw.TextStyle(fontSize: 8),
            ),
          ],
        ),
        build: (context) => [
          pw.Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              _metric('Invoices', '${number(summary['bills'])}'),
              _metric('Invoice value', amount(summary['revenue_minor'])),
              _metric(
                'Collected in this report',
                amount(summary['payment_total_minor']),
              ),
              _metric('Discounts', amount(summary['discount_minor'])),
              _metric('GST', amount(summary['tax_minor'])),
            ],
          ),
          pw.SizedBox(height: 12),
          pw.Text('Payment breakup', style: bold),
          pw.SizedBox(height: 4),
          pw.Table.fromTextArray(
            headers: const ['Payment method', 'Invoices', 'Amount'],
            headerStyle: bold,
            headerDecoration: const pw.BoxDecoration(color: PdfColors.grey300),
            cellStyle: const pw.TextStyle(fontSize: 8),
            cellAlignment: pw.Alignment.centerLeft,
            data: payments
                .map(
                  (row) => [
                    '${row['method']}',
                    '${number(row['orders'])}',
                    amount(row['amount_minor']),
                  ],
                )
                .toList(),
          ),
          pw.SizedBox(height: 14),
          pw.Text('Invoice details', style: bold),
          pw.SizedBox(height: 5),
          pw.Table.fromTextArray(
            headers: const [
              'Bill no.',
              'Date & time',
              'Source / table',
              'Customer',
              'Payment / account',
              'Bill total',
              'Collected',
              'Settlement remark',
            ],
            headerStyle: pw.TextStyle(
              fontSize: 8,
              fontWeight: pw.FontWeight.bold,
            ),
            headerDecoration: const pw.BoxDecoration(color: PdfColors.grey800),
            headerHeight: 20,
            headerAlignments: const {
              5: pw.Alignment.centerRight,
              6: pw.Alignment.centerRight,
            },
            headerCellDecoration: const pw.BoxDecoration(
              color: PdfColors.grey800,
            ),
            cellStyle: const pw.TextStyle(fontSize: 7),
            cellAlignments: const {
              5: pw.Alignment.centerRight,
              6: pw.Alignment.centerRight,
            },
            columnWidths: const {
              0: pw.FlexColumnWidth(1.0),
              1: pw.FlexColumnWidth(1.35),
              2: pw.FlexColumnWidth(1.2),
              3: pw.FlexColumnWidth(1.2),
              4: pw.FlexColumnWidth(1.6),
              5: pw.FlexColumnWidth(1.0),
              6: pw.FlexColumnWidth(1.0),
              7: pw.FlexColumnWidth(1.65),
            },
            data: ledger
                .map(
                  (row) => [
                    '${row['bill_number'] ?? 'Invoice'}',
                    dateTime(row['generated_at']),
                    '${row['table_number'] ?? row['order_type'] ?? 'Order'}',
                    '${row['customer_name'] ?? ''}',
                    [
                      paymentLabel(row),
                      if ('${row['bank_account_name'] ?? ''}'.trim().isNotEmpty)
                        '${row['bank_account_name']}',
                    ].join('\n'),
                    amount(row['total_minor']),
                    amount(row['report_amount_minor']),
                    '${row['settlement_remark'] ?? ''}',
                  ],
                )
                .toList(),
          ),
          pw.SizedBox(height: 10),
          pw.Align(
            alignment: pw.Alignment.centerRight,
            child: pw.Text(
              'Report collection total: ${amount(summary['payment_total_minor'])}',
              style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold),
            ),
          ),
        ],
      ),
    );
    return document.save();
  }

  static pw.Widget _metric(String label, String value) => pw.Container(
    width: 132,
    padding: const pw.EdgeInsets.all(8),
    decoration: pw.BoxDecoration(
      border: pw.Border.all(color: PdfColors.grey500),
      borderRadius: const pw.BorderRadius.all(pw.Radius.circular(3)),
    ),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(label, style: const pw.TextStyle(fontSize: 7)),
        pw.SizedBox(height: 3),
        pw.Text(
          value,
          style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold),
        ),
      ],
    ),
  );
}
