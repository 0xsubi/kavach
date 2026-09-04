import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:http/http.dart' as http;
import 'package:kavach_core/kavach_core.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:uuid/uuid.dart';

import 'passkey_bridge.dart';

/// Orchestrates the vault: device identity, vault-key lifecycle, item CRUD
/// against [LocalVaultCache] (plan §10 phase 1), `kavach-storage` sync
/// (phase 2, see `kavach-storage/README.md` at the repo root), and
/// multi-device approval (plan §5 "new device onboarding") — all on top of
/// the [SyncEngine] that already exists in `core`.
class VaultRepository {
  VaultRepository({
    required this.secureStore,
    required this.cache,
    required SodiumSumo sodium,
    this.storageHttpClient,
    PasskeyBridge? passkeyBridge,
  })  : crypto = VaultCrypto(sodium),
        _sodium = sodium,
        _passkeyBridge = passkeyBridge ?? MethodChannelPasskeyBridge();

  final SecureKeyStore secureStore;
  final LocalVaultCache cache;
  final VaultCrypto crypto;
  final SodiumSumo _sodium;
  final PasskeyBridge _passkeyBridge;

  /// Test seam: lets integration tests inject an [http.MockClient] instead
  /// of hitting a real kavach-storage server. `null` in production uses
  /// `http`'s default client.
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
  KeyPair? get deviceKeyPair => _deviceKeyPair;

  Future<bool> hasVault() async => (await secureStore.read(SecureKeyStoreKeys.deviceId)) != null;

