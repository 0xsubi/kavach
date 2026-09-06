import 'dart:convert';

import 'package:kavach/data/biometric_authenticator.dart';
import 'package:kavach/data/vault_repository.dart';
import 'package:kavach/main.dart';
import 'package:kavach/state/vault_controller.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kavach_core/kavach_core.dart';
import 'package:kavach_core_storage_native/kavach_core_storage_native.dart';
import 'package:sodium_libs/sodium_libs_sumo.dart';

class _FakeSecureKeyStore implements SecureKeyStore {
  final Map<String, String> _values = {};

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> delete(String key) async => _values.remove(key);

  @override
  Future<void> deleteAll() async => _values.clear();
}

/// Reports biometrics as unavailable, so `UnlockScreen`'s quick-unlock
/// falls straight through to the cached-vault-key path instead of showing
/// a real system Touch ID/password prompt during this automated test.
class _FakeBiometricAuthenticator implements BiometricAuthenticator {
  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<bool> authenticate() async => true;
}

/// Same in-memory kavach-storage REST API stand-in as storage_sync_test.dart,
/// shared by both simulated devices in this test since they talk to the same
/// vault. Additionally supports invite tokens and device listing/approval,
/// which storage_sync_test.dart's single-device flow never exercises.
class _FakeStorageServer {
  static const adminToken = 'admin-test-token';

  String? vaultId;
  String? _bootstrapToken;
  bool _bootstrapUsed = false;
  int _inviteCounter = 0;
  final Map<String, String> _inviteTokenOwner = {}; // token -> creator device id
  final Map<String, String> _deviceTokenToId = {};
  final Map<String, Map<String, dynamic>> _devices = {};
  final Map<String, Map<String, dynamic>> _vaultKeys = {};
  final Map<String, Map<String, dynamic>> _items = {};
  int _revision = 0;

  String? _token(http.Request r) {
    final h = r.headers['authorization'];
    return (h != null && h.startsWith('Bearer ')) ? h.substring(7) : null;
  }

  Future<http.Response> handle(http.Request request) async {
    final path = request.url.path;
    final method = request.method;
    final token = _token(request);

    if (method == 'POST' && path == '/v1/vaults') {
      if (token != adminToken) return http.Response('', 401);
      vaultId = 'vault-1';
      _bootstrapToken = 'bootstrap-token-1';
      return http.Response(jsonEncode({'vault_id': vaultId, 'bootstrap_token': _bootstrapToken}), 201);
    }

    if (method == 'POST' && path == '/v1/vaults/$vaultId/devices/invites') {
      final callerId = _deviceTokenToId[token];
      if (callerId == null || _devices[callerId]!['status'] != 'approved') return http.Response('', 403);
      final invite = 'invite-token-${_inviteCounter++}';
      _inviteTokenOwner[invite] = callerId;
      return http.Response(
        jsonEncode({'invite_token': invite, 'expires_at': DateTime.now().toUtc().add(const Duration(minutes: 15)).toIso8601String()}),
        201,
      );
    }

    if (method == 'POST' && path == '/v1/vaults/$vaultId/devices') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final deviceId = body['device_id'] as String;
      String status;
      if (token == _bootstrapToken && !_bootstrapUsed) {
        _bootstrapUsed = true;
        status = 'approved';
      } else if (_inviteTokenOwner.remove(token) != null) {
        status = 'pending';
      } else {
        return http.Response('', 401);
      }
      final deviceToken = 'device-token-$deviceId';
      _devices[deviceId] = {
        'device_id': deviceId,
        'public_key': body['public_key'],
        'status': status,
        'platform': body['platform'],
      };
      _deviceTokenToId[deviceToken] = deviceId;
      return http.Response(jsonEncode({..._devices[deviceId]!, 'device_token': deviceToken}), 201);
    }

    if (method == 'GET' && path == '/v1/vaults/$vaultId/devices') {
      if (_deviceTokenToId[token] == null) return http.Response('', 401);
      return http.Response(jsonEncode({'devices': _devices.values.toList()}), 200);
    }

    final deviceIdMatch = RegExp(r'^/v1/vaults/[^/]+/devices/([^/]+)$').firstMatch(path);
    if (deviceIdMatch != null) {
      final targetId = deviceIdMatch.group(1)!;
      final callerId = _deviceTokenToId[token];
      if (callerId == null) return http.Response('', 401);
      if (method == 'GET') {
        final d = _devices[targetId];
        return d == null ? http.Response('', 404) : http.Response(jsonEncode(d), 200);
      }
      if (method == 'PATCH') {
        if (_devices[callerId]!['status'] != 'approved') return http.Response('', 403);
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        _devices[targetId]!['status'] = body['status'];
        return http.Response(jsonEncode(_devices[targetId]), 200);
      }
    }

