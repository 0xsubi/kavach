import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'device_record.dart';

/// Thin REST client for `kavach-storage` (see `kavach-storage/README.md` in
/// the monorepo root) — the Postgres-backed replacement for the old
/// GitHub-repo backend. Every method maps directly to one `openapi.yaml`
/// operation; there is no git-shaped blob/tree/commit plumbing here, since
/// the server already exposes vault/device/key/item resources directly.
class KavachStorageClient {
  KavachStorageClient({
    required this.baseUrl,
    required this.vaultId,
    required this.deviceTokenProvider,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  /// e.g. `https://kavach-storage.example.com` — no trailing slash, no `/v1`.
  final String baseUrl;
  final String vaultId;

  /// Reads this device's own persisted bearer token. Not used by
  /// [registerDevice], which authenticates with a one-off bootstrap/invite
  /// token instead — this device doesn't have its own token yet at that point.
  final Future<String?> Function() deviceTokenProvider;
  final http.Client _http;

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$baseUrl/v1$path').replace(queryParameters: query);

  Future<Map<String, String>> _authHeaders() async {
    final token = await deviceTokenProvider();
    if (token == null) throw StateError('kavach-storage is not configured on this device yet.');
    return {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'};
  }

  void _throwIfError(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    throw KavachStorageApiException(response.statusCode, response.body);
  }

  // ---------------------------------------------------------------------
  // Vault + device onboarding.
  // ---------------------------------------------------------------------

  /// Creates a brand-new vault. Requires the server operator's admin token,
  /// not any device's token — there is no device yet. Static because it
  /// doesn't need a [vaultId] (that's what it returns).
  static Future<({String vaultId, String bootstrapToken})> createVault({
    required String baseUrl,
    required String adminToken,
    Map<String, dynamic> kdfDefaults = const {},
    http.Client? httpClient,
  }) async {
    final client = httpClient ?? http.Client();
    final response = await client.post(
      Uri.parse('$baseUrl/v1/vaults'),
      headers: {'Authorization': 'Bearer $adminToken', 'Content-Type': 'application/json'},
      body: jsonEncode({'kdf_defaults': kdfDefaults}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw KavachStorageApiException(response.statusCode, response.body);
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (vaultId: body['vault_id'] as String, bootstrapToken: body['bootstrap_token'] as String);
  }

  /// Registers this device against [vaultId], authenticating with a
  /// one-off [token] (the vault's bootstrap token for the very first
  /// device, an invite token for every device after that, or — as a
  /// convenience — an already-approved device's own token) rather than
  /// [deviceTokenProvider], since this device doesn't have its own token to
  /// read yet.
  Future<({String deviceToken, DeviceStatus status})> registerDevice({
    required String token,
    required String deviceId,
    required String publicKey,
    required String platform,
  }) async {
    final response = await _http.post(
      _uri('/vaults/$vaultId/devices'),
      headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
      body: jsonEncode({'device_id': deviceId, 'public_key': publicKey, 'platform': platform}),
    );
    _throwIfError(response);
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (
      deviceToken: body['device_token'] as String,
      status: DeviceStatus.values.byName(body['status'] as String),
    );
  }

  /// Mints a short-lived invite token a new device can register with
  /// (`registerDevice`'s [token] param) without ever holding this device's
  /// own permanent token. Caller must already be approved.
  Future<({String inviteToken, DateTime expiresAt})> createDeviceInvite() async {
    final response = await _http.post(_uri('/vaults/$vaultId/devices/invites'), headers: await _authHeaders());
    _throwIfError(response);
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (inviteToken: body['invite_token'] as String, expiresAt: DateTime.parse(body['expires_at'] as String));
  }

  // ---------------------------------------------------------------------
  // Devices.
  // ---------------------------------------------------------------------

  Future<List<DeviceRecord>> listDevices() async {
    final response = await _http.get(_uri('/vaults/$vaultId/devices'), headers: await _authHeaders());
    _throwIfError(response);
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['devices'] as List)
        .cast<Map<String, dynamic>>()
        .map(_deviceRecordFromApiJson)
        .toList();
  }

  Future<DeviceRecord> getDevice(String deviceId) async {
    final response = await _http.get(_uri('/vaults/$vaultId/devices/$deviceId'), headers: await _authHeaders());
    _throwIfError(response);
    return _deviceRecordFromApiJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<DeviceRecord> updateDeviceStatus({required String deviceId, required DeviceStatus status}) async {
    final response = await _http.patch(
      _uri('/vaults/$vaultId/devices/$deviceId'),
      headers: await _authHeaders(),
      body: jsonEncode({'status': status.name}),
    );
    _throwIfError(response);
    return _deviceRecordFromApiJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  // The REST API's device JSON already uses the same field names as
  // [DeviceRecord.fromJson] (device_id/public_key/status/platform), so this
  // just delegates — kept as its own function in case that ever drifts.
  DeviceRecord _deviceRecordFromApiJson(Map<String, dynamic> json) => DeviceRecord.fromJson(json);

  // ---------------------------------------------------------------------
  // Vault key / escrow.
  // ---------------------------------------------------------------------

  /// Throws [KavachStorageApiException] with `statusCode == 404` if nothing
  /// has been wrapped for this device at this epoch yet (i.e. not approved).
  Future<WrappedVaultKey> getWrappedVaultKey({required int epoch, required String deviceId}) async {
    final response = await _http.get(
      _uri('/vaults/$vaultId/keys/vault-key/$epoch/$deviceId'),
      headers: await _authHeaders(),
    );
    _throwIfError(response);
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return WrappedVaultKey(
      epoch: body['epoch'] as int,
      wrappedKey: base64Decode(body['wrapped_key'] as String),
      wrappedByDeviceId: body['wrapped_by_device_id'] as String,
    );
  }

  Future<void> putWrappedVaultKey({
    required int epoch,
    required String deviceId,
    required Uint8List wrapped,
  }) async {
    final response = await _http.put(
      _uri('/vaults/$vaultId/keys/vault-key/$epoch/$deviceId'),
      headers: await _authHeaders(),
      body: jsonEncode({'wrapped_key': base64Encode(wrapped)}),
    );
    _throwIfError(response);
  }

  /// Returns `null` if no escrow blob has been written for this epoch yet.
  Future<Uint8List?> getEscrowKey({required int epoch}) async {
    final response = await _http.get(_uri('/vaults/$vaultId/keys/escrow/$epoch'), headers: await _authHeaders());
    if (response.statusCode == 404) return null;
    _throwIfError(response);
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return base64Decode(body['wrapped_key'] as String);
  }

  Future<void> putEscrowKey({required int epoch, required Uint8List wrapped}) async {
    final response = await _http.put(
      _uri('/vaults/$vaultId/keys/escrow/$epoch'),
      headers: await _authHeaders(),
      body: jsonEncode({'wrapped_key': base64Encode(wrapped)}),
    );
    _throwIfError(response);
  }

  // ---------------------------------------------------------------------
  // Items — used by SyncEngine. Deletion is deliberately not exposed here:
  // Kavach represents a deleted item as a normal encrypted item with a
  // `deleted: true` flag *inside* the plaintext (see VaultRepository
  // .deleteItem), so sync only ever needs to read/write ciphertext, never
  // call the server's own DELETE — that stays a general-purpose REST
  // primitive the storage service exposes but this client doesn't need.
  // ---------------------------------------------------------------------

  Future<({List<RemoteItem> items, int latestRevision})> listItemsSince(int sinceRevision) async {
    final response = await _http.get(
      _uri('/vaults/$vaultId/items', {'since_revision': '$sinceRevision'}),
      headers: await _authHeaders(),
    );
    _throwIfError(response);
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final items = (body['items'] as List).cast<Map<String, dynamic>>().map(RemoteItem.fromJson).toList();
    return (items: items, latestRevision: (body['latest_revision'] as num).toInt());
  }

  /// Writes every item in [writes] atomically: either every one's
  /// `expected_version` still matches and all commit, or none do. On a
  /// conflict, returns the server's current copy of each mismatched item
  /// (via [BatchWriteOutcome.conflicts]) instead of throwing, so
  /// [SyncEngine] can fold them into its normal merge/retry loop exactly
  /// like a git non-fast-forward rejection used to.
  Future<BatchWriteOutcome> batchWrite(List<ItemWriteRequest> writes) async {
    final response = await _http.post(
      _uri('/vaults/$vaultId/items:batchWrite'),
      headers: await _authHeaders(),
      body: jsonEncode({'items': writes.map((w) => w.toJson()).toList()}),
    );
    if (response.statusCode == 409) {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final conflicts = (body['conflicts'] as List).cast<Map<String, dynamic>>().map(RemoteItem.fromJson).toList();
      return BatchWriteOutcome.conflict(conflicts);
    }
    _throwIfError(response);
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final items = (body['items'] as List).cast<Map<String, dynamic>>().map(RemoteItem.fromJson).toList();
    return BatchWriteOutcome.success(items: items, latestRevision: (body['latest_revision'] as num).toInt());
  }
}

class KavachStorageApiException implements Exception {
  KavachStorageApiException(this.statusCode, this.body);

  final int statusCode;
  final String body;

  @override
  String toString() => 'KavachStorageApiException($statusCode): $body';
}

class WrappedVaultKey {
  const WrappedVaultKey({required this.epoch, required this.wrappedKey, required this.wrappedByDeviceId});

  final int epoch;
  final Uint8List wrappedKey;
  final String wrappedByDeviceId;
}

/// One item row as the server sees it: sync metadata in the clear, content
/// opaque. Mirrors `openapi.yaml`'s `Item` schema.
class RemoteItem {
  const RemoteItem({
    required this.id,
    required this.version,
    required this.deleted,
    required this.updatedByDevice,
    required this.updatedAt,
    required this.revision,
    required this.ciphertext,
  });

  final String id;
  final int version;
  final bool deleted;
  final String updatedByDevice;
  final DateTime updatedAt;
  final int revision;

  /// Null only for a row tombstoned via the server's own DELETE endpoint —
  /// which, per the note on [KavachStorageClient], Kavach clients never call
  /// themselves. See [SyncEngine] for how a null here is handled defensively.
  final Uint8List? ciphertext;

  factory RemoteItem.fromJson(Map<String, dynamic> json) => RemoteItem(
        id: json['id'] as String,
        version: json['version'] as int,
        deleted: json['deleted'] as bool,
        updatedByDevice: json['updated_by_device'] as String,
        updatedAt: DateTime.parse(json['updated_at'] as String),
        revision: (json['revision'] as num).toInt(),
        ciphertext: json['ciphertext'] == null ? null : base64Decode(json['ciphertext'] as String),
      );
}

class ItemWriteRequest {
  const ItemWriteRequest({required this.id, required this.ciphertext, required this.expectedVersion});

  final String id;
  final Uint8List ciphertext;

  /// 0 means "create; must not already exist on the server".
  final int expectedVersion;

  Map<String, dynamic> toJson() => {
        'id': id,
        'ciphertext': base64Encode(ciphertext),
        'deleted': false,
        'expected_version': expectedVersion,
      };
}

/// Either every write in a batch committed ([items]/[latestRevision] set) or
/// none did ([conflicts] set) — never both.
class BatchWriteOutcome {
  const BatchWriteOutcome.success({required List<RemoteItem> items, required int latestRevision})
      : items = items,
        latestRevision = latestRevision,
        conflicts = null;

  const BatchWriteOutcome.conflict(List<RemoteItem> conflicts)
      : conflicts = conflicts,
        items = null,
        latestRevision = null;

  final List<RemoteItem>? items;
  final int? latestRevision;
  final List<RemoteItem>? conflicts;

  bool get isConflict => conflicts != null;
}