  /// True once this device has a usable vault key cached — false for a
  /// device that registered via [joinExistingVault] but hasn't been
  /// approved yet.
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
    unawaited(_syncPasskeysToNative());
    return true;
  }

  /// Recovery path (plan §5): re-derive the vault key from the local escrow
  /// blob via the master password, for when the device's cached vault key
  /// copy was lost without the device itself being wiped. Full lost-*device*
  /// recovery against the remotely-escrowed copy isn't wired up yet — see
  /// [setupNewVaultStorage]'s note on [KavachStorageClient.putEscrowKey].
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
      unawaited(_syncPasskeysToNative());
      return true;
    } catch (_) {
      return false;
    }
  }

  void lock() {
    _vaultKey?.dispose();
    _vaultKey = null;
    _deviceKeyPair = null;
    unawaited(_passkeyBridge.clearOnLock());
  }

  /// Pushes every passkey currently in the local cache into the shared
  /// Keychain and the OS credential-identity store, so the credential-
  /// provider extension can sign with them while the vault is unlocked
  /// (plan §6). Called after every successful unlock; a no-op on platforms
  /// without a passkey extension (Android, or before native provisioning is
  /// set up) since [PasskeyBridge] swallows those failures itself.
  Future<void> _syncPasskeysToNative() async {
    final items = await cache.allItems();
    final passkeys = items.where((i) => !i.deleted && i.data is PasskeyItemData).toList();
    await _passkeyBridge.syncUnlocked(passkeys);
  }

  /// Drains passkeys the credential-provider extension created since the app
  /// last ran, persisting each as a dirty local item so the next [syncNow]
  /// pushes it to the vault. Safe to call whenever the vault is unlocked;
  /// called from [syncNow] itself so it rides along with every existing
  /// sync trigger (app start, foreground, manual "Sync Now").
  Future<void> _drainPasskeyOutbox() async {
    if (_deviceId == null) return;
    final drained = await _passkeyBridge.drainOutboxAsVaultItems(deviceId: _deviceId!);
    for (final item in drained) {
      await cache.putItem(item, dirty: true);
    }
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
  // kavach-storage sync (plan §4). Vault creation/unlock above never touch
  // the network; everything below is opt-in, configured from the settings
  // screen once the user (or whoever hosts their kavach-storage instance)
  // has given them a server URL and either an admin token (to create a
  // brand-new vault) or an invite token (to join an existing one).
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

  /// Creates a brand-new vault on the kavach-storage server at [baseUrl]
  /// (the caller must hold that server's admin/provisioning token) and
  /// registers this device as its first, auto-approved device. Call once,
  /// right after [createVault] — unlike the old GitHub backend, there's no
  /// implicit "ensure initialized" step on every sync: the server creates
  /// the vault/device rows explicitly, right here, instead of on first
  /// commit.
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
      platform: Platform.operatingSystem,
    );
    await _persistStorageConfig(baseUrl: baseUrl, vaultId: created.vaultId, deviceToken: registered.deviceToken);

    final client = await _ensureStorageClient();
    final selfWrapped = crypto.wrapVaultKeyForDevice(
      vaultKey: vaultKey,
      recipientPublicKey: deviceKeyPair.publicKey,
      senderKeyPair: deviceKeyPair,
    );
    await client.putWrappedVaultKey(epoch: epoch, deviceId: deviceId, wrapped: selfWrapped);

    // Pushed for forward-compatibility with a future "recover with just the
    // master password" flow; not read back by this client yet (today's
    // unlockWithMasterPassword only ever reads the *local* escrow copy).
    final escrowB64 = await secureStore.read('$_escrowKeyPrefix$epoch');
    if (escrowB64 != null) {
      await client.putEscrowKey(epoch: epoch, wrapped: base64Decode(escrowB64));
    }
  }

  /// Ensures the drained passkey outbox is flushed, then runs
  /// [SyncEngine.sync]. Safe to call on every app start / "Sync Now" tap.
  Future<SyncReport> syncNow() async {
    final vaultKey = _vaultKey;
    final deviceKeyPair = _deviceKeyPair;
    final deviceId = _deviceId;
    if (vaultKey == null || deviceKeyPair == null || deviceId == null) {
      throw StateError('vault must be unlocked before syncing.');
    }

    final engine = await _ensureSyncEngine();
    await _drainPasskeyOutbox();
    final report = await engine.sync(vaultKey: vaultKey, epoch: epoch);
    unawaited(_syncPasskeysToNative());
    return report;
  }

  // ---------------------------------------------------------------------
  // Multi-device approval (plan §5 "new device onboarding").
  // ---------------------------------------------------------------------

  /// Registers this (brand-new, un-vaulted) device against an *existing*
  /// vault, authenticating with an invite token an already-approved device
  /// minted via [createDeviceInvite]. Unlike [createVault], this never
  /// touches a master password: only the approver needs one (to unlock and
  /// re-wrap), the new device just needs to be let in.
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
    await secureStore.write(
      SecureKeyStoreKeys.devicePublicKey,
      base64Encode(deviceKeyPair.publicKey),
    );

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
      platform: Platform.operatingSystem,
    );
    await _persistStorageConfig(baseUrl: baseUrl, vaultId: vaultId, deviceToken: registered.deviceToken);
    _deviceId = deviceId;
    _deviceKeyPair = deviceKeyPair;
  }

  /// Polls for an approval: looks for this device's wrapped vault key, and
  /// if present, unwraps it (looking up the approving device's public key
  /// via [KavachStorageClient.getDevice]) and caches the vault key locally.
  /// Safe to call repeatedly from a "waiting for approval" screen, including
  /// after an app restart — it reads device identity straight from
  /// [secureStore] rather than relying on in-memory state from
  /// [joinExistingVault].
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
    await secureStore.write(
      '${SecureKeyStoreKeys.cachedVaultKeyPrefix}$epoch',
      base64Encode(vaultKey.extractBytes()),
    );
    vaultKey.dispose();
    unawaited(_syncPasskeysToNative());
    return true;
  }

  /// Lists every device registered against this vault (plan §5's
  /// device-approval UI), pending and approved alike.
  Future<List<DeviceRecord>> listDevices() async {
    final client = await _ensureStorageClient();
    return client.listDevices();
  }

  /// Mints a short-lived invite token for a brand-new device to register
  /// with (see [joinExistingVault]'s `inviteToken` param), without ever
  /// handing that new device this device's own permanent bearer token.
  Future<({String inviteToken, DateTime expiresAt})> createDeviceInvite() async {
    final client = await _ensureStorageClient();
    return client.createDeviceInvite();
  }

  /// Approves [device]: wraps the (unlocked) vault key for its public key
  /// and flips its record to approved. Only callable from an already-
  /// unlocked, already-approved device.
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