    final keyMatch = RegExp(r'^/v1/vaults/[^/]+/keys/vault-key/(\d+)/([^/]+)$').firstMatch(path);
    if (keyMatch != null) {
      final epoch = keyMatch.group(1)!;
      final targetDeviceId = keyMatch.group(2)!;
      final callerId = _deviceTokenToId[token];
      if (callerId == null) return http.Response('', 401);
      final key = '$epoch:$targetDeviceId';
      if (method == 'GET') {
        if (callerId != targetDeviceId) return http.Response('', 403);
        final entry = _vaultKeys[key];
        if (entry == null) return http.Response('', 404);
        return http.Response(
          jsonEncode({'epoch': int.parse(epoch), 'wrapped_key': entry['wrapped_key'], 'wrapped_by_device_id': entry['wrapped_by_device_id']}),
          200,
        );
      }
      if (method == 'PUT') {
        if (_devices[callerId]!['status'] != 'approved') return http.Response('', 403);
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        _vaultKeys[key] = {'wrapped_key': body['wrapped_key'], 'wrapped_by_device_id': callerId};
        return http.Response(
          jsonEncode({'epoch': int.parse(epoch), 'wrapped_key': body['wrapped_key'], 'wrapped_by_device_id': callerId}),
          200,
        );
      }
    }

    final escrowMatch = RegExp(r'^/v1/vaults/[^/]+/keys/escrow/(\d+)$').firstMatch(path);
    if (escrowMatch != null && method == 'PUT') {
      if (_deviceTokenToId[token] == null) return http.Response('', 401);
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(jsonEncode({'epoch': int.parse(escrowMatch.group(1)!), 'wrapped_key': body['wrapped_key']}), 200);
    }

    if (method == 'GET' && path == '/v1/vaults/$vaultId/items') {
      final callerId = _deviceTokenToId[token];
      if (callerId == null || _devices[callerId]!['status'] != 'approved') return http.Response('', 403);
      final since = int.parse(request.url.queryParameters['since_revision'] ?? '0');
      final changed = _items.values.where((it) => (it['revision'] as int) > since).toList();
      return http.Response(jsonEncode({'items': changed, 'latest_revision': _revision}), 200);
    }

    if (method == 'POST' && path == '/v1/vaults/$vaultId/items:batchWrite') {
      final callerId = _deviceTokenToId[token];
      if (callerId == null || _devices[callerId]!['status'] != 'approved') return http.Response('', 403);
      final writes = ((jsonDecode(request.body) as Map<String, dynamic>)['items'] as List).cast<Map<String, dynamic>>();
      final result = <Map<String, dynamic>>[];
      for (final w in writes) {
        _revision++;
        final row = {
          'id': w['id'],
          'version': ((_items[w['id']]?['version'] as int?) ?? 0) + 1,
          'deleted': w['deleted'] ?? false,
          'updated_by_device': callerId,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
          'revision': _revision,
          'ciphertext': w['ciphertext'],
        };
        _items[w['id'] as String] = row;
        result.add(row);
      }
      return http.Response(jsonEncode({'items': result, 'latest_revision': _revision}), 200);
    }

    throw StateError('Unexpected request: $method $path');
  }
}

