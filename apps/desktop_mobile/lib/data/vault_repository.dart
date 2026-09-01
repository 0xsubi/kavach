import 'dart:convert';
import 'dart:io' show Platform;

import 'package:http/http.dart' as http;
import 'package:kavach_core/kavach_core.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:uuid/uuid.dart';

/// Orchestrates the vault: device identity, vault-key lifecycle, item CRUD
/// against [LocalVaultCache] (plan §10 phase 1), and GitHub sync (phase 2)
/// on top of the [SyncEngine]/[VaultProvisioning] that already exist in
/// `core`. Device-approval for a *second* device is not implemented yet —
/// [syncNow] always self-wraps the vault key for the current device, which
/// is only correct for a single-device vault.
class VaultRepository {
  VaultRepository({
    required this.secureStore,
    required this.cache,
    required SodiumSumo sodium,
    this.githubHttpClient,
  })  : crypto = VaultCrypto(sodium),
        _sodium = sodium;

  final SecureKeyStore secureStore;
  final LocalVaultCache cache;
  final VaultCrypto crypto;
  final SodiumSumo _sodium;

  /// Test seam: lets integration tests inject an [http.MockClient] instead
  /// of hitting the real GitHub API. `null` in production uses `http`'s
  /// default client.
  final http.Client? githubHttpClient;

  static const int epoch = 1;
  static const String _masterSaltKey = 'kavach.master.salt';
  static const String _escrowKeyPrefix = 'kavach.escrow.epoch.';
  static const String _vaultIdKey = 'kavach.vault.id';
  static const String _githubOwnerKey = 'kavach.github.owner';
  static const String _githubRepoKey = 'kavach.github.repo';
  static const Uuid _uuid = Uuid();

  SecureKey? _vaultKey;
  KeyPair? _deviceKeyPair;
  String? _deviceId;
  GitHubClient? _githubClient;
  SyncEngine? _syncEngine;

  bool get isUnlocked => _vaultKey != null;
  String? get deviceId => _deviceId;
  KeyPair? get deviceKeyPair => _deviceKeyPair;

  Future<bool> hasVault() async => (await secureStore.read(SecureKeyStoreKeys.deviceId)) != null;

  Future<void> createVault({required String masterPassword}) async {
    final deviceId = _uuid.v4();
    final deviceKeyPair = crypto.generateDeviceKeyPair();
    final vaultKey = crypto.generateVaultKey();
    final masterSalt = crypto.generateMasterSalt();
    final masterKey = crypto.deriveMasterKey(masterPassword: masterPassword, salt: masterSalt);
    final escrow = crypto.encryptEscrow(vaultKey: vaultKey, masterKey: masterKey);

    await secureStore.write(SecureKeyStoreKeys.deviceId, deviceId);
    await secureStore.write(
      SecureKeyStoreKeys.devicePrivateKey,
      base64Encode(deviceKeyPair.secretKey.extractBytes()),
    );
    await secureStore.write(
      SecureKeyStoreKeys.devicePublicKey,
      base64Encode(deviceKeyPair.publicKey),
    );
    await secureStore.write(
      '${SecureKeyStoreKeys.cachedVaultKeyPrefix}$epoch',
      base64Encode(vaultKey.extractBytes()),
    );
    await secureStore.write(_masterSaltKey, base64Encode(masterSalt));
    await secureStore.write('$_escrowKeyPrefix$epoch', base64Encode(escrow));
    await secureStore.write(_vaultIdKey, _uuid.v4());

    _deviceId = deviceId;
    _deviceKeyPair = deviceKeyPair;
    _vaultKey = vaultKey;
  }

  Future<bool> unlock() async {
    final deviceId = await secureStore.read(SecureKeyStoreKeys.deviceId);
    final vaultKeyB64 = await secureStore.read('${SecureKeyStoreKeys.cachedVaultKeyPrefix}$epoch');
    final privB64 = await secureStore.read(SecureKeyStoreKeys.devicePrivateKey);
    final pubB64 = await secureStore.read(SecureKeyStoreKeys.devicePublicKey);
    if (deviceId == null || vaultKeyB64 == null || privB64 == null || pubB64 == null) {
      return false;
    }
    _deviceId = deviceId;
    _vaultKey = SecureKey.fromList(_sodium, base64Decode(vaultKeyB64));
    _deviceKeyPair = KeyPair(
      publicKey: base64Decode(pubB64),
      secretKey: SecureKey.fromList(_sodium, base64Decode(privB64)),
    );
    return true;
  }

