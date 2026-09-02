import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kavach_core_storage_web/kavach_core_storage_web.dart';
import 'package:neopop_theme/neopop_theme.dart';
import 'package:sodium_libs/sodium_libs_sumo.dart';

import 'data/autofill_responder.dart';
import 'data/vault_repository.dart';
import 'screens/create_vault_screen.dart';
import 'screens/pending_approval_screen.dart';
import 'screens/unlock_screen.dart';
import 'screens/vault_list_screen.dart';
import 'state/vault_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final sodium = await SodiumSumoInit.init();
  final cache = await LocalVaultCacheWeb.open();
  final repository = VaultRepository(secureStore: SecureKeyStoreWeb(), cache: cache, sodium: sodium);

  // This same entrypoint runs both in the side panel and in the extension's
  // offscreen document (which mounts no UI at all — see build.mjs/manifest).
  // Building the container explicitly, instead of letting ProviderScope
  // create one implicitly, lets AutofillResponder share it.
  final container = ProviderContainer(overrides: [vaultRepositoryProvider.overrideWithValue(repository)]);
  container.read(vaultControllerProvider);

  // Only the offscreen document (marked via ?context=offscreen — see
  // service-worker.ts) answers autofill queries. If the side panel also
  // registered a responder, every query would get answered twice — once per
  // surface — and whichever instance is still mid-unlock at that instant
  // could race the other one and clobber a correct match with an empty one.
  final isOffscreenDocument = Uri.base.queryParameters['context'] == 'offscreen';
  if (isOffscreenDocument) {
    AutofillResponder(container);
    unawaited(_bootstrapOffscreenVault(container));
  }

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const KavachPopupApp(),
    ),
  );
}

/// Unlocks the vault in the offscreen document, explicitly.
///
/// Everywhere else this happens as a side effect of `UnlockScreen` mounting
/// (`initState` -> `tryQuickUnlock`). That never fires here: the offscreen
/// document is never painted, and Flutter web drives widget builds off
/// `requestAnimationFrame`, which browsers don't run for a document that
/// isn't rendered. So the screen never mounts, the quick unlock never runs,
/// and the responder is left answering every autofill query from a
/// permanently-locked vault — i.e. always zero matches.
Future<void> _bootstrapOffscreenVault(ProviderContainer container) async {
  final settled = Completer<VaultStatus>();
  late final ProviderSubscription<VaultState> subscription;

  void check(VaultState state) {
    if (state.status != VaultStatus.loading && !settled.isCompleted) {
      settled.complete(state.status);
    }
  }

  subscription = container.listen<VaultState>(vaultControllerProvider, (_, next) => check(next));
  check(container.read(vaultControllerProvider));

  final status = await settled.future.timeout(
    const Duration(seconds: 10),
    onTimeout: () => container.read(vaultControllerProvider).status,
  );
  subscription.close();

  if (status == VaultStatus.locked) {
    await container.read(vaultControllerProvider.notifier).tryQuickUnlock();
  }
}

class KavachPopupApp extends StatelessWidget {
  const KavachPopupApp({super.key});

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
        colorScheme: ColorScheme.fromSeed(seedColor: KavachColors.primary, brightness: Brightness.light),
        inputDecorationTheme: InputDecorationTheme(
          filled: false,
          hintStyle: const TextStyle(color: KavachColors.textSecondary),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: KavachColors.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: KavachColors.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: KavachColors.primary, width: 1.5),
          ),
        ),
      ),
      home: const _AppShell(),
    );
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
