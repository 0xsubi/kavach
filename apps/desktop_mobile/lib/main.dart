import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kavach_core_storage_native/kavach_core_storage_native.dart';
import 'package:neopop_theme/neopop_theme.dart';
import 'package:sodium_libs/sodium_libs_sumo.dart';

import 'data/vault_repository.dart';
import 'screens/create_vault_screen.dart';
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
