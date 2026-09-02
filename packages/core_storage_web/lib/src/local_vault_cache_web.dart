import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:kavach_core/kavach_core.dart';
import 'package:web/web.dart' as web;

/// [LocalVaultCache] backed by IndexedDB — the standard web-platform
/// storage API (unlike `chrome.storage`, works in any browser context, not
/// just an extension), used here for the local decrypted-item cache (plan
/// §9). Deliberately stores the whole cache as a single JSON document under
/// one IndexedDB record rather than one row per item: a personal password
/// vault is at most a few thousand items, so the simplicity of one
/// read-modify-write per mutation beats a fully relational IDB schema with
/// indexes/cursors, and it keeps this adapter's only IndexedDB surface area
/// to "open a database, get one key, put one key" — the three operations
/// most likely to be implemented correctly on the first try.
class LocalVaultCacheWeb implements LocalVaultCache {
  LocalVaultCacheWeb._(this._db);

  static const _dbName = 'kavach_vault';
  static const _storeName = 'state';
  static const _recordKey = 'state';

  final web.IDBDatabase _db;

  static Future<LocalVaultCacheWeb> open() async {
    final request = web.window.indexedDB.open(_dbName, 1);
    final completer = Completer<web.IDBDatabase>();

    request.addEventListener(
      'upgradeneeded',
      ((web.Event _) {
        final db = request.result as web.IDBDatabase;
        if (!db.objectStoreNames.contains(_storeName)) {
          db.createObjectStore(_storeName);
        }
      }).toJS,
    );
    request.addEventListener(
      'success',
      ((web.Event _) => completer.complete(request.result as web.IDBDatabase)).toJS,
    );
    request.addEventListener(
      'error',
      ((web.Event _) =>
          completer.completeError(StateError('Failed to open the kavach_vault IndexedDB store.'))).toJS,
    );

    return LocalVaultCacheWeb._(await completer.future);
  }

  Future<Map<String, dynamic>> _readState() async {
    final tx = _db.transaction(_storeName.toJS, 'readonly');
    final store = tx.objectStore(_storeName);
    final request = store.get(_recordKey.toJS);
    final completer = Completer<Map<String, dynamic>>();

    request.addEventListener(
      'success',
      ((web.Event _) {
        final result = request.result;
        if (result.isUndefinedOrNull) {
          completer.complete(<String, dynamic>{});
        } else {
          completer.complete(jsonDecode((result as JSString).toDart) as Map<String, dynamic>);
        }
      }).toJS,
    );
    request.addEventListener(
      'error',
      ((web.Event _) =>
          completer.completeError(StateError('Failed to read the kavach_vault IndexedDB store.'))).toJS,
    );

    return completer.future;
  }

  Future<void> _writeState(Map<String, dynamic> state) async {
    final tx = _db.transaction(_storeName.toJS, 'readwrite');
    final store = tx.objectStore(_storeName);
    final request = store.put(jsonEncode(state).toJS, _recordKey.toJS);
    final completer = Completer<void>();

    request.addEventListener('success', ((web.Event _) => completer.complete()).toJS);
    request.addEventListener(
      'error',
      ((web.Event _) =>
          completer.completeError(StateError('Failed to write the kavach_vault IndexedDB store.'))).toJS,
    );

    return completer.future;
  }

  @override
  Future<String?> get lastSyncedCommitSha async => (await _readState())['lastSyncedCommitSha'] as String?;

  @override
  Future<void> setLastSyncedCommitSha(String sha) async {
    final state = await _readState();
    state['lastSyncedCommitSha'] = sha;
    await _writeState(state);
  }

  @override
  Future<List<VaultItem>> allItems() async {
    final items = (await _readState())['items'] as Map<String, dynamic>? ?? {};
    return items.values
        .map((e) => VaultItem.fromJson((e as Map<String, dynamic>)['item'] as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<VaultItem?> getItem(String id) async {
    final items = (await _readState())['items'] as Map<String, dynamic>? ?? {};
    final entry = items[id] as Map<String, dynamic>?;
    if (entry == null) return null;
    return VaultItem.fromJson(entry['item'] as Map<String, dynamic>);
  }

  @override
  Future<void> putItem(VaultItem item, {required bool dirty}) async {
    final state = await _readState();
    final items = (state['items'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    items[item.id] = {'item': item.toJson(), 'dirty': dirty};
    state['items'] = items;
    await _writeState(state);
  }

  @override
  Future<void> markSynced(String id) async {
    final state = await _readState();
    final items = (state['items'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    final entry = items[id] as Map<String, dynamic>?;
    if (entry == null) return;
    entry['dirty'] = false;
    await _writeState(state);
  }

  @override
  Future<List<VaultItem>> dirtyItems() async {
    final items = (await _readState())['items'] as Map<String, dynamic>? ?? {};
    return items.values
        .where((e) => (e as Map<String, dynamic>)['dirty'] == true)
        .map((e) => VaultItem.fromJson((e as Map<String, dynamic>)['item'] as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<Map<String, String>> cachedBlobShas() async {
    final shas = (await _readState())['blobShas'] as Map<String, dynamic>? ?? {};
    return shas.map((k, v) => MapEntry(k, v as String));
  }

  @override
  Future<void> setCachedBlobShas(Map<String, String> shaByPath) async {
    final state = await _readState();
    state['blobShas'] = shaByPath;
    await _writeState(state);
  }
}
