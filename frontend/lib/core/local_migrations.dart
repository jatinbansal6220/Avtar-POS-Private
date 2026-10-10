import 'package:sqflite/sqflite.dart';

/// Incremental, transactional cache migrations. Never discard restaurant data.
Future<void> migrateLocalV3(DatabaseExecutor db) async {
  await db.execute("CREATE INDEX IF NOT EXISTS records_date ON records(resource, json_extract(body, '\$.generated_at'))");
  await db.execute("CREATE INDEX IF NOT EXISTS records_staff ON records(resource, json_extract(body, '\$.staff_id'), json_extract(body, '\$.date'))");
  await db.execute('CREATE INDEX IF NOT EXISTS outbox_entity ON outbox(entity,seq)');
  await db.execute("UPDATE records SET status='empty', body=json_set(body, '\$.status', 'empty') WHERE resource='tables' AND status IS NULL");
  await db.execute("UPDATE restaurant_tables SET status='empty', body=json_set(body, '\$.status', 'empty') WHERE status IS NULL");
}
