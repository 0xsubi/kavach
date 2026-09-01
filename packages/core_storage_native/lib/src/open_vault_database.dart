import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'vault_database.dart';

/// Opens (creating if needed) the on-device vault cache database in the
/// platform's application-support directory.
Future<VaultDatabase> openVaultDatabase({String fileName = 'kavach_vault.sqlite'}) async {
  final executor = LazyDatabase(() async {
    final dir = await getApplicationSupportDirectory();
    final file = File(p.join(dir.path, fileName));
    return NativeDatabase.createInBackground(file);
  });
  return VaultDatabase(executor);
}
