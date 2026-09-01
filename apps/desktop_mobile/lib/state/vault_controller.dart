import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kavach_core/kavach_core.dart';

import '../data/vault_repository.dart';

enum VaultStatus { loading, needsCreation, locked, unlocked }

class VaultState {
  const VaultState({
    required this.status,
    this.items = const [],
    this.error,
    this.isSyncing = false,
    this.lastSyncReport,
    this.syncError,
  });

  final VaultStatus status;
  final List<VaultItem> items;
  final String? error;
  final bool isSyncing;
  final SyncReport? lastSyncReport;
  final String? syncError;

  VaultState copyWith({
    VaultStatus? status,
    List<VaultItem>? items,
    String? error,
    bool? isSyncing,
    SyncReport? lastSyncReport,
    String? syncError,
  }) =>
      VaultState(
        status: status ?? this.status,
        items: items ?? this.items,
        error: error,
        isSyncing: isSyncing ?? this.isSyncing,
        lastSyncReport: lastSyncReport ?? this.lastSyncReport,
        syncError: syncError,
      );
}

class VaultController extends StateNotifier<VaultState> {
  VaultController(this._repo) : super(const VaultState(status: VaultStatus.loading)) {
    _init();
  }

  final VaultRepository _repo;

  Future<void> _init() async {
    final hasVault = await _repo.hasVault();
    state = VaultState(status: hasVault ? VaultStatus.locked : VaultStatus.needsCreation);
  }

  Future<void> createVault(String masterPassword) async {
    await _repo.createVault(masterPassword: masterPassword);
    await _refreshUnlocked();
  }

  Future<bool> unlock() async {
    final ok = await _repo.unlock();
    if (ok) {
      await _refreshUnlocked();
      unawaited(_autoSyncOnStart());
    }
    return ok;
  }

  Future<bool> unlockWithMasterPassword(String masterPassword) async {
    final ok = await _repo.unlockWithMasterPassword(masterPassword);
    if (ok) {
      await _refreshUnlocked();
      unawaited(_autoSyncOnStart());
    }
    return ok;
  }

  Future<void> _autoSyncOnStart() async {
    if (await _repo.hasGitHubConfigured()) {
      await syncNow();
    }
  }

  void lock() {
    _repo.lock();
    state = state.copyWith(status: VaultStatus.locked, items: const []);
  }

  Future<void> refresh() => _refreshUnlocked();

  Future<void> _refreshUnlocked() async {
    final items = await _repo.listItems();
    state = state.copyWith(status: VaultStatus.unlocked, items: items);
  }

  Future<void> savePasswordItem({
    String? id,
    required String name,
    required String username,
    required String password,
    List<String> uris = const [],
    String notes = '',
  }) async {
    await _repo.savePasswordItem(
      id: id,
      name: name,
      username: username,
      password: password,
      uris: uris,
      notes: notes,
    );
    await _refreshUnlocked();
  }

  Future<void> deleteItem(VaultItem item) async {
    await _repo.deleteItem(item);
    await _refreshUnlocked();
  }

  Future<bool> hasGitHubConfigured() => _repo.hasGitHubConfigured();

  Future<({String owner, String repo})?> gitHubTarget() => _repo.gitHubTarget();

  Future<void> configureGitHub({
    required String owner,
    required String repo,
    required String token,
  }) =>
      _repo.configureGitHub(owner: owner, repo: repo, token: token);

  Future<void> syncNow() async {
    state = state.copyWith(isSyncing: true, syncError: null);
    try {
      final report = await _repo.syncNow();
      state = state.copyWith(isSyncing: false, lastSyncReport: report, syncError: null);
      await _refreshUnlocked();
    } catch (e) {
      state = state.copyWith(isSyncing: false, syncError: e.toString());
    }
  }
}

final vaultRepositoryProvider = Provider<VaultRepository>((ref) {
  throw UnimplementedError('vaultRepositoryProvider must be overridden in main()');
});

final vaultControllerProvider = StateNotifierProvider<VaultController, VaultState>(
  (ref) => VaultController(ref.watch(vaultRepositoryProvider)),
);
