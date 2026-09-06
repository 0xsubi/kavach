import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kavach_core/kavach_core.dart';

import '../data/vault_repository.dart';

enum VaultStatus { loading, needsCreation, pendingApproval, locked, unlocked }

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

  /// Now that sync targets a server we control (kavach-storage) rather than
  /// GitHub, polling for changes is cheap: `since_revision` makes an
  /// unchanged poll a near-empty response, not a full-tree fetch. In
  /// *addition* to the manual "sync now" action — not a replacement for it.
  /// Only runs while unlocked (started in [_refreshUnlocked], stopped in
  /// [lock]/[dispose]). Runs independently in whichever context this
  /// controller is instantiated in — the offscreen document (auto-unlocked
  /// for autofill) and the side panel popup each get their own timer, so
  /// autofill data stays fresh even when the popup itself is closed.
  static const _pollInterval = Duration(seconds: 10);
  Timer? _pollTimer;

  void _startPolling() {
    _pollTimer ??= Timer.periodic(_pollInterval, (_) => syncIfConfigured());
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  @override
  void dispose() {
    _stopPolling();
    super.dispose();
  }

  Future<void> _init() async {
    final hasVault = await _repo.hasVault();
    if (!hasVault) {
      state = const VaultState(status: VaultStatus.needsCreation);
      return;
    }
    final hasKey = await _repo.hasCachedVaultKey();
    state = VaultState(status: hasKey ? VaultStatus.locked : VaultStatus.pendingApproval);
  }

  Future<void> joinExistingVault({
    required String baseUrl,
    required String vaultId,
    required String inviteToken,
  }) async {
    state = state.copyWith(error: null);
    try {
      await _repo.joinExistingVault(baseUrl: baseUrl, vaultId: vaultId, inviteToken: inviteToken);
      state = const VaultState(status: VaultStatus.pendingApproval);
    } catch (e) {
      state = state.copyWith(error: e.toString());
    }
  }

  Future<bool> checkJoinApproval() async {
    final approved = await _repo.checkJoinApproval();
    if (approved) {
      final ok = await _repo.unlock();
      if (ok) {
        await _refreshUnlocked();
        unawaited(syncIfConfigured());
      }
    }
    return approved;
  }

  Future<List<DeviceRecord>> listDevices() => _repo.listDevices();

  Future<void> approveDevice(DeviceRecord device) => _repo.approveDevice(device);

  Future<({String inviteToken, DateTime expiresAt})> createDeviceInvite() => _repo.createDeviceInvite();

  Future<void> createVault(String masterPassword) async {
    await _repo.createVault(masterPassword: masterPassword);
    await _refreshUnlocked();
  }

  Future<bool> unlockWithMasterPassword(String masterPassword) async {
    final ok = await _repo.unlockWithMasterPassword(masterPassword);
    if (ok) {
      await _refreshUnlocked();
      unawaited(syncIfConfigured());
    }
    return ok;
  }

  /// Tries the locally-cached vault key first (no master password needed —
  /// browsers have no biometric-gate equivalent, so this is the closest
  /// thing to "quick unlock" the popup has); the caller falls back to a
  /// master-password prompt if this returns false.
  Future<bool> tryQuickUnlock() async {
    final ok = await _repo.unlock();
    if (ok) {
      await _refreshUnlocked();
      unawaited(syncIfConfigured());
    }
    return ok;
  }

  Future<void> syncIfConfigured() async {
    if (state.isSyncing) return;
    if (await _repo.hasStorageConfigured()) {
      await syncNow();
    }
  }

  void lock() {
    _stopPolling();
    _repo.lock();
    state = state.copyWith(status: VaultStatus.locked, items: const []);
  }

  Future<void> refresh() => _refreshUnlocked();

  Future<void> _refreshUnlocked() async {
    final items = await _repo.listItems();
    state = state.copyWith(status: VaultStatus.unlocked, items: items);
    _startPolling();
  }

  Future<void> savePasswordItem({
    String? id,
    required String name,
    required String username,
    required String password,
    List<String> uris = const [],
    String notes = '',
  }) async {
    await _repo.savePasswordItem(id: id, name: name, username: username, password: password, uris: uris, notes: notes);
    await _refreshUnlocked();
  }

  Future<void> deleteItem(VaultItem item) async {
    await _repo.deleteItem(item);
    await _refreshUnlocked();
  }

  Future<bool> hasStorageConfigured() => _repo.hasStorageConfigured();

  Future<({String baseUrl, String vaultId})?> storageTarget() => _repo.storageTarget();

  Future<void> setupNewVaultStorage({required String baseUrl, required String adminToken}) =>
      _repo.setupNewVaultStorage(baseUrl: baseUrl, adminToken: adminToken);

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
