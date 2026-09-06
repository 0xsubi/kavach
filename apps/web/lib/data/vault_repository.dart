import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:kavach_core/kavach_core.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:uuid/uuid.dart';

/// Extension-popup twin of `apps/kavach/lib/data/vault_repository.dart`
/// — same device-identity/vault-key lifecycle, item CRUD, and kavach-storage
/// sync, backed by `kavach_core_storage_web` instead of Keychain/drift. No
/// passkey-bridge (native-only, plan §6) and no biometric unlock (browsers
/// have no equivalent OS API), so unlocking always goes through the master
/// password or a locally-cached vault key in `chrome.storage.local`.
class VaultRepository {
  VaultRepository({
    required this.secureStore,
    required this.cache,
    required SodiumSumo sodium,
    this.storageHttpClient,
  })  : crypto = VaultCrypto(sodium),
        _sodium = sodium;

  final SecureKeyStore secureStore;
  final LocalVaultCache cache;
  final VaultCrypto crypto;
  final SodiumSumo _sodium;

  /// Test seam: lets tests inject an [http.Client] instead of hitting a
  /// real kavach-storage server.
  final http.Client? storageHttpClient;

  static const int epoch = 1;
  static const String _masterSaltKey = 'kavach.master.salt';
  static const String _escrowKeyPrefix = 'kavach.escrow.epoch.';
  static const Uuid _uuid = Uuid();

  SecureKey? _vaultKey;
  KeyPair? _deviceKeyPair;
  String? _deviceId;
  KavachStorageClient? _storageClient;
  SyncEngine? _syncEngine;

  bool get isUnlocked => _vaultKey != null;
  String? get deviceId => _deviceId;

  Future<bool> hasVault() async => (await secureStore.read(SecureKeyStoreKeys.deviceId)) != null;

  Future<bool> hasCachedVaultKey() async =>
      (await secureStore.read('${SecureKeyStoreKeys.cachedVaultKeyPrefix}$epoch')) != null;

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
    await secureStore.write(SecureKeyStoreKeys.devicePublicKey, base64Encode(deviceKeyPair.publicKey));
    await secureStore.write(
      '${SecureKeyStoreKeys.cachedVaultKeyPrefix}$epoch',
      base64Encode(vaultKey.extractBytes()),
    );
    await secureStore.write(_masterSaltKey, base64Encode(masterSalt));
    await secureStore.write('$_escrowKeyPrefix$epoch', base64Encode(escrow));

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

