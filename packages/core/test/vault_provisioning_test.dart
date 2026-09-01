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

  test('ensureInitialized is a no-op when the repo already has a HEAD', () async {
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
      anyWriteCalled = true;
      throw StateError('Should not write when the repo is already initialized');
    });

    final provisioning = VaultProvisioning(_clientWith(mock));
    final commitSha = await provisioning.ensureInitialized({
      RepoPaths.manifest: utf8.encode('{"format_version":1}'),
    });

    expect(commitSha, 'existing-head-sha');
    expect(anyWriteCalled, isFalse);
  });
}
