import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kavach_core/kavach_core.dart';
import 'package:test/test.dart';

GitHubClient _clientWith(http.Client httpClient) => GitHubClient(
      owner: 'sudhabindu1',
      repo: 'kavach-vault',
      auth: PatAuthenticator(() async => 'test-token'),
      httpClient: httpClient,
    );

void main() {
  test('ensureInitialized creates one commit from scratch on an empty repo', () async {
    var blobCalls = 0;
    var sawBaseTreeKey = true;
    var refPosted = false;

    final mock = MockClient((request) async {
      final path = request.url.path;
      if (path.endsWith('git/ref/heads/main')) {
        return http.Response('', 404);
      }
      if (path.endsWith('git/blobs') && request.method == 'POST') {
        blobCalls++;
        return http.Response(jsonEncode({'sha': 'blob-sha-$blobCalls'}), 201);
      }
      if (path.endsWith('git/trees') && request.method == 'POST') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        sawBaseTreeKey = body.containsKey('base_tree');
        return http.Response(jsonEncode({'sha': 'tree-sha'}), 201);
      }
      if (path.endsWith('git/commits') && request.method == 'POST') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['parents'], isEmpty);
        return http.Response(jsonEncode({'sha': 'commit-sha'}), 201);
      }
      if (path.endsWith('git/refs') && request.method == 'POST') {
        refPosted = true;
        return http.Response('', 201);
      }
      throw StateError('Unexpected request: ${request.method} $path');
    });

    final provisioning = VaultProvisioning(_clientWith(mock));
    final commitSha = await provisioning.ensureInitialized({
      RepoPaths.manifest: utf8.encode('{"format_version":1}'),
      RepoPaths.device('device-1'): utf8.encode('{"status":"approved"}'),
    });

    expect(commitSha, 'commit-sha');
    expect(blobCalls, 2);
    expect(sawBaseTreeKey, isFalse);
    expect(refPosted, isTrue);
  });

  test('ensureInitialized is a no-op once the manifest is already present', () async {
    var anyWriteCalled = false;

    final mock = MockClient((request) async {
      final path = request.url.path;
      if (path.endsWith('git/ref/heads/main')) {
        return http.Response(
          jsonEncode({
            'object': {'sha': 'existing-head-sha'},
          }),
          200,
        );
      }
      if (path.endsWith('git/commits/existing-head-sha')) {
        return http.Response(
          jsonEncode({
            'tree': {'sha': 'existing-tree-sha'},
          }),
          200,
        );
      }
      if (path.contains('git/trees/existing-tree-sha')) {
        return http.Response(
          jsonEncode({
            'tree': [
              {'path': RepoPaths.manifest, 'mode': '100644', 'type': 'blob', 'sha': 'manifest-blob'},
            ],
          }),
          200,
        );
      }
      anyWriteCalled = true;
      throw StateError('Should not write once the manifest already exists');
    });

    final provisioning = VaultProvisioning(_clientWith(mock));
    final commitSha = await provisioning.ensureInitialized({
      RepoPaths.manifest: utf8.encode('{"format_version":1}'),
    });

    expect(commitSha, 'existing-head-sha');
    expect(anyWriteCalled, isFalse);
  });

  test('ensureInitialized adds scaffolding on top of a repo with unrelated pre-existing commits', () async {
    var blobCalls = 0;
    String? sawBaseTree;
    List<String>? sawParents;
    var refPatched = false;

    final mock = MockClient((request) async {
      final path = request.url.path;
      if (path.endsWith('git/ref/heads/main') && request.method == 'GET') {
        return http.Response(
          jsonEncode({
            'object': {'sha': 'readme-only-head-sha'},
          }),
          200,
        );
      }
      if (path.endsWith('git/commits/readme-only-head-sha')) {
        return http.Response(
          jsonEncode({
            'tree': {'sha': 'readme-only-tree-sha'},
          }),
          200,
        );
      }
      if (path.contains('git/trees/readme-only-tree-sha')) {
        return http.Response(
          jsonEncode({
            'tree': [
              {'path': 'README.md', 'mode': '100644', 'type': 'blob', 'sha': 'readme-blob'},
            ],
          }),
          200,
        );
      }
      if (path.endsWith('git/blobs') && request.method == 'POST') {
        blobCalls++;
        return http.Response(jsonEncode({'sha': 'blob-sha-$blobCalls'}), 201);
      }
      if (path.endsWith('git/trees') && request.method == 'POST') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        sawBaseTree = body['base_tree'] as String?;
        return http.Response(jsonEncode({'sha': 'new-tree-sha'}), 201);
      }
      if (path.endsWith('git/commits') && request.method == 'POST') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        sawParents = (body['parents'] as List).cast<String>();
        return http.Response(jsonEncode({'sha': 'new-commit-sha'}), 201);
      }
      if (path.endsWith('git/refs/heads/main') && request.method == 'PATCH') {
        refPatched = true;
        return http.Response(
          jsonEncode({
            'object': {'sha': 'new-commit-sha'},
          }),
          200,
        );
      }
      throw StateError('Unexpected request: ${request.method} $path');
    });

    final provisioning = VaultProvisioning(_clientWith(mock));
    final commitSha = await provisioning.ensureInitialized({
      RepoPaths.manifest: utf8.encode('{"format_version":1}'),
      RepoPaths.device('device-1'): utf8.encode('{"status":"approved"}'),
    });

    expect(commitSha, 'new-commit-sha');
    expect(blobCalls, 2);
    expect(sawBaseTree, 'readme-only-tree-sha');
    expect(sawParents, ['readme-only-head-sha']);
    expect(refPatched, isTrue);
  });
}
