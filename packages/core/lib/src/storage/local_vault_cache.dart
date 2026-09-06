import '../models/vault_item.dart';

/// Local, non-secret cache of the decrypted vault: the last-synced item set,
/// the last-known remote commit SHA, and any locally-dirty (not-yet-synced)
/// items. This is what makes the app usable offline and is what
/// [SyncEngine] diffs against on each sync (plan §4).
///
/// Implemented per-target outside of `core`:
///  - native: `packages/core_storage_native`, backed by `drift` (SQLite).
///  - web/extension: `packages/core_storage_web`, backed by IndexedDB.
abstract class LocalVaultCache {
  /// The `revision` of the last `kavach-storage` sync (0 if never synced).
  /// [SyncEngine] passes this as `since_revision` so a pull only fetches
  /// items that changed after it, instead of walking the whole vault.
  Future<int> get lastSyncedRevision;
  Future<void> setLastSyncedRevision(int revision);

  Future<List<VaultItem>> allItems();
  Future<VaultItem?> getItem(String id);
  Future<void> putItem(VaultItem item, {required bool dirty});
  Future<void> markSynced(String id);
  Future<List<VaultItem>> dirtyItems();

  /// Each item id's last-known storage-server row `version` — the
  /// optimistic-concurrency baseline [SyncEngine] sends as
  /// `expected_version` on its next write for that id. An id absent here
  /// (or mapped to 0) has never been written to the server, so the next
  /// write for it is a create.
  ///
  /// This is a separate concept from [VaultItem.version]: that field is an
  /// app-level edit counter embedded in the encrypted plaintext, used to
  /// decide *whose* edit wins on a real conflict (see `merge.dart`); this
  /// map is pure transport-level optimistic concurrency against the server.
  Future<Map<String, int>> cachedItemVersions();
  Future<void> setCachedItemVersions(Map<String, int> versionById);
}
