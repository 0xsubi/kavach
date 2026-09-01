import 'dart:convert';

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

/// A minimal but stateful in-memory stand-in for GitHub's Git Data API, so
/// this test exercises the real [GitHubClient]/[SyncEngine]/
/// [VaultProvisioning] code against realistic request/response shapes
/// without needing a live GitHub repo + PAT.
class _FakeGitHubServer {
  String? refSha;
  final Map<String, List<int>> _blobs = {};
  final Map<String, Map<String, Map<String, dynamic>>> _trees = {}; // treeSha -> path -> entry
  final Map<String, Map<String, dynamic>> _commits = {}; // commitSha -> {tree, parents}
  int _counter = 0;
  int commitCount = 0;

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
      final commit = _commits[sha]!;
      return http.Response(
        jsonEncode({
          'tree': {'sha': commit['tree']},
        }),
        200,
      );
    }

    if (method == 'GET' && path.contains('git/trees/')) {
      final sha = path.split('/').last;
      final tree = _trees[sha]!;
      return http.Response(
        jsonEncode({
          'tree': tree.values.toList(),
        }),
        200,
      );
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
      final bytes = base64Decode((body['content'] as String));
      final sha = _nextSha('blob');
      _blobs[sha] = bytes;
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
      commitCount++;
      return http.Response(jsonEncode({'sha': sha}), 201);
    }

    if (method == 'POST' && path.endsWith('git/refs')) {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      refSha = body['sha'] as String;
      return http.Response('', 201);
    }

    if (method == 'PATCH' && path.endsWith('git/refs/heads/main')) {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      refSha = body['sha'] as String;
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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('configure GitHub sync and push a password item to a fresh repo', (tester) async {
    final sodium = await SodiumSumoInit.init();
    final database = VaultDatabase(NativeDatabase.memory());
    final server = _FakeGitHubServer();
    final repository = VaultRepository(
      secureStore: _FakeSecureKeyStore(),
      cache: LocalVaultCacheNative(database),
      sodium: sodium,
      githubHttpClient: MockClient(server.handle),
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
    await tester.ensureVisible(find.text('Create vault'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create vault'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    final itemFields = find.byType(TextField);
    await tester.enterText(itemFields.at(0), 'GitHub');
    await tester.enterText(itemFields.at(1), 'sudhabindu1@gmail.com');
    await tester.enterText(itemFields.at(2), 's3cr3t-p@ssw0rd');
    await tester.ensureVisible(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    expect(find.text('GitHub sync'), findsOneWidget);

    final settingsFields = find.byType(TextField);
    await tester.enterText(settingsFields.at(0), 'sudhabindu1');
    await tester.enterText(settingsFields.at(1), 'kavach-vault');
    await tester.enterText(settingsFields.at(2), 'ghp_test_token');
    await tester.ensureVisible(find.text('Save & sync now'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save & sync now'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Sync failed'), findsNothing);
    expect(find.textContaining('1 pushed'), findsOneWidget);

    // Two commits: VaultProvisioning's initial `.kavach/` scaffolding commit,
    // then SyncEngine's commit pushing the one dirty password item.
    expect(server.commitCount, 2);
    expect(server.refSha, isNotNull);

    // A second, independent sync (as "Sync Now" would do on a later app
    // start) should be a clean no-op: nothing new to push, nothing to pull.
    final commitsBeforeSecondSync = server.commitCount;
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.sync));
    await tester.pumpAndSettle();
    expect(server.commitCount, commitsBeforeSecondSync);
  });
}
