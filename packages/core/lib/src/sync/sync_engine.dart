import 'dart:convert';
import 'dart:typed_data';

import 'package:sodium/sodium_sumo.dart';
import 'package:uuid/uuid.dart';

import '../crypto/aad.dart';
import '../crypto/vault_crypto.dart';
import '../models/vault_item.dart';
import '../storage/local_vault_cache.dart';
import 'kavach_storage_client.dart';
import 'merge.dart';

/// What a [SyncEngine.sync] call actually did, surfaced to the UI so it can
/// show e.g. "3 items pulled, 1 conflict copy created".
class SyncReport {
  const SyncReport({
    required this.pulledItemIds,
    required this.pushedItemIds,
    required this.conflictCopies,
    required this.didCommit,
  });

  final List<String> pulledItemIds;
  final List<String> pushedItemIds;
  final List<VaultItem> conflictCopies;
  final bool didCommit;

  bool get isNoop => pulledItemIds.isEmpty && pushedItemIds.isEmpty;
}

/// Drives "Sync Now" / auto-sync-on-start against `kavach-storage` (plan
/// §4, updated for a Postgres backend — see `kavach-storage/README.md`).
///
/// **Invariant this engine relies on**: whatever writes dirty items into
/// [LocalVaultCache] (the vault repository layer, outside `core`) must bump
/// an item's `version` by exactly 1 relative to the last version this
/// device saw for that id when marking it dirty. That lets this engine
/// infer the edit's base version as `item.version - 1` without needing a
/// separate "base version" field in the cache. (This is the app-level
/// [VaultItem.version] used by `merge.dart` — a different number from the
/// server's own per-item `expected_version`, tracked separately via
/// [LocalVaultCache.cachedItemVersions].)
class SyncEngine {
  SyncEngine({
    required this.client,
    required this.cache,
    required this.crypto,
    required this.deviceId,
    this.maxRetries = 5,
    Uuid? uuid,
  }) : _uuid = uuid ?? const Uuid();

  final KavachStorageClient client;
  final LocalVaultCache cache;
  final VaultCrypto crypto;
  final String deviceId;
  final int maxRetries;
  final Uuid _uuid;

  Future<SyncReport> sync({required SecureKey vaultKey, required int epoch}) async {
    for (var attempt = 0; attempt < maxRetries; attempt++) {
      final report = await _attemptSync(vaultKey: vaultKey, epoch: epoch);
      if (report != null) return report;
      // Batch write raced with another device; loop retries from a fresh fetch.
    }
    throw StateError(
      'Sync failed after $maxRetries attempts: the server kept rejecting our batch write '
      '(another device is syncing very frequently, or a retry storm bug).',
    );
  }

