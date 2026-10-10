import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

import 'storage_native.dart'
    if (dart.library.js_interop) 'storage_web.dart'
    as storage;

import 'models.dart';
import 'local_migrations.dart';

class LocalStore {
  final Database db;
  LocalStore(this.db);
  static Future<LocalStore> open(String account) async {
    final name = sha256.convert(utf8.encode(account)).toString();
    final location = await storage.databaseLocation('$name.sqlite');
    return connect(location.$1, location.$2);
  }

  static Future<LocalStore> connect(
    DatabaseFactory factory,
    String path,
  ) async {
    final db = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 3,
        onConfigure: (db) async {
          // Android's SQLite driver returns a result row for these PRAGMAs.
          // `execute` rejects result-producing statements, which made the
          // local database close repeatedly on physical devices.
          await db.rawQuery('PRAGMA journal_mode=WAL');
          await db.rawQuery('PRAGMA busy_timeout=5000');
          // Keep the companion -wal file deliberately small.  On Windows
          // this database lives in the signed-in user's AppData profile,
          // which can have a quota even when the C: drive itself has free
          // space.  This changes only SQLite's journal housekeeping; it
          // never clears records, drafts, or pending sync work.
          await db.rawQuery('PRAGMA wal_autocheckpoint=200');
          await db.rawQuery('PRAGMA journal_size_limit=8388608');
        },
        onCreate: (db, _) async {
          await db.execute(
            'CREATE TABLE records(resource TEXT NOT NULL,id TEXT NOT NULL,name TEXT NOT NULL,status TEXT,body TEXT NOT NULL,PRIMARY KEY(resource,id))',
          );
          await db.execute(
            'CREATE INDEX records_lookup ON records(resource,status,name,id)',
          );
          await db.execute(
            'CREATE TABLE meta(key TEXT PRIMARY KEY,value TEXT NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE drafts(id TEXT PRIMARY KEY,body TEXT NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE outbox(seq INTEGER PRIMARY KEY AUTOINCREMENT,key TEXT UNIQUE NOT NULL,entity TEXT NOT NULL,resource TEXT NOT NULL,method TEXT NOT NULL,path TEXT NOT NULL,payload TEXT NOT NULL,state TEXT NOT NULL DEFAULT \'pending\',error TEXT)',
          );
          await db.execute(
            'CREATE TABLE restaurant_tables(id TEXT PRIMARY KEY, table_number TEXT NOT NULL, status TEXT, current_order_id TEXT, body TEXT NOT NULL)',
          );
          await migrateLocalV3(db);
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) {
            await db.execute(
              'CREATE TABLE IF NOT EXISTS restaurant_tables(id TEXT PRIMARY KEY, table_number TEXT NOT NULL, status TEXT, current_order_id TEXT, body TEXT NOT NULL)',
            );
            await db.execute(
              "INSERT OR REPLACE INTO restaurant_tables(id, table_number, status, current_order_id, body) SELECT id, json_extract(body, '\$.table_number'), status, json_extract(body, '\$.current_order_id'), body FROM records WHERE resource='tables'",
            );
          }
          if (oldVersion < 3) await migrateLocalV3(db);
        },
      ),
    );
    return LocalStore(db);
  }

  static Future<void> put(
    DatabaseExecutor db,
    String resource,
    Json row,
  ) async {
    row = clone(row);
    // These optional profile notes are not fields in the existing Laravel
    // staff schema. A server refresh must not erase the locally saved notes.
    if (resource == 'staff' && row['id'] != null) {
      final previous = await db.query(
        'records',
        columns: ['body'],
        where: 'resource=? AND id=?',
        whereArgs: ['staff', row['id']],
        limit: 1,
      );
      if (previous.isNotEmpty) {
        final saved = jsonDecode(previous.single['body'] as String) as Json;
        for (final field in ['qualification', 'degree', 'experience']) {
          if (!row.containsKey(field) && saved.containsKey(field)) {
            row[field] = saved[field];
          }
        }
      }
    }
    if (resource == 'tables') row['status'] ??= 'empty';
    final name =
        '${row['name'] ?? row['title'] ?? row['table_number'] ?? row['bill_number'] ?? row['account_name'] ?? row['item_name'] ?? ''}';
    await db.insert('records', {
      'resource': resource,
      'id': row['id'],
      'name': name,
      'status': row['status'],
      'body': jsonEncode(row),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    if (resource == 'tables') {
      await db.insert('restaurant_tables', {
        'id': row['id'],
        'table_number': '${row['table_number'] ?? ''}',
        'status': row['status'],
        'current_order_id': row['current_order_id'],
        'body': jsonEncode(row),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  Future<List<Json>> list(
    String resource, {
    String query = '',
    String? status,
    int offset = 0,
    int limit = 100,
    Json filters = const {},
  }) async {
    final conditions = <String>['resource=?'];
    final arguments = <Object?>[resource];
    if (resource == 'bills') {
      if (query.trim().isNotEmpty) {
        final fields = [
          'bill_number',
          'customer_name',
          'customer_phone',
          'table_number',
          'generated_at',
        ];
        final expressions = [
          'name LIKE ?',
          for (final field in fields)
            "COALESCE(json_extract(body, '\$.$field'), json_extract(body, '\$.receipt.$field'), '') LIKE ?",
          "EXISTS (SELECT 1 FROM json_each(COALESCE(json_extract(body, '\$.merged_table_numbers'), json_extract(body, '\$.receipt.merged_table_numbers'), '[]')) WHERE CAST(value AS TEXT) LIKE ?)",
        ];
        conditions.add('(${expressions.join(' OR ')})');
        arguments.addAll(List.filled(expressions.length, '%${query.trim()}%'));
      }
    } else {
      conditions.add('name LIKE ?');
      arguments.add('%$query%');
    }
    if (status != null) {
      conditions.add('status=?');
      arguments.add(status);
    }
    for (final field in [
      'staff_id',
      'table_number',
      'purchase_item_id',
      'inventory_item_id',
    ]) {
      if ('${filters[field] ?? ''}'.isNotEmpty) {
        if (resource == 'bills' && field == 'table_number') {
          // A joined receipt is visible from every original table card.  The
          // primary table is stored in table_number; the rest are retained in
          // merged_table_numbers, so never hide its bill from Table T02/T03.
          conditions.add('''(
            COALESCE(json_extract(body, '\$.table_number'), json_extract(body, '\$.receipt.table_number'))=?
            OR EXISTS (
              SELECT 1 FROM json_each(COALESCE(
                json_extract(body, '\$.merged_table_numbers'),
                json_extract(body, '\$.receipt.merged_table_numbers'),
                '[]'
              )) WHERE CAST(value AS TEXT)=?
            )
          )''');
          arguments.addAll([filters[field], filters[field]]);
        } else {
          conditions.add("json_extract(body, '\$.$field')=?");
          arguments.add(filters[field]);
        }
      }
    }
    if (resource == 'bills') {
      switch ('${filters['invoice_scope'] ?? ''}') {
        case 'online':
        case 'takeaway':
        case 'pos':
          conditions.add(
            "COALESCE(json_extract(body, '\$.order_type'), json_extract(body, '\$.receipt.order_type'))=?",
          );
          arguments.add(filters['invoice_scope']);
        case 'settlement':
          // A settlement card intentionally contains only invoices that have
          // a recorded settlement correction/remark.  The normal history
          // still shows these invoices too.
          conditions.add('''(
            COALESCE(json_extract(body, '\$.settlement_remark'), json_extract(body, '\$.receipt.settlement_remark'), '')<>''
            OR json_array_length(COALESCE(
              json_extract(body, '\$.settlement_edits'),
              json_extract(body, '\$.receipt.settlement_edits'),
              '[]'
            ))>0
          )''');
      }
    }
    if (resource == 'purchases' && filters['item_name'] != null) {
      conditions.add('name=?');
      arguments.add(filters['item_name']);
    }
    final purchaseItemIds = filters['purchase_item_ids'];
    if (resource == 'purchases' &&
        purchaseItemIds is List &&
        purchaseItemIds.isNotEmpty) {
      final marks = List.filled(purchaseItemIds.length, '?').join(',');
      conditions.add("json_extract(body, '\$.purchase_item_id') IN ($marks)");
      arguments.addAll(purchaseItemIds);
    }
    // Purchases use their own date field for history filtering. Bills can be
    // locally-created receipts or server receipts, so prefer their top-level
    // timestamp and fall back to the timestamp inside the saved receipt.
    final dateField = switch (resource) {
      'bills' => 'generated_at',
      'purchases' => 'purchase_date',
      'expenses' => 'expense_date',
      'inventory_entries' => 'recorded_at',
      _ => 'date',
    };
    final dateExpression = resource == 'bills'
        ? "COALESCE(json_extract(body, '\$.generated_at'), json_extract(body, '\$.receipt.generated_at'), json_extract(body, '\$.date'))"
        : "COALESCE(json_extract(body, '\$.$dateField'), json_extract(body, '\$.date'))";
    for (final bound in ['from', 'to']) {
      if ('${filters[bound] ?? ''}'.isNotEmpty) {
        conditions.add(
          "substr($dateExpression,1,10) ${bound == 'from' ? '>=' : '<='} ?",
        );
        arguments.add(filters[bound]);
      }
    }
    for (final bound in ['min_amount', 'max_amount']) {
      if (filters[bound] != null) {
        conditions.add(
          "CAST(json_extract(body, '\$.total_minor') AS INTEGER) ${bound == 'min_amount' ? '>=' : '<='} ?",
        );
        arguments.add(filters[bound]);
      }
    }
    final rows = await db.query(
      'records',
      where: conditions.join(' AND '),
      whereArgs: arguments,
      orderBy: resource == 'bills'
          ? "$dateExpression DESC,id"
          : resource == 'purchases'
          ? "json_extract(body, '\$.purchase_date') DESC,id DESC"
          : 'name,id',
      limit: limit,
      offset: offset,
    );
    return rows.map((r) => jsonDecode(r['body'] as String) as Json).toList();
  }

  /// Reads every locally synced row in safe pages. The page size is technical
  /// only; callers never impose a restaurant-data cap such as "first 1000".
  Future<List<Json>> listAll(String resource, {Json filters = const {}}) async {
    const pageSize = 200;
    final values = <Json>[];
    while (true) {
      final page = await list(
        resource,
        offset: values.length,
        limit: pageSize,
        filters: filters,
      );
      values.addAll(page);
      if (page.length < pageSize) return values;
    }
  }

  Future<Json?> get(String resource, String id) async {
    final rows = await db.query(
      'records',
      where: 'resource=? AND id=?',
      whereArgs: [resource, id],
      limit: 1,
    );
    return rows.isEmpty
        ? null
        : jsonDecode(rows.first['body'] as String) as Json;
  }

  /// Bound, chunked lookups avoid one database round trip per floor card.
  Future<Map<String, Json>> getMany(
    String resource,
    Iterable<String> ids,
  ) async {
    final keys = ids.where((id) => id.isNotEmpty).toSet().toList();
    final result = <String, Json>{};
    for (var offset = 0; offset < keys.length; offset += 400) {
      final chunk = keys.skip(offset).take(400).toList();
      final rows = await db.query(
        'records',
        columns: ['id', 'body'],
        where:
            'resource=? AND id IN (${List.filled(chunk.length, '?').join(',')})',
        whereArgs: [resource, ...chunk],
      );
      for (final row in rows) {
        result[row['id'] as String] = jsonDecode(row['body'] as String) as Json;
      }
    }
    return result;
  }

  Future<Map<String, String>> metaMany(Iterable<String> keys) async {
    final unique = keys.toSet().toList();
    final result = <String, String>{};
    for (var offset = 0; offset < unique.length; offset += 400) {
      final chunk = unique.skip(offset).take(400).toList();
      final rows = await db.query(
        'meta',
        where: 'key IN (${List.filled(chunk.length, '?').join(',')})',
        whereArgs: chunk,
      );
      for (final row in rows) {
        result[row['key'] as String] = row['value'] as String;
      }
    }
    return result;
  }

  Future<List<Json>> purchaseItems() async {
    final rows = await db.rawQuery(
      "SELECT name AS item_name, COUNT(*) AS entry_count FROM records WHERE resource='purchases' AND name<>'' GROUP BY name ORDER BY name LIMIT 100",
    );
    return rows.map((row) => Map<String, dynamic>.from(row)).toList();
  }

  Future<List<Json>> purchaseHistory(String itemName) async {
    final rows = await db.rawQuery(
      "SELECT body FROM records WHERE resource='purchases' AND name=? ORDER BY json_extract(body, char(36) || '.purchase_date') DESC, id DESC LIMIT 100",
      [itemName],
    );
    return rows
        .map((row) => jsonDecode(row['body'] as String) as Json)
        .toList();
  }

  Future<List<Json>> bookingsForTables(List<String> tableIds) async {
    if (tableIds.isEmpty) return [];
    final rows = await db.query(
      'records',
      where: 'resource=?',
      whereArgs: ['table_bookings'],
      limit: 500,
    );
    final now = indiaNow();
    return rows.map((row) => jsonDecode(row['body'] as String) as Json).where((
      booking,
    ) {
      final end = DateTime.tryParse(booking['end_at']?.toString() ?? '');
      return tableIds.contains(booking['table_id']?.toString()) &&
          end != null &&
          end.isAfter(now);
    }).toList();
  }

  Future<Json?> bookingConflict(
    String tableId,
    DateTime start,
    DateTime end, {
    String? exceptId,
  }) async {
    final rows = await db.query(
      'records',
      where: 'resource=?',
      whereArgs: ['table_bookings'],
      limit: 500,
    );
    for (final record in rows) {
      final booking = jsonDecode(record['body'] as String) as Json;
      final bookedStart = DateTime.tryParse(
        booking['start_at']?.toString() ?? '',
      );
      final bookedEnd = DateTime.tryParse(booking['end_at']?.toString() ?? '');
      if (booking['id'] != exceptId &&
          booking['table_id']?.toString() == tableId &&
          bookedStart != null &&
          bookedEnd != null &&
          bookedStart.isBefore(end) &&
          bookedEnd.isAfter(start))
        return booking;
    }
    return null;
  }

  Future<Map<String, int>> paymentTotalsByStaff() async {
    final rows = await db.rawQuery(
      "SELECT json_extract(body, '\$.staff_id') AS staff_id, SUM(CAST(json_extract(body, '\$.amount_minor') AS INTEGER)) AS paid FROM records WHERE resource='payments' GROUP BY json_extract(body, '\$.staff_id')",
    );
    return {
      for (final row in rows)
        if (row['staff_id'] != null)
          row['staff_id'].toString(): number(row['paid']),
    };
  }

  Future<String?> meta(String key) async {
    final rows = await db.query('meta', where: 'key=?', whereArgs: [key]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  Future<void> setMeta(String key, String value) => db
      .insert('meta', {
        'key': key,
        'value': value,
      }, conflictAlgorithm: ConflictAlgorithm.replace)
      .then((_) {});

  /// Kitchen-ticket acknowledgements belong only to this terminal. Keep the
  /// acknowledgement beside the local open-order draft as well as metadata,
  /// so reopening a cart or receiving a normal server sync can never make an
  /// already printed KOT line appear as new again. This is deliberately not
  /// queued to the server and has no effect on invoices or final bills.
  Future<void> saveKotAcknowledgement(
    Json order, {
    Map<String, String?> metadata = const {},
  }) async {
    final snapshot = clone(order);
    await db.transaction((txn) async {
      for (final entry in metadata.entries) {
        if (entry.value == null) {
          await txn.delete('meta', where: 'key=?', whereArgs: [entry.key]);
        } else {
          await txn.insert('meta', {
            'key': entry.key,
            'value': entry.value,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
      await LocalStore.put(txn, 'orders', snapshot);
      await txn.insert('drafts', {
        'id': snapshot['id'],
        'body': jsonEncode(snapshot),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  Future<void> draft(Json order) => db
      .insert('drafts', {
        'id': order['id'],
        'body': jsonEncode(order),
      }, conflictAlgorithm: ConflictAlgorithm.replace)
      .then((_) {});
  Future<Json?> readDraft(String id) async {
    final rows = await db.query('drafts', where: 'id=?', whereArgs: [id]);
    return rows.isEmpty
        ? null
        : jsonDecode(rows.first['body'] as String) as Json;
  }

  Future<List<Json>> drafts() async =>
      (await db.query('drafts'))
          .map((r) => jsonDecode(r['body'] as String) as Json)
          .toList();
}
