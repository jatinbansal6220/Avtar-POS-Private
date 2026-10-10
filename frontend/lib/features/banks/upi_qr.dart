import 'dart:convert';
import 'dart:typed_data';

import 'package:qr/qr.dart';
import 'package:image/image.dart' as image;

import '../../core/models.dart';
import 'qr_image.dart';

bool validUpiId(dynamic value) =>
    RegExp(r'^[a-zA-Z0-9._-]+@[a-zA-Z0-9.-]+$')
        .hasMatch('${value ?? ''}'.trim()) &&
    '${value ?? ''}'.trim().length <= 40;

String upiPaymentUri({
  required String upiId,
  required String name,
  int? amountMinor,
  String? reference,
}) {
  if (!validUpiId(upiId)) {
    throw const FormatException('Enter a valid UPI ID, for example shop@bank.');
  }
  if (amountMinor != null && amountMinor <= 0) {
    throw const FormatException('UPI amount must be greater than zero.');
  }
  final params = <String, String>{
    'pa': upiId.trim(),
    'pn': name.trim().isEmpty ? 'Merchant' : name.trim(),
    'cu': 'INR',
    if (amountMinor != null)
      'am':
          '${amountMinor ~/ 100}.${(amountMinor % 100).toString().padLeft(2, '0')}',
    if (reference != null &&
        reference.trim().isNotEmpty &&
        reference != 'PREVIEW')
      'tr': reference,
  };
  return 'upi://pay?${params.entries.map((e) => '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}').join('&')}';
}

String upiQrPng(String uri) {
  final matrix = QrImage(
    QrCode.fromData(data: uri, errorCorrectLevel: QrErrorCorrectLevel.M),
  );
  const quiet = 4, pixels = 6;
  final size = (matrix.moduleCount + quiet * 2) * pixels;
  final canvas = image.Image(size, size);
  image.fill(canvas, image.getColor(255, 255, 255));
  for (var row = 0; row < matrix.moduleCount; row++) {
    for (var col = 0; col < matrix.moduleCount; col++) {
      if (matrix.isDark(row, col)) {
        image.fillRect(
          canvas,
          (col + quiet) * pixels,
          (row + quiet) * pixels,
          (col + quiet + 1) * pixels - 1,
          (row + quiet + 1) * pixels - 1,
          image.getColor(0, 0, 0),
        );
      }
    }
  }
  return base64Encode(image.encodePng(canvas));
}

int upiReceiptAmount(Json receipt) => receipt['payment_method'] == 'mixed'
    ? maps(receipt['payments'])
          .where((p) => p['method'] == 'upi')
          .fold<int>(0, (sum, p) => sum + number(p['amount_minor']))
    : receipt['payment_method'] == 'upi'
    ? number(receipt['total_minor'])
    : 0;

Uint8List? receiptUpiQr(Json receipt) {
  final amount = upiReceiptAmount(receipt);
  if (amount > 0 && validUpiId(receipt['qr_upi_id'])) {
    return qrImageBytes(
      upiQrPng(
        upiPaymentUri(
          upiId: '${receipt['qr_upi_id']}',
          name: '${receipt['qr_bank_account_name'] ?? 'Merchant'}',
          amountMinor: amount,
          reference: '${receipt['bill_number'] ?? ''}',
        ),
      ),
    );
  }
  // Legacy accounts with only uploaded artwork retain their existing QR.
  return qrImageBytes(receipt['qr_image_base64']);
}
