import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kavach_core/kavach_core.dart';
import 'package:kavach_core_storage_native/kavach_core_storage_native.dart';
import 'package:neopop_theme/neopop_theme.dart';
import 'package:sodium_libs/sodium_libs_sumo.dart';

import 'data/vault_repository.dart';
import 'screens/create_vault_screen.dart';
import 'screens/join_vault_screen.dart';
import 'screens/pending_approval_screen.dart';
import 'screens/unlock_screen.dart';
import 'screens/vault_list_screen.dart';
import 'state/vault_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final sodium = await SodiumSumoInit.init();
  final database = await openVaultDatabase();
  final secureStore = SecureKeyStoreNative();
  await ensureFreshInstallState(secureStore);
  final repository = VaultRepository(
    secureStore: secureStore,
    cache: LocalVaultCacheNative(database),
    sodium: sodium,
  );

  runApp(
    ProviderScope(
      overrides: [vaultRepositoryProvider.overrideWithValue(repository)],
      child: const KavachApp(),
    ),
  );
}

class KavachApp extends StatelessWidget {
  const KavachApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'kavach',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        fontFamily: KavachFonts.display,
        scaffoldBackgroundColor: KavachColors.background,
        colorScheme: ColorScheme.fromSeed(
          seedColor: KavachColors.primary,
          brightness: Brightness.light,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: false,
          hintStyle: const TextStyle(color: KavachColors.textSecondary),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: KavachColors.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: KavachColors.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: KavachColors.primary, width: 1.5),
          ),
        ),
      ),
      home: const _DeepLinkListener(child: _AppShell()),
    );
  }
}

/// Routes `kavach://join?…` deep links to the join screen with the invite
/// already filled in.
///
/// That link is what the inviting device's QR code encodes, so scanning it
/// with a phone's system camera is enough to onboard a device — no
/// transcribing a server URL, a UUID and a one-time token by hand.
class _DeepLinkListener extends ConsumerStatefulWidget {
  const _DeepLinkListener({required this.child});

  final Widget child;

  @override
  ConsumerState<_DeepLinkListener> createState() => _DeepLinkListenerState();
}

class _DeepLinkListenerState extends ConsumerState<_DeepLinkListener> {
  StreamSubscription<Uri>? _subscription;
  DeviceInviteUri? _pendingInvite;
  bool _joinRouteOpen = false;

  @override
  void initState() {
    super.initState();
    // uriLinkStream replays the cold-start link as its first event, so
    // there's no separate getInitialLink() call to double-handle.
    _subscription = AppLinks().uriLinkStream.listen((uri) {
      final invite = DeviceInviteUri.tryParse(uri);
      // Anything that isn't a well-formed current-version invite is
      // ignored outright — this input arrives from a camera scan.
      if (invite == null) return;
      _pendingInvite = invite;
      _drainPendingInvite();
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  Future<void> _drainPendingInvite() async {
    final invite = _pendingInvite;
    if (invite == null || _joinRouteOpen || !mounted) return;

    final status = ref.read(vaultControllerProvider).status;
    // A cold-start link routinely beats the controller's read of local
    // state. Hold the invite; the ref.listen in build() calls back here
    // as soon as the status settles.
    if (status == VaultStatus.loading) return;
    _pendingInvite = null;

    if (status != VaultStatus.needsCreation) {
      // joinExistingVault regenerates this device's identity keypair and
      // repoints its storage config, which would strand the vault already
      // set up here. Refuse rather than silently clobber it.
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: KavachColors.surface,
          title: const Text('already set up', style: TextStyle(color: KavachColors.textPrimary)),
          content: const Text(
            'this device is already part of a vault. joining another one would '
            'replace its identity and lose access to the current vault.',
            style: TextStyle(color: KavachColors.textSecondary, fontSize: 13),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('ok')),
          ],
        ),
      );
      return;
    }

    _joinRouteOpen = true;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => JoinVaultScreen(initialInvite: invite)),
    );
    _joinRouteOpen = false;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(vaultControllerProvider, (previous, next) {
      if (previous?.status != next.status) _drainPendingInvite();
    });
    return widget.child;
  }
}

class _AppShell extends ConsumerWidget {
  const _AppShell();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(vaultControllerProvider).status;
    return switch (status) {
      VaultStatus.loading => const Scaffold(
          backgroundColor: KavachColors.background,
          body: Center(child: CircularProgressIndicator(color: KavachColors.accent)),
        ),
      VaultStatus.needsCreation => const CreateVaultScreen(),
      VaultStatus.pendingApproval => const PendingApprovalScreen(),
      VaultStatus.locked => const UnlockScreen(),
      VaultStatus.unlocked => const VaultListScreen(),
    };
  }
}
