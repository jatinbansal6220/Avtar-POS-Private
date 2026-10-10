import 'package:avtar_pos/core/models.dart';
import 'package:avtar_pos/core/session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'pos_usability_test.dart' as fixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test('demo owner can set first code and reset requires current code', () async {
    final session = await fixture.setup();
    addTearDown(() async {
      session.dispose();
      await session.local!.db.close();
    });
    await session.setInvoiceDeleteCode(newCode: '4567');
    await session.verifyInvoiceAccessCode('4567');
    final settings = (await session.local!.list('settings')).single;
    expect(settings['invoice_delete_code_hash'], isNot('4567'));
    expect(settings['is_tax_enabled'], false);
    await expectLater(
      session.setInvoiceDeleteCode(newCode: '7654', currentCode: '1111'),
      throwsA(isA<ApiFailure>()),
    );
    await session.verifyInvoiceAccessCode('4567');
    await session.setInvoiceDeleteCode(newCode: '7654', currentCode: '4567');
    await session.verifyInvoiceAccessCode('7654');
    await expectLater(
      session.verifyInvoiceAccessCode('4567'),
      throwsA(isA<ApiFailure>()),
    );
  });
}
