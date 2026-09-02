import 'github_client.dart';
import 'repo_paths.dart';

/// Gives a vault repo its `.kavach/` scaffolding commit, so [SyncEngine]
/// (which needs a real HEAD to diff against) has something to operate on.
/// Callers supply the already-serialized `.kavach/` scaffolding files
/// (manifest, self-approved device record, wrapped vault key, escrow blob —
/// plan §2/§5) as path -> bytes; this class only knows how to turn that into
/// one Git commit, not how those files are shaped.
class VaultProvisioning {
  const VaultProvisioning(this.github);

  final GitHubClient github;

  /// No-ops (returning the existing HEAD) once [RepoPaths.manifest] is
  /// actually present, so this is safe to call unconditionally on every app
  /// start. Deliberately checks for the manifest file itself rather than
  /// "does the branch have any commit" — a repo can easily have unrelated
  /// pre-existing commits (a README, prior manual cleanup, ...) without ever
  /// having been initialized as a Kavach vault, and treating that as
  /// "already initialized" silently skips writing this device's own device
  /// record/wrapped key, which then makes every other device's approval of
  /// it unresolvable (no `devices/<this-id>.json` to read the approver's
  /// public key from).
  Future<String> ensureInitialized(Map<String, List<int>> files) async {
    final existingHead = await github.getHeadCommitSha();
    String? baseTreeSha;
    final parents = <String>[];

    if (existingHead != null) {
      final treeSha = await github.getCommitTreeSha(existingHead);
      final tree = await github.getTreeRecursive(treeSha);
      final alreadyInitialized = tree.any((entry) => entry.path == RepoPaths.manifest);
      if (alreadyInitialized) return existingHead;
      baseTreeSha = treeSha;
      parents.add(existingHead);
    }

    final entries = <GitTreeEntry>[];
    for (final entry in files.entries) {
      final blobSha = await github.createBlob(entry.value);
      entries.add(GitTreeEntry(path: entry.key, mode: '100644', type: 'blob', sha: blobSha));
    }
    final treeSha = await github.createTree(entries, baseTreeSha: baseTreeSha);
    final commitSha = await github.createCommit(
      message: 'Kavach: initialize vault',
      treeSha: treeSha,
      parentShas: parents,
    );

    if (existingHead == null) {
      await github.createInitialRef(commitSha);
    } else {
      final landed = await github.updateRefFastForward(commitSha);
      if (!landed) {
        throw StateError('Vault initialization failed: the repo changed concurrently. Please retry.');
      }
    }
    return commitSha;
  }
}
