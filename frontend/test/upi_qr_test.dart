import 'dart:io';

import 'package:avtar_pos/features/banks/upi_qr.dart';
import 'package:avtar_pos/features/banks/qr_image.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;

void main() {
  test('UPI URI preserves destination and exact paise with encoded names', () {
    final uri = Uri.parse(
      upiPaymentUri(
        upiId: ' shop.one@bank ',
        name: 'Shop & Counter',
        amountMinor: 12345,
        reference: 'AV-001',
      ),
    );
    expect(uri.scheme, 'upi');
    expect(uri.host, 'pay');
    expect(uri.queryParameters, {
      'pa': 'shop.one@bank',
      'pn': 'Shop & Counter',
      'cu': 'INR',
      'am': '123.45',
      'tr': 'AV-001',
    });
    expect(
      Uri.parse(upiPaymentUri(upiId: 'shop@bank', name: 'Shop', amountMinor: 1))
          .queryParameters['am'],
      '0.01',
    );
  });
  test('invalid or injectable UPI IDs and zero amounts are rejected', () {
    for (final id in [
      'shop',
      'shop@',
      '@bank',
      'shop@bank&pa=other@bank',
      'shop @bank',
      'upi://pay',
    ]) {
      expect(validUpiId(id), false);
      expect(
        () => upiPaymentUri(upiId: id, name: 'Shop'),
        throwsFormatException,
      );
    }
    expect(
      () => upiPaymentUri(upiId: 'shop@bank', name: 'Shop', amountMinor: 0),
      throwsFormatException,
    );
  });
  test(
    'account QR needs no amount; receipt QR uses final total or UPI share',
    () {
      final account = Uri.parse(
        upiPaymentUri(upiId: 'shop@bank', name: 'Shop'),
      );
      expect(account.queryParameters.containsKey('am'), false);
      final receipt = <String, dynamic>{
        'qr_upi_id': 'shop@bank',
        'qr_bank_account_name': 'Shop',
        'payment_method': 'upi',
        'total_minor': 12345,
        'bill_number': 'AV-001',
      };
      expect(upiReceiptAmount(receipt), 12345);
      final png = receiptUpiQr(receipt)!;
      final bitmap = image.decodePng(png)!;
      expect(image.getRed(bitmap.getPixel(0, 0)), 255);
      expect(
        png,
        qrImageBytes(
          upiQrPng(
            upiPaymentUri(
              upiId: 'shop@bank',
              name: 'Shop',
              amountMinor: 12345,
              reference: 'AV-001',
            ),
          ),
        ),
      );
      final other = {...receipt, 'qr_upi_id': 'second@bank'};
      expect(receiptUpiQr(other), isNot(png));
      final mixed = {
        ...receipt,
        'payment_method': 'mixed',
        'payments': [
          {'method': 'cash', 'amount_minor': 2345},
          {'method': 'upi', 'amount_minor': 10000},
        ],
      };
      expect(upiReceiptAmount(mixed), 10000);
      expect(receiptUpiQr(mixed), isNot(png));
      final output = Platform.environment['UPI_QR_VERIFY_PNG'];
      if (output != null) File(output).writeAsBytesSync(png);
    },
  );
  test('legacy uploaded-only accounts retain original QR image', () {
    final png = upiQrPng(upiPaymentUri(upiId: 'old@bank', name: 'Old'));
    expect(
      receiptUpiQr({
        'payment_method': 'upi',
        'total_minor': 100,
        'qr_image_base64': png,
      }),
      qrImageBytes(png),
    );
    expect(
      receiptUpiQr({'payment_method': 'cash', 'total_minor': 100}),
      isNull,
    );
  });
}