  /// Returns `null` to signal "the caller should retry" after a losing race
  /// on the batch write; otherwise returns the completed [SyncReport].
  ///
  /// Local cache is deliberately left untouched until the very end, and only
  /// mutated once (after a successful write, or immediately for a pure pull
  /// with nothing to push) — so a losing race never leaves partially-applied
  /// state behind to reconcile on retry.
  Future<SyncReport?> _attemptSync({required SecureKey vaultKey, required int epoch}) async {
    final lastRevision = await cache.lastSyncedRevision;
    final localDirty = await cache.dirtyItems();
    final cachedVersions = await cache.cachedItemVersions();

    final (:items, :latestRevision) = await client.listItemsSince(lastRevision);

    if (items.isEmpty && localDirty.isEmpty) {
      if (latestRevision != lastRevision) await cache.setLastSyncedRevision(latestRevision);
      return const SyncReport(pulledItemIds: [], pushedItemIds: [], conflictCopies: [], didCommit: false);
    }

    // --- Pull: decrypt every remotely-changed item, and remember its
    // server-side row version regardless (needed as the next write's
    // expected_version even for items we don't end up decrypting). ---
    final remoteChanged = <String, VaultItem>{};
    final newVersions = Map<String, int>.from(cachedVersions);
    for (final raw in items) {
      newVersions[raw.id] = raw.version;
      final sealed = raw.ciphertext;
      if (sealed == null) {
        // Only a non-Kavach caller of the REST API tombstones via the
        // server's own DELETE — see KavachStorageClient's item-section doc
        // comment. Nothing to decrypt; the revision bump above is enough to
        // not re-fetch this id forever.
        continue;
      }
      final plaintext = crypto.decryptItem(
        sealed: sealed,
        vaultKey: vaultKey,
        aad: itemAad(itemId: raw.id, epoch: epoch),
      );
      remoteChanged[raw.id] = VaultItem.fromJson(jsonDecode(utf8.decode(plaintext)) as Map<String, dynamic>);
    }

    // --- Merge: reconcile local dirty edits against anything that changed
    // remotely at the same id. ---
    final now = DateTime.now().toUtc();
    final toPush = <VaultItem>[]; // items to write to the server this sync
    final toApplyLocally = <String, VaultItem>{...remoteChanged}; // id -> final item for the cache
    final conflictCopies = <VaultItem>[];

    for (final dirty in localDirty) {
      final remote = remoteChanged[dirty.id];
      if (remote == null) {
        // Nothing changed remotely at this id: pure fast-forward push.
        toPush.add(dirty);
        toApplyLocally[dirty.id] = dirty;
        continue;
      }

      final decision = resolveItemConflict(
        local: dirty,
        localBaseVersion: dirty.version - 1,
        remote: remote,
        conflictItemId: _uuid.v7(),
        localDeviceId: deviceId,
        now: now,
      );

      switch (decision.outcome) {
        case MergeOutcome.fastForwardLocal:
          toPush.add(dirty);
          toApplyLocally[dirty.id] = dirty;
        case MergeOutcome.conflict:
          // Original id: remote wins, already staged in toApplyLocally via
          // remoteChanged above. The local edit survives as a new item.
          final copy = decision.conflictCopy!;
          toPush.add(copy);
          toApplyLocally[copy.id] = copy;
          conflictCopies.add(copy);
      }
    }

    if (toPush.isEmpty) {
      // Pure pull: no write needed, so no race is possible — apply directly.
      for (final item in toApplyLocally.values) {
        await cache.putItem(item, dirty: false);
      }
      await cache.setCachedItemVersions(newVersions);
      await cache.setLastSyncedRevision(latestRevision);
      return SyncReport(
        pulledItemIds: remoteChanged.keys.toList(),
        pushedItemIds: const [],
        conflictCopies: const [],
        didCommit: false,
      );
    }

    // --- Push: one atomic batch write for every pushed item. ---
    final writes = <ItemWriteRequest>[];
    for (final item in toPush) {
      final sealed = crypto.encryptItem(
        plaintext: Uint8List.fromList(utf8.encode(jsonEncode(item.toJson()))),
        vaultKey: vaultKey,
        aad: itemAad(itemId: item.id, epoch: epoch),
      );
      writes.add(ItemWriteRequest(id: item.id, ciphertext: sealed, expectedVersion: newVersions[item.id] ?? 0));
    }

    final outcome = await client.batchWrite(writes);
    if (outcome.isConflict) {
      return null; // caller retries from a fresh fetch
    }

    for (final result in outcome.items!) {
      newVersions[result.id] = result.version;
    }
    for (final item in toApplyLocally.values) {
      await cache.putItem(item, dirty: false);
    }
    await cache.setCachedItemVersions(newVersions);
    final newRevision = outcome.latestRevision! > latestRevision ? outcome.latestRevision! : latestRevision;
    await cache.setLastSyncedRevision(newRevision);

    final pushedIds = toPush.map((e) => e.id).toSet();
    return SyncReport(
      pulledItemIds: remoteChanged.keys.where((id) => !pushedIds.contains(id)).toList(),
      pushedItemIds: pushedIds.toList(),
      conflictCopies: conflictCopies,
      didCommit: true,
    );
  }
}