  Future<bool> unlockWithMasterPassword(String masterPassword) async {
    final saltB64 = await secureStore.read(_masterSaltKey);
    final escrowB64 = await secureStore.read('$_escrowKeyPrefix$epoch');
    final deviceId = await secureStore.read(SecureKeyStoreKeys.deviceId);
    final privB64 = await secureStore.read(SecureKeyStoreKeys.devicePrivateKey);
    final pubB64 = await secureStore.read(SecureKeyStoreKeys.devicePublicKey);
    if (saltB64 == null || escrowB64 == null || deviceId == null || privB64 == null || pubB64 == null) {
      return false;
    }
    final masterKey = crypto.deriveMasterKey(masterPassword: masterPassword, salt: base64Decode(saltB64));
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
      data: VaultItemData.password(name: name, username: username, password: password, uris: uris, notes: notes),
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
  // kavach-storage sync
  // ---------------------------------------------------------------------

  Future<bool> hasStorageConfigured() async {
    final baseUrl = await secureStore.read(SecureKeyStoreKeys.storageBaseUrl);
    final vaultId = await secureStore.read(SecureKeyStoreKeys.storageVaultId);
    final token = await secureStore.read(SecureKeyStoreKeys.storageDeviceToken);
    return baseUrl != null && vaultId != null && token != null;
  }

  Future<({String baseUrl, String vaultId})?> storageTarget() async {
    final baseUrl = await secureStore.read(SecureKeyStoreKeys.storageBaseUrl);
    final vaultId = await secureStore.read(SecureKeyStoreKeys.storageVaultId);
    if (baseUrl == null || vaultId == null) return null;
    return (baseUrl: baseUrl, vaultId: vaultId);
  }

  Future<void> _persistStorageConfig({
    required String baseUrl,
    required String vaultId,
    required String deviceToken,
  }) async {
    await secureStore.write(SecureKeyStoreKeys.storageBaseUrl, baseUrl);
    await secureStore.write(SecureKeyStoreKeys.storageVaultId, vaultId);
    await secureStore.write(SecureKeyStoreKeys.storageDeviceToken, deviceToken);
    _storageClient = null;
    _syncEngine = null;
  }

  Future<KavachStorageClient> _ensureStorageClient() async {
    final cached = _storageClient;
    if (cached != null) return cached;

    final baseUrl = await secureStore.read(SecureKeyStoreKeys.storageBaseUrl);
    final vaultId = await secureStore.read(SecureKeyStoreKeys.storageVaultId);
    if (baseUrl == null || vaultId == null) {
      throw StateError('kavach-storage is not configured yet.');
    }
    final client = KavachStorageClient(
      baseUrl: baseUrl,
      vaultId: vaultId,
      deviceTokenProvider: () => secureStore.read(SecureKeyStoreKeys.storageDeviceToken),
      httpClient: storageHttpClient,
    );
    _storageClient = client;
    return client;
  }

  Future<SyncEngine> _ensureSyncEngine() async {
    final cached = _syncEngine;
    if (cached != null) return cached;
    final client = await _ensureStorageClient();
    final engine = SyncEngine(client: client, cache: cache, crypto: crypto, deviceId: _deviceId!);
    _syncEngine = engine;
    return engine;
  }

  Future<void> setupNewVaultStorage({required String baseUrl, required String adminToken}) async {
    final vaultKey = _vaultKey;
    final deviceKeyPair = _deviceKeyPair;
    final deviceId = _deviceId;
    if (vaultKey == null || deviceKeyPair == null || deviceId == null) {
      throw StateError('call createVault() before setupNewVaultStorage().');
    }

    final created = await KavachStorageClient.createVault(
      baseUrl: baseUrl,
      adminToken: adminToken,
      httpClient: storageHttpClient,
    );
    final bootstrapClient = KavachStorageClient(
      baseUrl: baseUrl,
      vaultId: created.vaultId,
      deviceTokenProvider: () => secureStore.read(SecureKeyStoreKeys.storageDeviceToken),
      httpClient: storageHttpClient,
    );
    final registered = await bootstrapClient.registerDevice(
      token: created.bootstrapToken,
      deviceId: deviceId,
      publicKey: base64Encode(deviceKeyPair.publicKey),
      platform: 'web',
    );
    await _persistStorageConfig(baseUrl: baseUrl, vaultId: created.vaultId, deviceToken: registered.deviceToken);

    final client = await _ensureStorageClient();
    final selfWrapped = crypto.wrapVaultKeyForDevice(
      vaultKey: vaultKey,
      recipientPublicKey: deviceKeyPair.publicKey,
      senderKeyPair: deviceKeyPair,
    );
    await client.putWrappedVaultKey(epoch: epoch, deviceId: deviceId, wrapped: selfWrapped);

    final escrowB64 = await secureStore.read('$_escrowKeyPrefix$epoch');
    if (escrowB64 != null) {
      await client.putEscrowKey(epoch: epoch, wrapped: base64Decode(escrowB64));
    }
  }

  Future<SyncReport> syncNow() async {
    final vaultKey = _vaultKey;
    final deviceKeyPair = _deviceKeyPair;
    final deviceId = _deviceId;
    if (vaultKey == null || deviceKeyPair == null || deviceId == null) {
      throw StateError('vault must be unlocked before syncing.');
    }

    final engine = await _ensureSyncEngine();
    return engine.sync(vaultKey: vaultKey, epoch: epoch);
  }

  // ---------------------------------------------------------------------
  // Multi-device approval (plan §5) — the extension is very often a device
  // JOINING an already-existing vault (created on desktop/mobile first),
  // so this path matters at least as much here as createVault above.
  // ---------------------------------------------------------------------

  Future<void> joinExistingVault({
    required String baseUrl,
    required String vaultId,
    required String inviteToken,
  }) async {
    final deviceId = _uuid.v4();
    final deviceKeyPair = crypto.generateDeviceKeyPair();

    await secureStore.write(SecureKeyStoreKeys.deviceId, deviceId);
    await secureStore.write(
      SecureKeyStoreKeys.devicePrivateKey,
      base64Encode(deviceKeyPair.secretKey.extractBytes()),
    );
    await secureStore.write(SecureKeyStoreKeys.devicePublicKey, base64Encode(deviceKeyPair.publicKey));

    final client = KavachStorageClient(
      baseUrl: baseUrl,
      vaultId: vaultId,
      deviceTokenProvider: () => secureStore.read(SecureKeyStoreKeys.storageDeviceToken),
      httpClient: storageHttpClient,
    );
    final registered = await client.registerDevice(
      token: inviteToken,
      deviceId: deviceId,
      publicKey: base64Encode(deviceKeyPair.publicKey),
      platform: 'web',
    );
    await _persistStorageConfig(baseUrl: baseUrl, vaultId: vaultId, deviceToken: registered.deviceToken);
    _deviceId = deviceId;
    _deviceKeyPair = deviceKeyPair;
  }

  Future<bool> checkJoinApproval() async {
    final deviceId = await secureStore.read(SecureKeyStoreKeys.deviceId);
    final privB64 = await secureStore.read(SecureKeyStoreKeys.devicePrivateKey);
    final pubB64 = await secureStore.read(SecureKeyStoreKeys.devicePublicKey);
    if (deviceId == null || privB64 == null || pubB64 == null) return false;
    _deviceId = deviceId;

    final client = await _ensureStorageClient();
    final WrappedVaultKey wrapped;
    try {
      wrapped = await client.getWrappedVaultKey(epoch: epoch, deviceId: deviceId);
    } on KavachStorageApiException catch (e) {
      if (e.statusCode == 404) return false;
      rethrow;
    }

    final approver = await client.getDevice(wrapped.wrappedByDeviceId);
    final vaultKey = crypto.unwrapVaultKey(
      wrapped: wrapped.wrappedKey,
      senderPublicKey: base64Decode(approver.publicKey),
      recipientKeyPair: KeyPair(
        publicKey: base64Decode(pubB64),
        secretKey: SecureKey.fromList(_sodium, base64Decode(privB64)),
      ),
    );
    await secureStore.write('${SecureKeyStoreKeys.cachedVaultKeyPrefix}$epoch', base64Encode(vaultKey.extractBytes()));
    vaultKey.dispose();
    return true;
  }

  Future<List<DeviceRecord>> listDevices() async {
    final client = await _ensureStorageClient();
    return client.listDevices();
  }

  Future<({String inviteToken, DateTime expiresAt})> createDeviceInvite() async {
    final client = await _ensureStorageClient();
    return client.createDeviceInvite();
  }

  Future<void> approveDevice(DeviceRecord device) async {
    final vaultKey = _vaultKey;
    final approverKeyPair = _deviceKeyPair;
    if (vaultKey == null || approverKeyPair == null) {
      throw StateError('vault must be unlocked to approve a device.');
    }

    final client = await _ensureStorageClient();
    final wrapped = crypto.wrapVaultKeyForDevice(
      vaultKey: vaultKey,
      recipientPublicKey: base64Decode(device.publicKey),
      senderKeyPair: approverKeyPair,
    );
    await client.putWrappedVaultKey(epoch: epoch, deviceId: device.deviceId, wrapped: wrapped);
    await client.updateDeviceStatus(deviceId: device.deviceId, status: DeviceStatus.approved);
  }
}

/// Host of [uri], tolerating the free-text forms users actually type into
/// the item editor (`amazon.com`, `www.amazon.com`, `https://amazon.com/gp`
/// all normalize to `amazon.com`). Dart's `Uri.parse` treats a string with
/// no `://` as a bare path with no host at all — `Uri.parse('amazon.com')
/// .host` is `''`, not `'amazon.com'` — so a scheme is prepended first when
/// missing, and any `www.` prefix is stripped so a saved bare domain still
/// matches the page's actual (`www.`-prefixed) origin.
String? _normalizedHost(String uri) {
  final withScheme = uri.contains('://') ? uri : 'https://$uri';
  final host = Uri.tryParse(withScheme)?.host.toLowerCase();
  if (host == null || host.isEmpty) return null;
  return host.startsWith('www.') ? host.substring(4) : host;
}

/// Password items whose stored URIs share a host with [origin] (e.g.
/// `https://example.com`) — used to answer the content script's "does the
/// vault have anything for this page?" autofill query.
List<VaultItem> matchesForOrigin(List<VaultItem> items, String origin) {
  final targetHost = _normalizedHost(origin);
  if (targetHost == null) return const [];

  return items.where((item) {
    final data = item.data;
    if (data is! PasswordItemData) return false;
    return data.uris.any((uri) => _normalizedHost(uri) == targetHost);
  }).toList();
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
