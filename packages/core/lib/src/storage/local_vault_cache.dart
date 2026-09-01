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
  Future<String?> get lastSyncedCommitSha;
  Future<void> setLastSyncedCommitSha(String sha);

  Future<List<VaultItem>> allItems();
  Future<VaultItem?> getItem(String id);
  Future<void> putItem(VaultItem item, {required bool dirty});
  Future<void> markSynced(String id);
  Future<List<VaultItem>> dirtyItems();

  /// Cached remote tree, keyed by repo path, storing each blob's SHA so the
  /// sync engine can skip re-downloading unchanged files.
  Future<Map<String, String>> cachedBlobShas();
  Future<void> setCachedBlobShas(Map<String, String> shaByPath);
}
