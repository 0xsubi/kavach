import 'dart:convert';
import 'dart:typed_data';

import 'package:sodium/sodium_sumo.dart';
import 'package:uuid/uuid.dart';

import '../crypto/aad.dart';
import '../crypto/vault_crypto.dart';
import '../models/vault_item.dart';
import '../storage/local_vault_cache.dart';
import 'github_client.dart';
import 'merge.dart';
import 'repo_paths.dart';

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

/// Drives "Sync Now" / auto-sync-on-start (plan §4).
///
/// **Invariant this engine relies on**: whatever writes dirty items into
/// [LocalVaultCache] (the vault repository layer, outside `core`) must bump
/// an item's `version` by exactly 1 relative to the last version this
/// device saw for that id when marking it dirty. That lets this engine
/// infer the edit's base version as `item.version - 1` without needing a
/// separate "base version" field in the cache.
class SyncEngine {
  SyncEngine({
    required this.github,
    required this.cache,
    required this.crypto,
    required this.deviceId,
    this.maxRetries = 5,
    Uuid? uuid,
  }) : _uuid = uuid ?? const Uuid();

  final GitHubClient github;
  final LocalVaultCache cache;
  final VaultCrypto crypto;
  final String deviceId;
  final int maxRetries;
  final Uuid _uuid;

  Future<SyncReport> sync({required SecureKey vaultKey, required int epoch}) async {
    for (var attempt = 0; attempt < maxRetries; attempt++) {
      final report = await _attemptSync(vaultKey: vaultKey, epoch: epoch);
      if (report != null) return report;
      // Ref update raced with another device; loop retries from a fresh fetch.
    }
    throw StateError(
      'Sync failed after $maxRetries attempts: the remote ref kept moving out from '
      'under us (another device is syncing very frequently, or a retry storm bug).',
    );
  }

  /// Returns `null` to signal "the caller should retry" after a losing race
  /// on the ref update; otherwise returns the completed [SyncReport].
  ///
  /// Local cache is deliberately left untouched until the very end, and only
  /// mutated once (after a successful commit, or immediately for a pure pull
  /// with nothing to push) — so a losing race never leaves partially-applied
  /// state behind to reconcile on retry.
  Future<SyncReport?> _attemptSync({required SecureKey vaultKey, required int epoch}) async {
    final headSha = await github.getHeadCommitSha();
    if (headSha == null) {
      throw StateError('Vault repo has no commits yet; run the vault-creation flow first.');
    }
    final cachedSha = await cache.lastSyncedCommitSha;
    final localDirty = await cache.dirtyItems();

    if (headSha == cachedSha && localDirty.isEmpty) {
      return const SyncReport(
        pulledItemIds: [],
        pushedItemIds: [],
        conflictCopies: [],
        didCommit: false,
      );
    }

    final treeSha = await github.getCommitTreeSha(headSha);
    final remoteTree = await github.getTreeRecursive(treeSha);
    final cachedBlobShas = await cache.cachedBlobShas();

    final changedItemPaths = <String, String>{}; // path -> blobSha
    for (final entry in remoteTree) {
      if (!entry.path.startsWith(RepoPaths.itemsDirPrefix)) continue;
      if (entry.sha == null) continue;
      if (cachedBlobShas[entry.path] != entry.sha) {
        changedItemPaths[entry.path] = entry.sha!;
      }
    }

    // --- Pull: decrypt every remotely-changed item. ---
    final remoteChanged = <String, VaultItem>{};
    for (final MapEntry(key: path, value: blobSha) in changedItemPaths.entries) {
      final id = _idFromItemPath(path);
      final bytes = Uint8List.fromList(await github.getBlobBytes(blobSha));
      final plaintext = crypto.decryptItem(
        sealed: bytes,
        vaultKey: vaultKey,
        aad: itemAad(itemId: id, epoch: epoch),
      );
      final item = VaultItem.fromJson(jsonDecode(utf8.decode(plaintext)) as Map<String, dynamic>);
      remoteChanged[id] = item;
    }

    // --- Merge: reconcile local dirty edits against anything that changed
    // remotely at the same id. ---
    final now = DateTime.now().toUtc();
    final toPush = <VaultItem>[]; // items to write to the repo this sync
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
      // Pure pull: no commit needed, so no race is possible — apply directly.
      for (final item in toApplyLocally.values) {
        await cache.putItem(item, dirty: false);
      }
      await cache.setCachedBlobShas({...cachedBlobShas, ...changedItemPaths});
      await cache.setLastSyncedCommitSha(headSha);
      return SyncReport(
        pulledItemIds: remoteChanged.keys.toList(),
        pushedItemIds: const [],
        conflictCopies: const [],
        didCommit: false,
      );
    }

    // --- Push: build one commit for every pushed item.
    //
    // Ciphertext is binary, and the create-tree API's inline `content` field
    // is treated as UTF-8 text, so each item is written via an explicit
    // create-blob call rather than inline tree content.
    final pushTreeEntries = <GitTreeEntry>[];
    for (final item in toPush) {
      final sealed = crypto.encryptItem(
        plaintext: Uint8List.fromList(utf8.encode(jsonEncode(item.toJson()))),
        vaultKey: vaultKey,
        aad: itemAad(itemId: item.id, epoch: epoch),
      );
      final blobSha = await github.createBlob(sealed);
      pushTreeEntries.add(
        GitTreeEntry(path: RepoPaths.item(item.id), mode: '100644', type: 'blob', sha: blobSha),
      );
    }

    final newTreeSha = await github.createTree(pushTreeEntries, baseTreeSha: treeSha);
    final commitSha = await github.createCommit(
      message: 'Kavach sync from $deviceId: ${toPush.length} item(s)',
      treeSha: newTreeSha,
      parentShas: [headSha],
    );
    final landed = await github.updateRefFastForward(commitSha);
    if (!landed) {
      return null; // caller retries from a fresh fetch
    }

    for (final item in toApplyLocally.values) {
      await cache.putItem(item, dirty: false);
    }
    // Blob shas for pushed paths are now stale (we know the item content,
    // not the sha git assigned it); drop them so the next sync's tree diff
    // re-checks those paths against HEAD rather than trusting a guess.
    final newBlobShaCache = {...cachedBlobShas, ...changedItemPaths}
      ..removeWhere((path, _) => toPush.any((item) => RepoPaths.item(item.id) == path));
    await cache.setCachedBlobShas(newBlobShaCache);
    await cache.setLastSyncedCommitSha(commitSha);

    final pushedIds = toPush.map((e) => e.id).toSet();
    return SyncReport(
      pulledItemIds: remoteChanged.keys.where((id) => !pushedIds.contains(id)).toList(),
      pushedItemIds: pushedIds.toList(),
      conflictCopies: conflictCopies,
      didCommit: true,
    );
  }

  String _idFromItemPath(String path) {
    final fileName = path.split('/').last;
    return fileName.substring(0, fileName.length - '.json.enc'.length);
  }
}
