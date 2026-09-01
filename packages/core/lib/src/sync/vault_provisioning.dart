import 'github_client.dart';

/// Gives a brand-new vault repo its first commit, so [SyncEngine] (which
/// needs a real HEAD to diff against) has something to operate on. Callers
/// supply the already-serialized `.kavach/` scaffolding files (manifest,
/// self-approved device record, wrapped vault key, escrow blob — plan §2/§5)
/// as path -> bytes; this class only knows how to turn that into one Git
/// commit, not how those files are shaped.
class VaultProvisioning {
  const VaultProvisioning(this.github);

  final GitHubClient github;

  /// No-ops (returning the existing HEAD) if the repo already has commits,
  /// so this is safe to call unconditionally on every app start.
  Future<String> ensureInitialized(Map<String, List<int>> files) async {
    final existingHead = await github.getHeadCommitSha();
    if (existingHead != null) return existingHead;

    final entries = <GitTreeEntry>[];
    for (final entry in files.entries) {
      final blobSha = await github.createBlob(entry.value);
      entries.add(GitTreeEntry(path: entry.key, mode: '100644', type: 'blob', sha: blobSha));
    }
    final treeSha = await github.createTree(entries);
    final commitSha = await github.createCommit(
      message: 'Kavach: initialize vault',
      treeSha: treeSha,
      parentShas: const [],
    );
    await github.createInitialRef(commitSha);
    return commitSha;
  }
}
