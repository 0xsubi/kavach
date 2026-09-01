import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:kavach_core/kavach_core.dart';

/// [SecureKeyStore] backed by Keychain (iOS/macOS) / Keystore (Android) via
/// `flutter_secure_storage` (plan §9).
class SecureKeyStoreNative implements SecureKeyStore {
  SecureKeyStoreNative({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
              iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
              mOptions: MacOsOptions(accessibility: KeychainAccessibility.first_unlock),
            );

  final FlutterSecureStorage _storage;

  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);

  @override
  Future<void> deleteAll() => _storage.deleteAll();
}
