import 'dart:convert';

import 'package:desktop_mobile/data/biometric_authenticator.dart';
import 'package:desktop_mobile/data/vault_repository.dart';
import 'package:desktop_mobile/main.dart';
import 'package:desktop_mobile/state/vault_controller.dart';
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

/// Same in-memory Git Data API stand-in as github_sync_test.dart, shared by
/// both simulated devices in this test since they talk to the same repo.
class _FakeGitHubServer {
  String? refSha;
  final Map<String, List<int>> _blobs = {};
  final Map<String, Map<String, Map<String, dynamic>>> _trees = {};
  final Map<String, Map<String, dynamic>> _commits = {};
  int _counter = 0;

  String _nextSha(String prefix) => '$prefix-${_counter++}';

  Future<http.Response> handle(http.Request request) async {
    final path = request.url.path;
    final method = request.method;

    if (method == 'GET' && path.endsWith('git/ref/heads/main')) {
      if (refSha == null) return http.Response('', 404);
      return http.Response(
        jsonEncode({
          'object': {'sha': refSha},
        }),
        200,
      );
    }
    if (method == 'GET' && RegExp(r'git/commits/[^/]+$').hasMatch(path)) {
      final sha = path.split('/').last;
      return http.Response(
        jsonEncode({
          'tree': {'sha': _commits[sha]!['tree']},
        }),
        200,
      );
    }
    if (method == 'GET' && path.contains('git/trees/')) {
      final sha = path.split('/').last;
      return http.Response(jsonEncode({'tree': _trees[sha]!.values.toList()}), 200);
    }
    if (method == 'GET' && path.contains('git/blobs/')) {
      final sha = path.split('/').last;
      return http.Response(
        jsonEncode({'content': base64Encode(_blobs[sha]!), 'encoding': 'base64'}),
        200,
      );
    }
    if (method == 'POST' && path.endsWith('git/blobs')) {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final sha = _nextSha('blob');
      _blobs[sha] = base64Decode(body['content'] as String);
      return http.Response(jsonEncode({'sha': sha}), 201);
    }
    if (method == 'POST' && path.endsWith('git/trees')) {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final baseTreeSha = body['base_tree'] as String?;
      final merged = <String, Map<String, dynamic>>{
        if (baseTreeSha != null) ..._trees[baseTreeSha]!,
      };
      for (final raw in (body['tree'] as List).cast<Map<String, dynamic>>()) {
        merged[raw['path'] as String] = raw;
      }
      final sha = _nextSha('tree');
      _trees[sha] = merged;
      return http.Response(jsonEncode({'sha': sha}), 201);
    }
    if (method == 'POST' && path.endsWith('git/commits')) {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final sha = _nextSha('commit');
      _commits[sha] = {'tree': body['tree'], 'parents': body['parents']};
      return http.Response(jsonEncode({'sha': sha}), 201);
    }
    if (method == 'POST' && path.endsWith('git/refs')) {
      refSha = (jsonDecode(request.body) as Map<String, dynamic>)['sha'] as String;
      return http.Response('', 201);
    }
    if (method == 'PATCH' && path.endsWith('git/refs/heads/main')) {
      refSha = (jsonDecode(request.body) as Map<String, dynamic>)['sha'] as String;
      return http.Response(
        jsonEncode({
          'object': {'sha': refSha},
        }),
        200,
      );
    }
    throw StateError('Unexpected request: $method $path');
  }
}

/// Simulates two physically separate devices (each with its own secure
/// store and local cache) talking to the same remote vault repo. Split into
/// four sequential [testWidgets] cases — each doing exactly one
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
  late _FakeGitHubServer server;
  late _FakeSecureKeyStore secureStoreA;
  late LocalVaultCacheNative cacheA;
  late _FakeSecureKeyStore secureStoreB;
  late LocalVaultCacheNative cacheB;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
    server = _FakeGitHubServer();
    secureStoreA = _FakeSecureKeyStore();
    cacheA = LocalVaultCacheNative(VaultDatabase(NativeDatabase.memory()));
    secureStoreB = _FakeSecureKeyStore();
    cacheB = LocalVaultCacheNative(VaultDatabase(NativeDatabase.memory()));
  });

  testWidgets('1. device A creates the vault and initializes the remote repo', (tester) async {
    final repoA = VaultRepository(
      secureStore: secureStoreA,
      cache: cacheA,
      sodium: sodium,
      githubHttpClient: MockClient(server.handle),
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
    await tester.enterText(settingsFields.at(0), 'sudhabindu1');
    await tester.enterText(settingsFields.at(1), 'kavach-vault');
    await tester.enterText(settingsFields.at(2), 'ghp_test_token');
    await tester.ensureVisible(find.text('save & sync now'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('save & sync now'));
    await tester.pumpAndSettle();
    expect(find.textContaining('sync failed'), findsNothing);
  });

  testWidgets('2. device B requests to join and is not yet approved', (tester) async {
    final repoB = VaultRepository(
      secureStore: secureStoreB,
      cache: cacheB,
      sodium: sodium,
      githubHttpClient: MockClient(server.handle),
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
    await tester.enterText(joinFields.at(0), 'sudhabindu1');
    await tester.enterText(joinFields.at(1), 'kavach-vault');
    await tester.enterText(joinFields.at(2), 'ghp_test_token');
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
      githubHttpClient: MockClient(server.handle),
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
      githubHttpClient: MockClient(server.handle),
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
