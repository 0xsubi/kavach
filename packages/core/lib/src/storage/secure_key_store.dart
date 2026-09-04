/// Platform-specific secure storage for key material that must never touch
/// disk unencrypted: the device's own X25519 private key, this device's
/// kavach-storage bearer token, and a cached unlocked vault key.
///
/// Implemented per-target outside of `core`:
///  - native (iOS/Android/macOS): `packages/core_storage_native`, backed by
///    `flutter_secure_storage` (Keychain / Keystore).
///  - web/extension: `packages/core_storage_web`, backed by
///    `chrome.storage.local`.
///
/// `core` only ever depends on this interface, never a concrete storage
/// package, so it stays platform-independent.
abstract class SecureKeyStore {
  Future<void> write(String key, String value);
  Future<String?> read(String key);
  Future<void> delete(String key);

  /// Clears everything this store holds. Used only for full sign-out /
  /// "remove this device" flows.
  Future<void> deleteAll();
}

/// Well-known keys used with [SecureKeyStore]. Centralized here so every
/// platform target agrees on the same storage keys.
abstract final class SecureKeyStoreKeys {
  static const String devicePrivateKey = 'kavach.device.x25519_private_key';
  static const String devicePublicKey = 'kavach.device.x25519_public_key';
  static const String deviceId = 'kavach.device.id';
  static const String storageBaseUrl = 'kavach.storage.base_url';
  static const String storageVaultId = 'kavach.storage.vault_id';
  static const String storageDeviceToken = 'kavach.storage.device_token';
  static const String cachedVaultKeyPrefix = 'kavach.vault_key.epoch.';
}