  /// Recovery path (plan §5): re-derive the vault key from the local escrow
  /// blob via the master password, for when the device's cached vault key
  /// copy was lost without the device itself being wiped. Full lost-*device*
  /// recovery against the GitHub-hosted escrow copy lands with sync.
  Future<bool> unlockWithMasterPassword(String masterPassword) async {
    final saltB64 = await secureStore.read(_masterSaltKey);
    final escrowB64 = await secureStore.read('$_escrowKeyPrefix$epoch');
    final deviceId = await secureStore.read(SecureKeyStoreKeys.deviceId);
    final privB64 = await secureStore.read(SecureKeyStoreKeys.devicePrivateKey);
    final pubB64 = await secureStore.read(SecureKeyStoreKeys.devicePublicKey);
    if (saltB64 == null || escrowB64 == null || deviceId == null || privB64 == null || pubB64 == null) {
      return false;
    }
    final masterKey = crypto.deriveMasterKey(
      masterPassword: masterPassword,
      salt: base64Decode(saltB64),
    );
    try {
      final vaultKey = crypto.decryptEscrow(sealed: base64Decode(escrowB64), masterKey: masterKey);
      _vaultKey = vaultKey;
      _deviceId = deviceId;
      _deviceKeyPair = KeyPair(
        publicKey: base64Decode(pubB64),
        secretKey: SecureKey.fromList(_sodium, base64Decode(privB64)),
      );
      await secureStore.write(
        '${SecureKeyStoreKeys.cachedVaultKeyPrefix}$epoch',
        base64Encode(vaultKey.extractBytes()),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  void lock() {
    _vaultKey?.dispose();
    _vaultKey = null;
    _deviceKeyPair = null;
  }

  Future<List<VaultItem>> listItems() async {
    final items = await cache.allItems();
    final visible = items.where((item) => !item.deleted).toList()
      ..sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
    return visible;
  }

  Future<void> savePasswordItem({
    String? id,
    required String name,
    required String username,
    required String password,
    List<String> uris = const [],
    String notes = '',
  }) async {
    final existing = id == null ? null : await cache.getItem(id);
    final item = VaultItem(
      id: id ?? _uuid.v7(),
      version: (existing?.version ?? 0) + 1,
      updatedAt: DateTime.now().toUtc(),
      updatedByDevice: _deviceId!,
      data: VaultItemData.password(
        name: name,
        username: username,
        password: password,
        uris: uris,
        notes: notes,
      ),
    );
    await cache.putItem(item, dirty: true);
  }

  Future<void> deleteItem(VaultItem item) async {
    final tombstone = item.copyWith(
      version: item.version + 1,
      deleted: true,
      updatedAt: DateTime.now().toUtc(),
      updatedByDevice: _deviceId!,
    );
    await cache.putItem(tombstone, dirty: true);
  }

  // ---------------------------------------------------------------------
  // GitHub sync (plan §4). Vault creation/unlock above never touch the
  // network; everything below is opt-in, configured from the settings
  // screen once the user has created a private repo and a PAT for it.
  // ---------------------------------------------------------------------

  Future<bool> hasGitHubConfigured() async {
    final owner = await secureStore.read(_githubOwnerKey);
    final repo = await secureStore.read(_githubRepoKey);
    final token = await secureStore.read(SecureKeyStoreKeys.githubToken);
    return owner != null && repo != null && token != null;
  }

  Future<({String owner, String repo})?> gitHubTarget() async {
    final owner = await secureStore.read(_githubOwnerKey);
    final repo = await secureStore.read(_githubRepoKey);
    if (owner == null || repo == null) return null;
    return (owner: owner, repo: repo);
  }

  Future<void> configureGitHub({
    required String owner,
    required String repo,
    required String token,
  }) async {
    await secureStore.write(_githubOwnerKey, owner);
    await secureStore.write(_githubRepoKey, repo);
    await secureStore.write(SecureKeyStoreKeys.githubToken, token);
    _githubClient = null;
    _syncEngine = null;
  }

  Future<SyncEngine> _ensureSyncEngine() async {
    final cached = _syncEngine;
    if (cached != null) return cached;

    final owner = await secureStore.read(_githubOwnerKey);
    final repo = await secureStore.read(_githubRepoKey);
    if (owner == null || repo == null) {
      throw StateError('GitHub sync is not configured yet.');
    }
    final client = GitHubClient(
      owner: owner,
      repo: repo,
      auth: PatAuthenticator(() => secureStore.read(SecureKeyStoreKeys.githubToken)),
      httpClient: githubHttpClient,
    );
    _githubClient = client;
    final engine = SyncEngine(github: client, cache: cache, crypto: crypto, deviceId: _deviceId!);
    _syncEngine = engine;
    return engine;
  }

  /// Ensures the remote repo has an initial commit (manifest, self-approved
  /// device record, self-wrapped vault key, escrow — plan §2/§5), then runs
  /// [SyncEngine.sync]. Safe to call on every app start / "Sync Now" tap:
  /// [VaultProvisioning.ensureInitialized] no-ops once the repo has a HEAD.
  Future<SyncReport> syncNow() async {
    final vaultKey = _vaultKey;
    final deviceKeyPair = _deviceKeyPair;
    final deviceId = _deviceId;
    if (vaultKey == null || deviceKeyPair == null || deviceId == null) {
      throw StateError('Vault must be unlocked before syncing.');
    }

    final engine = await _ensureSyncEngine();
    final provisioning = VaultProvisioning(_githubClient!);
    await provisioning.ensureInitialized(
      await _initialRepoFiles(
        vaultKey: vaultKey,
        deviceKeyPair: deviceKeyPair,
        deviceId: deviceId,
      ),
    );
    return engine.sync(vaultKey: vaultKey, epoch: epoch);
  }

  Future<Map<String, List<int>>> _initialRepoFiles({
    required SecureKey vaultKey,
    required KeyPair deviceKeyPair,
    required String deviceId,
  }) async {
    final vaultId = await secureStore.read(_vaultIdKey) ?? deviceId;
    final saltB64 = await secureStore.read(_masterSaltKey);
    final escrowB64 = await secureStore.read('$_escrowKeyPrefix$epoch');

    final selfWrapped = crypto.wrapVaultKeyForDevice(
      vaultKey: vaultKey,
      recipientPublicKey: deviceKeyPair.publicKey,
      senderKeyPair: deviceKeyPair,
    );

    final files = <String, List<int>>{
      RepoPaths.manifest: utf8.encode(jsonEncode({
        'format_version': 1,
        'vault_id': vaultId,
        'current_epoch': epoch,
      })),
      RepoPaths.device(deviceId): utf8.encode(jsonEncode({
        'device_id': deviceId,
        'public_key': base64Encode(deviceKeyPair.publicKey),
        'status': 'approved',
        'platform': Platform.operatingSystem,
      })),
      RepoPaths.vaultKeyForDevice(epoch, deviceId): utf8.encode(jsonEncode({
        'epoch': epoch,
        'device_id': deviceId,
        'wrapped_by_device_id': deviceId,
        'wrapped': base64Encode(selfWrapped),
      })),
    };

    if (saltB64 != null && escrowB64 != null) {
      files[RepoPaths.escrow(epoch)] = utf8.encode(jsonEncode({
        'epoch': epoch,
        'salt': saltB64,
        'wrapped': escrowB64,
      }));
    }

    return files;
  }
}

extension VaultItemDisplay on VaultItem {
  String get displayName => switch (data) {
        PasswordItemData d => d.name,
        PasskeyItemData d => d.rpName,
      };

  String get displaySubtitle => switch (data) {
        PasswordItemData d => d.username,
        PasskeyItemData d => d.userName,
      };
}
