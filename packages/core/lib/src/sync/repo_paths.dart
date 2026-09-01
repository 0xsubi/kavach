/// File paths within the `.kavach`-backed vault repo (plan §2). Centralized
/// here so [SyncEngine], onboarding/approval flows, and tests all agree on
/// the exact layout.
abstract final class RepoPaths {
  static const String manifest = '.kavach/manifest.json';
  static const String index = '.kavach/index.json.enc';

  static String device(String deviceId) => '.kavach/devices/$deviceId.json';

  static String vaultKeyForDevice(int epoch, String deviceId) =>
      '.kavach/keys/vault-key.$epoch.$deviceId.json';

  static String escrow(int epoch) => '.kavach/keys/escrow.$epoch.json';

  /// Items are sharded by the first 2 hex characters of their id to avoid
  /// dumping thousands of files into one directory.
  static String item(String itemId) {
    final shard = itemId.length >= 2 ? itemId.substring(0, 2) : '00';
    return 'items/$shard/$itemId.json.enc';
  }

  static const String devicesDirPrefix = '.kavach/devices/';
  static const String itemsDirPrefix = 'items/';
}
