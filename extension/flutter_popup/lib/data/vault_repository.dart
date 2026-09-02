import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:kavach_core/kavach_core.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:uuid/uuid.dart';

/// Extension-popup twin of `apps/desktop_mobile/lib/data/vault_repository.dart`
/// — same device-identity/vault-key lifecycle, item CRUD, and GitHub sync,
/// backed by `kavach_core_storage_web` instead of Keychain/drift. No
/// passkey-bridge (native-only, plan §6) and no biometric unlock (browsers
/// have no equivalent OS API), so unlocking always goes through the master
/// password or a locally-cached vault key in `chrome.storage.local`.
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

  /// Test seam: lets tests inject an [http.Client] instead of hitting the
  /// real GitHub API.
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
  // GitHub sync
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

  Future<void> configureGitHub({required String owner, required String repo, required String token}) async {
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
      await _initialRepoFiles(vaultKey: vaultKey, deviceKeyPair: deviceKeyPair, deviceId: deviceId),
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
      RepoPaths.device(deviceId): utf8.encode(jsonEncode(
        DeviceRecord(
          deviceId: deviceId,
          publicKey: base64Encode(deviceKeyPair.publicKey),
          status: DeviceStatus.approved,
          platform: 'web',
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
  // Multi-device approval (plan §5) — the extension is very often a device
  // JOINING an already-existing vault (created on desktop/mobile first),
  // so this path matters at least as much here as createVault above.
  // ---------------------------------------------------------------------

  Future<void> joinExistingVault({required String owner, required String repo, required String token}) async {
    final deviceId = _uuid.v4();
    final deviceKeyPair = crypto.generateDeviceKeyPair();

    await secureStore.write(SecureKeyStoreKeys.deviceId, deviceId);
    await secureStore.write(
      SecureKeyStoreKeys.devicePrivateKey,
      base64Encode(deviceKeyPair.secretKey.extractBytes()),
    );
    await secureStore.write(SecureKeyStoreKeys.devicePublicKey, base64Encode(deviceKeyPair.publicKey));
    await configureGitHub(owner: owner, repo: repo, token: token);
    _deviceId = deviceId;

    final client = await _ensureGitHubClient();
    final headSha = await client.getHeadCommitSha();
    if (headSha == null) {
      throw StateError('this GitHub repo has no vault yet — ask the vault owner to finish creating it first.');
    }
    final treeSha = await client.getCommitTreeSha(headSha);

    final record = DeviceRecord(
      deviceId: deviceId,
      publicKey: base64Encode(deviceKeyPair.publicKey),
      status: DeviceStatus.pending,
      platform: 'web',
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
    final wrappedJson = jsonDecode(utf8.decode(await client.getBlobBytes(wrappedEntry!.sha!))) as Map<String, dynamic>;
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
    await secureStore.write('${SecureKeyStoreKeys.cachedVaultKeyPrefix}$epoch', base64Encode(vaultKey.extractBytes()));
    vaultKey.dispose();
    return true;
  }

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
        GitTreeEntry(path: RepoPaths.device(device.deviceId), mode: '100644', type: 'blob', sha: deviceBlobSha),
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
