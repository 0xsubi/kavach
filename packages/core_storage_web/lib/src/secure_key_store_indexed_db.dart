import 'dart:async';
import 'dart:js_interop';

import 'package:kavach_core/kavach_core.dart';
import 'package:web/web.dart' as web;

/// [SecureKeyStore] for a plain web page — no extension runtime, so there's
/// no `chrome.storage.local` to proxy through (see [SecureKeyStoreWeb]).
/// IndexedDB is the only origin-scoped persistence a standalone site has.
///
/// This is *not* OS-Keychain-grade protection: anything with script
/// execution in this origin — most concretely a successful XSS against
/// `apps/web` itself — can read the device private key and any cached
/// vault key straight out of here, the same way it could read
/// `localStorage`. That is an inherent limit of running a password
/// manager as a website rather than a browser extension or native app,
/// not a bug in this adapter; it's the same tradeoff Vaultwarden's own web
/// vault makes. Mitigations that actually matter live outside this class:
/// a strict `Content-Security-Policy` at the nginx layer (see
/// `apps/web/nginx.conf`) and keeping this app's dependency surface small.
class SecureKeyStoreIndexedDb implements SecureKeyStore {
  SecureKeyStoreIndexedDb._(this._db);

  static const _dbName = 'kavach_keystore';
  static const _storeName = 'keys';

  final web.IDBDatabase _db;

  static Future<SecureKeyStoreIndexedDb> open() async {
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
          completer.completeError(StateError('Failed to open the kavach_keystore IndexedDB store.'))).toJS,
    );

    return SecureKeyStoreIndexedDb._(await completer.future);
  }

  @override
  Future<void> write(String key, String value) async {
    final tx = _db.transaction(_storeName.toJS, 'readwrite');
    final request = tx.objectStore(_storeName).put(value.toJS, key.toJS);
    final completer = Completer<void>();
    request.addEventListener('success', ((web.Event _) => completer.complete()).toJS);
    request.addEventListener(
      'error',
      ((web.Event _) => completer.completeError(StateError('Failed to write "$key" to IndexedDB.'))).toJS,
    );
    return completer.future;
  }

  @override
  Future<String?> read(String key) async {
    final tx = _db.transaction(_storeName.toJS, 'readonly');
    final request = tx.objectStore(_storeName).get(key.toJS);
    final completer = Completer<String?>();
    request.addEventListener(
      'success',
      ((web.Event _) {
        final result = request.result;
        completer.complete(result.isUndefinedOrNull ? null : (result as JSString).toDart);
      }).toJS,
    );
    request.addEventListener(
      'error',
      ((web.Event _) => completer.completeError(StateError('Failed to read "$key" from IndexedDB.'))).toJS,
    );
    return completer.future;
  }

  @override
  Future<void> delete(String key) async {
    final tx = _db.transaction(_storeName.toJS, 'readwrite');
    final request = tx.objectStore(_storeName).delete(key.toJS);
    final completer = Completer<void>();
    request.addEventListener('success', ((web.Event _) => completer.complete()).toJS);
    request.addEventListener(
      'error',
      ((web.Event _) => completer.completeError(StateError('Failed to delete "$key" from IndexedDB.'))).toJS,
    );
    return completer.future;
  }

  @override
  Future<void> deleteAll() async {
    final tx = _db.transaction(_storeName.toJS, 'readwrite');
    final request = tx.objectStore(_storeName).clear();
    final completer = Completer<void>();
    request.addEventListener('success', ((web.Event _) => completer.complete()).toJS);
    request.addEventListener(
      'error',
      ((web.Event _) => completer.completeError(StateError('Failed to clear the kavach_keystore store.'))).toJS,
    );
    return completer.future;
  }
}
