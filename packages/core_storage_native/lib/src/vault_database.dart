import 'package:drift/drift.dart';

part 'vault_database.g.dart';

/// The local, decrypted-vault cache (plan §9: "Local cache: `drift`
/// (native)"). This is non-secret at rest by design — see
/// `kavach_core`'s `LocalVaultCache` doc comment — the vault key itself
/// never lives here, only in `SecureKeyStore`.
class Items extends Table {
  TextColumn get id => text()();
  IntColumn get version => integer()();
  DateTimeColumn get updatedAt => dateTime()();
  TextColumn get updatedByDevice => text()();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();

  /// True for a locally-edited item not yet pushed by [SyncEngine].
  BoolColumn get dirty => boolean().withDefault(const Constant(false))();

  /// The full `VaultItem` as JSON (see `kavach_core`'s `VaultItem.toJson`).
  TextColumn get dataJson => text()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Small key/value table for sync bookkeeping: `last_synced_revision` (the
/// kavach-storage revision counter [SyncEngine] passes as `since_revision`
/// on its next pull) and `item_versions` (a JSON map of item id -> that
/// item's last-known server row version, the optimistic-concurrency
/// baseline for the next write).
class KeyValues extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

@DriftDatabase(tables: [Items, KeyValues])
class VaultDatabase extends _$VaultDatabase {
  VaultDatabase(super.executor);

  @override
  int get schemaVersion => 1;
}
