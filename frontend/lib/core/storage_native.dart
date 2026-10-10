import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;

/// Preserve the existing desktop/mobile database location and factory.
Future<(DatabaseFactory, String)> databaseLocation(String name) async {
  if (Platform.isWindows || Platform.isLinux) {
    ffi.sqfliteFfiInit();
    databaseFactory = ffi.databaseFactoryFfi;
  }
  final root = await getApplicationSupportDirectory();
  return (databaseFactory, p.join(root.path, name));
}
