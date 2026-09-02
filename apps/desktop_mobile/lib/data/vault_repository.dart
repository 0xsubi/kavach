import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:http/http.dart' as http;
import 'package:kavach_core/kavach_core.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:uuid/uuid.dart';

import 'passkey_bridge.dart';

/// Orchestrates the vault: device identity, vault-key lifecycle, item CRUD
/// against [LocalVaultCache] (plan §10 phase 1), GitHub sync (phase 2), and
/// multi-device approval (plan §5 "new device onboarding") — all on top of
/// the [SyncEngine]/[VaultProvisioning] that already exist in `core`.
class VaultRepository {
  VaultRepository({
    required this.secureStore,
    required this.cache,
    required SodiumSumo sodium,
    this.githubHttpClient,
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
    unawaited(_syncPasskeysToNative());
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
  /// pushes it to the vault repo. Safe to call whenever the vault is
  /// unlocked; called from [syncNow] itself so it rides along with every
  /// existing sync trigger (app start, foreground, manual "Sync Now").
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

  Future<GitHubClient> _ensureGitHubClient() async {
    final cached = _githubClient;
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
    return client;
  }

  Future<SyncEngine> _ensureSyncEngine() async {
    final cached = _syncEngine;
    if (cached != null) return cached;
    final client = await _ensureGitHubClient();
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
      throw StateError('vault must be unlocked before syncing.');
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
    await _drainPasskeyOutbox();
    final report = await engine.sync(vaultKey: vaultKey, epoch: epoch);
    unawaited(_syncPasskeysToNative());
    return report;
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
      RepoPaths.device(deviceId): utf8.encode(jsonEncode(
        DeviceRecord(
          deviceId: deviceId,
          publicKey: base64Encode(deviceKeyPair.publicKey),
          status: DeviceStatus.approved,
          platform: Platform.operatingSystem,
        ).toJson(),
      )),
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

  // ---------------------------------------------------------------------
  // Multi-device approval (plan §5 "new device onboarding").
  // ---------------------------------------------------------------------

  /// Registers this (brand-new, un-vaulted) device against an *existing*
  /// vault repo: generates its own keypair, writes a plaintext pending
  /// `devices/<id>.json`, and waits — it has no vault key until an already-
  /// approved device calls [approveDevice] for it. Unlike [createVault],
  /// this never touches a master password: only the approver needs one (to
  /// unlock and re-wrap), the new device just needs to be let in.
  Future<void> joinExistingVault({
    required String owner,
    required String repo,
    required String token,
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
    await configureGitHub(owner: owner, repo: repo, token: token);
    _deviceId = deviceId;

    final client = await _ensureGitHubClient();
    final headSha = await client.getHeadCommitSha();
    if (headSha == null) {
      throw StateError(
        'This GitHub repo has no vault yet — ask the vault owner to finish creating it first.',
      );
    }
    final treeSha = await client.getCommitTreeSha(headSha);

    final record = DeviceRecord(
      deviceId: deviceId,
      publicKey: base64Encode(deviceKeyPair.publicKey),
      status: DeviceStatus.pending,
      platform: Platform.operatingSystem,
    );
    final blobSha = await client.createBlob(utf8.encode(jsonEncode(record.toJson())));
    final newTreeSha = await client.createTree(
      [GitTreeEntry(path: RepoPaths.device(deviceId), mode: '100644', type: 'blob', sha: blobSha)],
      baseTreeSha: treeSha,
    );
    final commitSha = await client.createCommit(
      message: 'Kavach: device $deviceId requests approval',
      treeSha: newTreeSha,
      parentShas: [headSha],
    );
    final landed = await client.updateRefFastForward(commitSha);
    if (!landed) {
      throw StateError('failed to register this device — the repo changed concurrently. please retry.');
    }
  }

  /// Polls for an approval: looks for this device's
  /// `keys/vault-key.{epoch}.{deviceId}.json`, and if present, unwraps it
  /// (looking up the approving device's public key from its own device
  /// record) and caches the vault key locally. Safe to call repeatedly from
  /// a "waiting for approval" screen, including after an app restart — it
  /// reads device identity straight from [secureStore] rather than relying
  /// on in-memory state from [joinExistingVault].
  Future<bool> checkJoinApproval() async {
    final deviceId = await secureStore.read(SecureKeyStoreKeys.deviceId);
    final privB64 = await secureStore.read(SecureKeyStoreKeys.devicePrivateKey);
    final pubB64 = await secureStore.read(SecureKeyStoreKeys.devicePublicKey);
    if (deviceId == null || privB64 == null || pubB64 == null) return false;
    _deviceId = deviceId;

    final client = await _ensureGitHubClient();
    final headSha = await client.getHeadCommitSha();
    if (headSha == null) return false;
    final treeSha = await client.getCommitTreeSha(headSha);
    final tree = await client.getTreeRecursive(treeSha);

    final wrappedEntry = _findEntry(tree, RepoPaths.vaultKeyForDevice(epoch, deviceId));
    if (wrappedEntry?.sha == null) return false;
    final wrappedJson = jsonDecode(utf8.decode(await client.getBlobBytes(wrappedEntry!.sha!)))
        as Map<String, dynamic>;
    final approverId = wrappedJson['wrapped_by_device_id'] as String;

    final approverEntry = _findEntry(tree, RepoPaths.device(approverId));
    if (approverEntry?.sha == null) return false;
    final approverRecord = DeviceRecord.fromJson(
      jsonDecode(utf8.decode(await client.getBlobBytes(approverEntry!.sha!))) as Map<String, dynamic>,
    );

    final vaultKey = crypto.unwrapVaultKey(
      wrapped: base64Decode(wrappedJson['wrapped'] as String),
      senderPublicKey: base64Decode(approverRecord.publicKey),
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

  /// Lists every device record in the repo (plan §5's device-approval UI),
  /// pending and approved alike.
  Future<List<DeviceRecord>> listDevices() async {
    final client = await _ensureGitHubClient();
    final headSha = await client.getHeadCommitSha();
    if (headSha == null) return const [];
    final treeSha = await client.getCommitTreeSha(headSha);
    final tree = await client.getTreeRecursive(treeSha);

    final devices = <DeviceRecord>[];
    for (final entry in tree) {
      if (!entry.path.startsWith(RepoPaths.devicesDirPrefix)) continue;
      if (entry.sha == null) continue;
      final bytes = await client.getBlobBytes(entry.sha!);
      devices.add(DeviceRecord.fromJson(jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>));
    }
    return devices;
  }

  /// Approves [device]: wraps the (unlocked) vault key for its public key
  /// and flips its record to approved, in one commit. Only callable from an
  /// already-unlocked, already-approved device.
  Future<void> approveDevice(DeviceRecord device) async {
    final vaultKey = _vaultKey;
    final approverKeyPair = _deviceKeyPair;
    final approverId = _deviceId;
    if (vaultKey == null || approverKeyPair == null || approverId == null) {
      throw StateError('vault must be unlocked to approve a device.');
    }

    final client = await _ensureGitHubClient();
    final headSha = await client.getHeadCommitSha();
    if (headSha == null) throw StateError('remote vault is not initialized yet.');
    final treeSha = await client.getCommitTreeSha(headSha);

    final wrapped = crypto.wrapVaultKeyForDevice(
      vaultKey: vaultKey,
      recipientPublicKey: base64Decode(device.publicKey),
      senderKeyPair: approverKeyPair,
    );
    final wrappedBlobSha = await client.createBlob(utf8.encode(jsonEncode({
      'epoch': epoch,
      'device_id': device.deviceId,
      'wrapped_by_device_id': approverId,
      'wrapped': base64Encode(wrapped),
    })));
    final deviceBlobSha = await client.createBlob(
      utf8.encode(jsonEncode(device.copyWith(status: DeviceStatus.approved).toJson())),
    );

    final newTreeSha = await client.createTree(
      [
        GitTreeEntry(
          path: RepoPaths.vaultKeyForDevice(epoch, device.deviceId),
          mode: '100644',
          type: 'blob',
          sha: wrappedBlobSha,
        ),
        GitTreeEntry(
          path: RepoPaths.device(device.deviceId),
          mode: '100644',
          type: 'blob',
          sha: deviceBlobSha,
        ),
      ],
      baseTreeSha: treeSha,
    );
    final commitSha = await client.createCommit(
      message: 'Kavach: approve device ${device.deviceId}',
      treeSha: newTreeSha,
      parentShas: [headSha],
    );
    final landed = await client.updateRefFastForward(commitSha);
    if (!landed) {
      throw StateError('approval failed: the repo changed concurrently. please retry.');
    }
  }

  GitTreeEntry? _findEntry(List<GitTreeEntry> tree, String path) {
    for (final entry in tree) {
      if (entry.path == path) return entry;
    }
    return null;
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
