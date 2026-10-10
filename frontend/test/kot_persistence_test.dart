import 'dart:io';

import 'package:avtar_pos/core/local_store.dart';
import 'package:avtar_pos/core/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('KOT acknowledgement persists before a printer result', () async {
    final directory = await Directory.systemTemp.createTemp('avtar_kot_');
    addTearDown(() => directory.delete(recursive: true));
    final store = await LocalStore.connect(
      databaseFactoryFfi,
      '${directory.path}${Platform.pathSeparator}kot.sqlite',
    );
    addTearDown(store.db.close);

    final order = <String, dynamic>{
      'id': 'order-1',
      'status': 'open',
      'items': <Json>[
        {
          'menu_item_id': 'naan',
          'item_name': 'Butter Naan',
          'quantity': 2,
          '_kot_printed_quantity': 1,
        },
        {
          'menu_item_id': 'shake',
          'item_name': 'Shake',
          'quantity': 1,
          '_kot_printed_quantity': 1,
        },
      ],
      '_kot_sent_quantities': {'naan||Butter Naan|': 1},
    };

    await store.saveKotAcknowledgement(order);
    final saved = await store.readDraft('order-1');

    expect(saved, isNotNull);
    final items = maps(saved!['items']);
    expect(number(items[0]['_kot_printed_quantity']), 1);
    expect(number(items[1]['_kot_printed_quantity']), 1);
    expect(saved['_kot_sent_quantities'], isA<Map>());
  });
}
