import 'package:kavach_core/kavach_core.dart';

import 'chrome_storage_interop.dart';

/// [SecureKeyStore] backed by the extension's `chrome.storage.local` (plan
/// §9) — the only persistence a browser-extension popup/service-worker has
/// that isn't the OS Keychain, which extensions can't reach. Not literally
/// OS-secure the way native Keychain/Keystore is, but `chrome.storage` is
/// sandboxed per-extension-id and never touches disk as a plain file the
/// way a naive `localStorage` fallback would.
///
/// Requires the `"storage"` permission in the extension manifest.
class SecureKeyStoreWeb implements SecureKeyStore {
  @override
  Future<void> write(String key, String value) => ChromeStorageLocal.set(key, value);

  @override
  Future<String?> read(String key) => ChromeStorageLocal.get(key);

  @override
  Future<void> delete(String key) => ChromeStorageLocal.remove(key);

  @override
  Future<void> deleteAll() => ChromeStorageLocal.clear();
}
