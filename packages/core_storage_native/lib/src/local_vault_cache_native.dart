import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:kavach_core/kavach_core.dart';

import 'vault_database.dart';

const String _lastSyncedRevisionKey = 'last_synced_revision';
const String _itemVersionsKey = 'item_versions';

/// [LocalVaultCache] backed by a drift (SQLite) database (plan §9).
class LocalVaultCacheNative implements LocalVaultCache {
  LocalVaultCacheNative(this._db);

  final VaultDatabase _db;

  @override
  Future<int> get lastSyncedRevision async {
    final raw = await _readKeyValue(_lastSyncedRevisionKey);
    return raw == null ? 0 : int.parse(raw);
  }

  @override
  Future<void> setLastSyncedRevision(int revision) => _writeKeyValue(_lastSyncedRevisionKey, '$revision');

  @override
  Future<List<VaultItem>> allItems() async {
    final rows = await _db.select(_db.items).get();
    return rows.map(_toVaultItem).toList();
  }

  @override
  Future<VaultItem?> getItem(String id) async {
    final row = await (_db.select(_db.items)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    return row == null ? null : _toVaultItem(row);
  }

  @override
  Future<void> putItem(VaultItem item, {required bool dirty}) {
    return _db.into(_db.items).insertOnConflictUpdate(
          ItemsCompanion.insert(
            id: item.id,
            version: item.version,
            updatedAt: item.updatedAt,
            updatedByDevice: item.updatedByDevice,
            deleted: Value(item.deleted),
            dirty: Value(dirty),
            dataJson: jsonEncode(item.toJson()),
          ),
        );
  }

  @override
  Future<void> markSynced(String id) async {
    await (_db.update(_db.items)..where((t) => t.id.equals(id)))
        .write(const ItemsCompanion(dirty: Value(false)));
  }

  @override
  Future<List<VaultItem>> dirtyItems() async {
    final rows = await (_db.select(_db.items)..where((t) => t.dirty.equals(true))).get();
    return rows.map(_toVaultItem).toList();
  }

  @override
  Future<Map<String, int>> cachedItemVersions() async {
    final raw = await _readKeyValue(_itemVersionsKey);
    if (raw == null) return {};
    return (jsonDecode(raw) as Map<String, dynamic>).map((k, v) => MapEntry(k, v as int));
  }

  @override
  Future<void> setCachedItemVersions(Map<String, int> versionById) =>
      _writeKeyValue(_itemVersionsKey, jsonEncode(versionById));

  VaultItem _toVaultItem(Item row) =>
      VaultItem.fromJson(jsonDecode(row.dataJson) as Map<String, dynamic>);

  Future<String?> _readKeyValue(String key) async {
    final row = await (_db.select(_db.keyValues)..where((t) => t.key.equals(key)))
        .getSingleOrNull();
    return row?.value;
  }

  Future<void> _writeKeyValue(String key, String value) {
    return _db.into(_db.keyValues).insertOnConflictUpdate(
          KeyValuesCompanion.insert(key: key, value: value),
        );
  }
}
