import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

/// SQLite persists in this browser origin's IndexedDB, independently of native
/// restaurant databases. Keep a fixed localhost port when testing persistence.
Future<(DatabaseFactory, String)> databaseLocation(String name) async =>
    (databaseFactoryFfiWeb, name);