/// Simulates two physically separate devices (each with its own secure
/// store and local cache) talking to the same remote vault. Split into four
/// sequential [testWidgets] cases — each doing exactly one
/// [WidgetTester.pumpWidget] call, the same pattern every other integration
/// test in this suite uses — rather than one long test that calls
/// `pumpWidget` repeatedly to simulate each device "session": driving
/// multiple full app restarts through repeated `pumpWidget` calls within a
/// single `testWidgets` body proved unreliable under
/// `IntegrationTestWidgetsFlutterBinding` (the app got stuck on a stale
/// screen after the second `pumpWidget`). Fixtures are shared via top-level
/// `late` variables set up once in [setUpAll], since `flutter test` runs
/// every `testWidgets` in a file sequentially in the same process.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late SodiumSumo sodium;
  late _FakeStorageServer server;
  late _FakeSecureKeyStore secureStoreA;
  late LocalVaultCacheNative cacheA;
  late _FakeSecureKeyStore secureStoreB;
  late LocalVaultCacheNative cacheB;
  late VaultRepository repoA; // kept across steps 1 and "mint an invite" below
  late String vaultIdForB;
  late String inviteTokenForB;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
    server = _FakeStorageServer();
    secureStoreA = _FakeSecureKeyStore();
    cacheA = LocalVaultCacheNative(VaultDatabase(NativeDatabase.memory()));
    secureStoreB = _FakeSecureKeyStore();
    cacheB = LocalVaultCacheNative(VaultDatabase(NativeDatabase.memory()));
  });

  testWidgets('1. device A creates the vault, initializes it, and mints an invite', (tester) async {
    repoA = VaultRepository(
      secureStore: secureStoreA,
      cache: cacheA,
      sodium: sodium,
      storageHttpClient: MockClient(server.handle),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          vaultRepositoryProvider.overrideWithValue(repoA),
          biometricAuthenticatorProvider.overrideWithValue(_FakeBiometricAuthenticator()),
        ],
        child: const KavachApp(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).at(0), 'correct horse battery staple');
    await tester.enterText(find.byType(TextField).at(1), 'correct horse battery staple');
    await tester.ensureVisible(find.text('create vault'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('create vault'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    final settingsFields = find.byType(TextField);
    await tester.enterText(settingsFields.at(0), 'https://kavach-storage.test');
    await tester.enterText(settingsFields.at(1), _FakeStorageServer.adminToken);
    await tester.ensureVisible(find.text('create vault & sync'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('create vault & sync'));
    await tester.pumpAndSettle();
    expect(find.textContaining('sync failed'), findsNothing);

    // Minting the invite through repoA directly (rather than driving the
    // "invite a device" dialog) — that dialog is plain, low-risk Flutter
    // widgetry; what actually needs coverage here is the invite token
    // making a real round trip through the server into device B's join.
    final target = await repoA.storageTarget();
    vaultIdForB = target!.vaultId;
    final invite = await repoA.createDeviceInvite();
    inviteTokenForB = invite.inviteToken;
  });

  testWidgets('2. device B joins with the invite and is not yet approved', (tester) async {
    final repoB = VaultRepository(
      secureStore: secureStoreB,
      cache: cacheB,
      sodium: sodium,
      storageHttpClient: MockClient(server.handle),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          vaultRepositoryProvider.overrideWithValue(repoB),
          biometricAuthenticatorProvider.overrideWithValue(_FakeBiometricAuthenticator()),
        ],
        child: const KavachApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('create your vault'), findsOneWidget);
    await tester.tap(find.textContaining('already have a vault'));
    await tester.pumpAndSettle();
    expect(find.text('join a vault'), findsOneWidget);

    final joinFields = find.byType(TextField);
    await tester.enterText(joinFields.at(0), 'https://kavach-storage.test');
    await tester.enterText(joinFields.at(1), vaultIdForB);
    await tester.enterText(joinFields.at(2), inviteTokenForB);
    await tester.ensureVisible(find.text('request to join'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('request to join'));
    await tester.pumpAndSettle();

    expect(find.text('waiting for approval'), findsOneWidget);

    await tester.tap(find.text('check now'));
    await tester.pumpAndSettle();
    expect(find.text('not approved yet.'), findsOneWidget);
  });

  testWidgets('3. device A (reopened) approves device B', (tester) async {
    final repoA2 = VaultRepository(
      secureStore: secureStoreA,
      cache: cacheA,
      sodium: sodium,
      storageHttpClient: MockClient(server.handle),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          vaultRepositoryProvider.overrideWithValue(repoA2),
          biometricAuthenticatorProvider.overrideWithValue(_FakeBiometricAuthenticator()),
        ],
        child: const KavachApp(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('devices'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('devices'));
    await tester.pumpAndSettle();

    expect(find.text('approve'), findsOneWidget);
    await tester.tap(find.text('approve'));
    await tester.pumpAndSettle();
    expect(find.text('approve'), findsNothing);
  });

  testWidgets('4. device B checks again and unlocks', (tester) async {
    final repoB2 = VaultRepository(
      secureStore: secureStoreB,
      cache: cacheB,
      sodium: sodium,
      storageHttpClient: MockClient(server.handle),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          vaultRepositoryProvider.overrideWithValue(repoB2),
          biometricAuthenticatorProvider.overrideWithValue(_FakeBiometricAuthenticator()),
        ],
        child: const KavachApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('waiting for approval'), findsOneWidget);
    await tester.tap(find.text('check now'));
    await tester.pumpAndSettle();

    expect(find.text('no items yet.\ntap + to add your first password.'), findsOneWidget);
  });
}
