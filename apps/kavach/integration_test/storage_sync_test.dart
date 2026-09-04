import 'dart:convert';

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

/// A minimal but stateful in-memory stand-in for `kavach-storage`'s REST
/// API (see `kavach-storage/openapi.yaml`), so this test exercises the real
/// [KavachStorageClient]/[SyncEngine] code against realistic request/
/// response shapes without needing a live Postgres-backed server.
class _FakeStorageServer {
  static const adminToken = 'admin-test-token';

  String? vaultId;
  String? _bootstrapToken;
  bool _bootstrapUsed = false;
  final Map<String, String> _deviceTokenToId = {};
  final Map<String, Map<String, dynamic>> _devices = {};
  final Map<String, Map<String, dynamic>> _vaultKeys = {}; // "epoch:deviceId" -> {...}
  final Map<String, Map<String, dynamic>> _items = {};
  int _revision = 0;
  int batchWriteCount = 0;

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

    if (method == 'POST' && path == '/v1/vaults/$vaultId/devices') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final deviceId = body['device_id'] as String;
      String status;
      if (token == _bootstrapToken && !_bootstrapUsed) {
        _bootstrapUsed = true;
        status = 'approved';
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

    final keyMatch = RegExp(r'^/v1/vaults/[^/]+/keys/vault-key/(\d+)/([^/]+)$').firstMatch(path);
    if (keyMatch != null && method == 'PUT') {
      final callerId = _deviceTokenToId[token];
      if (callerId == null || _devices[callerId]!['status'] != 'approved') return http.Response('', 403);
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final key = '${keyMatch.group(1)}:${keyMatch.group(2)}';
      _vaultKeys[key] = {'wrapped_key': body['wrapped_key'], 'wrapped_by_device_id': callerId};
      return http.Response(
        jsonEncode({'epoch': int.parse(keyMatch.group(1)!), 'wrapped_key': body['wrapped_key'], 'wrapped_by_device_id': callerId}),
        200,
      );
    }

    final escrowMatch = RegExp(r'^/v1/vaults/[^/]+/keys/escrow/(\d+)$').firstMatch(path);
    if (escrowMatch != null && method == 'PUT') {
      final callerId = _deviceTokenToId[token];
      if (callerId == null) return http.Response('', 401);
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
      batchWriteCount++;
      final writes = ((jsonDecode(request.body) as Map<String, dynamic>)['items'] as List).cast<Map<String, dynamic>>();

      for (final w in writes) {
        final currentVersion = (_items[w['id']]?['version'] as int?) ?? 0;
        if (currentVersion != w['expected_version']) {
          return http.Response(jsonEncode({'conflicts': writes.map((w2) => _items[w2['id']] ?? _zeroItem(w2['id'] as String)).toList()}), 409);
        }
      }
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

  Map<String, dynamic> _zeroItem(String id) => {
        'id': id,
        'version': 0,
        'deleted': false,
        'updated_by_device': '',
        'updated_at': DateTime.now().toUtc().toIso8601String(),
        'revision': 0,
        'ciphertext': null,
      };
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('create a vault on kavach-storage and push a password item', (tester) async {
    final sodium = await SodiumSumoInit.init();
    final database = VaultDatabase(NativeDatabase.memory());
    final server = _FakeStorageServer();
    final repository = VaultRepository(
      secureStore: _FakeSecureKeyStore(),
      cache: LocalVaultCacheNative(database),
      sodium: sodium,
      storageHttpClient: MockClient(server.handle),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [vaultRepositoryProvider.overrideWithValue(repository)],
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

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    final itemFields = find.byType(TextField);
    await tester.enterText(itemFields.at(0), 'GitHub');
    await tester.enterText(itemFields.at(1), 'sudhabindu1@gmail.com');
    await tester.enterText(itemFields.at(2), 's3cr3t-p@ssw0rd');
    await tester.ensureVisible(find.text('save'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('save'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    expect(find.text('kavach-storage sync'), findsOneWidget);

    final settingsFields = find.byType(TextField);
    await tester.enterText(settingsFields.at(0), 'https://kavach-storage.test');
    await tester.enterText(settingsFields.at(1), _FakeStorageServer.adminToken);
    await tester.ensureVisible(find.text('create vault & sync'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('create vault & sync'));
    await tester.pumpAndSettle();

    expect(find.textContaining('sync failed'), findsNothing);
    expect(find.textContaining('1 pushed'), findsOneWidget);

    // One vault-key PUT (self-approval), one escrow PUT, and exactly one
    // batch write for the single dirty password item.
    expect(server.batchWriteCount, 1);

    // A second, independent sync (as "Sync Now" would do on a later app
    // start) should be a clean no-op: nothing new to push, nothing to pull.
    final batchWritesBeforeSecondSync = server.batchWriteCount;
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.sync));
    await tester.pumpAndSettle();
    expect(server.batchWriteCount, batchWritesBeforeSecondSync);
  });
}
