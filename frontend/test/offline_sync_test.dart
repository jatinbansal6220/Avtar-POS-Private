import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:avtar_pos/core/local_store.dart';
import 'package:avtar_pos/core/session.dart';
import 'package:avtar_pos/features/orders/data/order_draft.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  test(
    'offline mutation survives restart and reuses its idempotency key',
    () async {
      final dir = await Directory.systemTemp.createTemp('avtar-test-');
      final path = '${dir.path}/cache.sqlite';
      final keys = <String>[];
      var online = false;
      final client = MockClient((request) async {
        if (!online) throw const SocketException('offline');
        if (request.method == 'POST') {
          keys.add(request.headers['Idempotency-Key']!);
          final row = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({...row, 'version': 1, 'status': 'open'}),
            201,
          );
        }
        return http.Response(
          jsonEncode({'changes': [], 'next_cursor': 0, 'has_more': false}),
          200,
        );
      });
      final session = Session(client: client)
        ..base = 'https://test.invalid/api'
        ..user = {'id': 1, 'role': 'owner'};
      session.local = await LocalStore.connect(databaseFactoryFfi, path);
      await session.local!.setMeta('cursor', '0');
      final draft = newOrder();
      await session.enqueueOrder(draft);
      while (session.syncing) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final before = await session.local!.db.query('outbox');
      expect(before.length, 1);
      // A single transient failure retains the last Connected label; a
      // second failure establishes Offline without losing the queued intent.
      expect(session.online, true);
      await session.sync();
      expect(session.online, false);
      await session.local!.db.close();
      session.local = await LocalStore.connect(databaseFactoryFfi, path);
      online = true;
      await session.sync();
      expect(keys, [before.first['key']]);
      expect(await session.local!.db.query('outbox'), isEmpty);
      expect((await session.local!.get('orders', draft['id']))!['version'], 1);
      await session.local!.db.close();
      session.dispose();
      await dir.delete(recursive: true);
    },
  );
  test(
    'conflict stays queued for review and does not erase the draft',
    () async {
      final session =
          Session(
              client: MockClient(
                (request) async => http.Response(
                  jsonEncode(
                    request.method == 'POST'
                        ? {'message': 'Order changed'}
                        : {'changes': [], 'next_cursor': 0, 'has_more': false},
                  ),
                  request.method == 'POST' ? 409 : 200,
                ),
              ),
            )
            ..base = 'https://test.invalid/api'
            ..user = {'id': 1, 'role': 'owner'};
      session.local = await LocalStore.connect(
        databaseFactoryFfi,
        inMemoryDatabasePath,
      );
      await session.local!.setMeta('cursor', '0');
      final draft = newOrder();
      await session.enqueueOrder(draft);
      while (session.syncing) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(
        (await session.local!.db.query('outbox')).first['state'],
        'conflict',
      );
      expect(await session.local!.readDraft(draft['id']), isNotNull);
      await session.local!.db.close();
      session.dispose();
    },
  );
  test('table cancellation reaches the dedicated status endpoint', () async {
    final requests = <String>[];
    final session =
        Session(
            client: MockClient((request) async {
              requests.add('${request.method} ${request.url.path}');
              if (request.url.path.endsWith('/updates')) {
                return http.Response(
                  jsonEncode({
                    'changes': [],
                    'next_cursor': 0,
                    'has_more': false,
                  }),
                  200,
                );
              }
              final body = jsonDecode(request.body) as Map<String, dynamic>;
              if (request.url.path.endsWith('/status')) {
                return http.Response(
                  jsonEncode({
                    'id': request.url.pathSegments[2],
                    'version': 2,
                    'status': 'cancelled',
                  }),
                  200,
                );
              }
              return http.Response(
                jsonEncode({...body, 'version': 1, 'status': 'open'}),
                201,
              );
            }),
          )
          ..base = 'https://test.invalid/api'
          ..user = {'id': 1, 'role': 'owner'};
    session.local = await LocalStore.connect(
      databaseFactoryFfi,
      inMemoryDatabasePath,
    );
    await session.local!.setMeta('cursor', '0');
    await LocalStore.put(session.local!.db, 'tables', {
      'id': 'sync-table',
      'table_number': 'SYNC',
      'status': 'empty',
    });
    final order = newOrder(table: {'id': 'sync-table', 'table_number': 'SYNC'})
      ..['items'] = [
        {
          'menu_item_id': 'item-1',
          'item_name': 'Sync item',
          'quantity': 1,
          'price_minor': 10000,
        },
      ];
    await session.enqueueOrder(order);
    for (var i = 0; i < 50; i++) {
      if (!session.syncing &&
          (await session.local!.db.query('outbox')).isEmpty) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await session.changeOrderStatus(order, action: 'cancel');
    for (var i = 0; i < 50; i++) {
      if (!session.syncing &&
          (await session.local!.db.query('outbox')).isEmpty) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(requests, contains('POST /api/orders/${order['id']}/status'));
    expect(
      (await session.local!.get('tables', 'sync-table'))!['status'],
      'empty',
    );
    expect(
      (await session.local!.get('orders', order['id']))!['status'],
      'cancelled',
    );
    await session.local!.db.close();
    session.dispose();
  });
}
