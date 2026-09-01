import 'dart:convert';

import 'package:http/http.dart' as http;

import '../github_auth/github_auth.dart';

/// A single entry in a Git tree, as returned by / sent to the Git Data API.
class GitTreeEntry {
  const GitTreeEntry({
    required this.path,
    required this.mode,
    required this.type,
    this.sha,
    this.content,
  });

  final String path;

  /// `100644` for a normal file (the only mode Kavach ever writes).
  final String mode;

  /// `blob`, `tree`, or `commit`.
  final String type;

  /// The blob/tree SHA. Present on entries read from GitHub; may be omitted
  /// on write when [content] is supplied instead (GitHub creates the blob).
  final String? sha;

  /// Raw content for a new blob entry, base64-free (GitHub Contents-less
  /// tree-creation API accepts inline `content` and creates the blob for
  /// you — avoids a separate create-blob round trip per file).
  final String? content;

  factory GitTreeEntry.fromJson(Map<String, dynamic> json) => GitTreeEntry(
        path: json['path'] as String,
        mode: json['mode'] as String,
        type: json['type'] as String,
        sha: json['sha'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'path': path,
        'mode': mode,
        'type': type,
        if (sha != null) 'sha': sha,
        if (content != null) 'content': content,
      };
}

/// Thin client over GitHub's low-level Git Data API (blobs/trees/commits/
/// refs), chosen over the Contents API and over shelling out to a `git`
/// binary per plan §4: the Contents API can't batch multiple file changes
/// into one atomic commit, and Flutter/a browser extension has no embedded
/// git to shell out to anyway.
class GitHubClient {
  GitHubClient({
    required this.owner,
    required this.repo,
    required this.auth,
    http.Client? httpClient,
    this.branch = 'main',
  }) : _http = httpClient ?? http.Client();

  final String owner;
  final String repo;
  final String branch;
  final GitHubAuthenticator auth;
  final http.Client _http;

  Uri _api(String path) => Uri.parse('https://api.github.com/repos/$owner/$repo/$path');

  Future<Map<String, String>> _headers() async {
    final session = await auth.currentSession();
    return {
      'Authorization': 'Bearer ${session.token}',
      'Accept': 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
    };
  }

  /// The commit SHA that `refs/heads/<branch>` currently points at, or
  /// `null` if the repo/branch is empty (brand-new repo, no commits yet).
  Future<String?> getHeadCommitSha() async {
    final response = await _http.get(
      _api('git/ref/heads/$branch'),
      headers: await _headers(),
    );
    if (response.statusCode == 404) return null;
    _throwIfError(response);
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['object'] as Map<String, dynamic>)['sha'] as String;
  }

  Future<String> getCommitTreeSha(String commitSha) async {
    final response = await _http.get(_api('git/commits/$commitSha'), headers: await _headers());
    _throwIfError(response);
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['tree'] as Map<String, dynamic>)['sha'] as String;
  }

  /// The full recursive tree, path -> entry, for diffing against the local
  /// blob-sha cache (plan §4 step 2).
  Future<List<GitTreeEntry>> getTreeRecursive(String treeSha) async {
    final response = await _http.get(
      _api('git/trees/$treeSha').replace(queryParameters: const {'recursive': '1'}),
      headers: await _headers(),
    );
    _throwIfError(response);
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final entries = (body['tree'] as List).cast<Map<String, dynamic>>();
    return entries.where((e) => e['type'] == 'blob').map(GitTreeEntry.fromJson).toList();
  }

  Future<List<int>> getBlobBytes(String blobSha) async {
    final response = await _http.get(_api('git/blobs/$blobSha'), headers: await _headers());
    _throwIfError(response);
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final encoding = body['content'] as String;
    return base64.decode(encoding.replaceAll('\n', ''));
  }

  Future<String> createBlob(List<int> bytes) async {
    final response = await _http.post(
      _api('git/blobs'),
      headers: await _headers(),
      body: jsonEncode({'content': base64Encode(bytes), 'encoding': 'base64'}),
    );
    _throwIfError(response);
    return (jsonDecode(response.body) as Map<String, dynamic>)['sha'] as String;
  }

  /// Builds a new tree on top of [baseTreeSha] with [entries] applied. Pass
  /// a `sha` of `null` on an entry to delete that path. Omit [baseTreeSha]
  /// (or pass `null`) to build a brand-new tree from scratch, as needed for
  /// a repo's very first commit.
  Future<String> createTree(List<GitTreeEntry> entries, {String? baseTreeSha}) async {
    final response = await _http.post(
      _api('git/trees'),
      headers: await _headers(),
      body: jsonEncode({
        if (baseTreeSha != null) 'base_tree': baseTreeSha,
        'tree': entries.map((e) => e.toJson()).toList(),
      }),
    );
    _throwIfError(response);
    return (jsonDecode(response.body) as Map<String, dynamic>)['sha'] as String;
  }

  Future<String> createCommit({
    required String message,
    required String treeSha,
    required List<String> parentShas,
  }) async {
    final response = await _http.post(
      _api('git/commits'),
      headers: await _headers(),
      body: jsonEncode({'message': message, 'tree': treeSha, 'parents': parentShas}),
    );
    _throwIfError(response);
    return (jsonDecode(response.body) as Map<String, dynamic>)['sha'] as String;
  }

  /// Fast-forward-only ref update. Returns `false` (instead of throwing) on
  /// a 422/409 non-fast-forward rejection, so [SyncEngine] can treat a
  /// concurrent-write race as "re-fetch and retry" rather than a hard error
  /// (plan §4 step 5).
  Future<bool> updateRefFastForward(String newCommitSha) async {
    final response = await _http.patch(
      _api('git/refs/heads/$branch'),
      headers: await _headers(),
      body: jsonEncode({'sha': newCommitSha, 'force': false}),
    );
    if (response.statusCode == 422 || response.statusCode == 409) return false;
    _throwIfError(response);
    return true;
  }

  /// Used only for the very first commit to an empty repo, where there is
  /// no existing ref to PATCH.
  Future<void> createInitialRef(String commitSha) async {
    final response = await _http.post(
      _api('git/refs'),
      headers: await _headers(),
      body: jsonEncode({'ref': 'refs/heads/$branch', 'sha': commitSha}),
    );
    _throwIfError(response);
  }

  void _throwIfError(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    throw GitHubApiException(response.statusCode, response.body);
  }
}

class GitHubApiException implements Exception {
  GitHubApiException(this.statusCode, this.body);

  final int statusCode;
  final String body;

  @override
  String toString() => 'GitHubApiException($statusCode): $body';
}
