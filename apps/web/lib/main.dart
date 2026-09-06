import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kavach_core/kavach_core.dart';
import 'package:kavach_core_storage_web/kavach_core_storage_web.dart';
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
  final cache = await LocalVaultCacheWeb.open();
  final secureStore = await SecureKeyStoreIndexedDb.open();
  final repository = VaultRepository(secureStore: secureStore, cache: cache, sodium: sodium);

  runApp(
    ProviderScope(
      overrides: [vaultRepositoryProvider.overrideWithValue(repository)],
      child: KavachWebApp(initialInvite: _inviteFromCurrentUrl()),
    ),
  );
}

/// Reads a device invite off the page's own URL — `/join?v=1&url=…` — the
/// web equivalent of the native apps' `kavach://join` deep link. There's no
/// custom scheme to register for a website, and none is needed: the
/// inviting device's QR code encodes an ordinary `https://<this
/// origin>/join?…` link, so scanning it with a phone camera just opens
/// this page directly with the invite already in the query string. Only
/// consulted once, at startup — a browser tab has no equivalent of a
/// second incoming deep link arriving while it's already open.
DeviceInviteUri? _inviteFromCurrentUrl() {
  final uri = Uri.base;
  if (uri.pathSegments.isEmpty || uri.pathSegments.last != 'join') return null;
  return DeviceInviteUri.tryParseQueryParameters(uri.queryParameters);
}

class KavachWebApp extends StatelessWidget {
  const KavachWebApp({super.key, this.initialInvite});

  final DeviceInviteUri? initialInvite;

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
      // Unlike the extension's fixed-width side panel or a phone screen, a
      // browser window can be arbitrarily wide. Every screen here was
      // built against a narrow layout, so rather than reflow each one,
      // pin the whole app to a phone-shaped column and let it float on a
      // neutral field on anything wider — the same trick Bitwarden's and
      // Vaultwarden's web vaults use.
      builder: (context, child) => ColoredBox(
        color: const Color(0xFFF2F3F5),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: child,
          ),
        ),
      ),
      home: _AppShell(initialInvite: initialInvite),
    );
  }
}

class _AppShell extends ConsumerStatefulWidget {
  const _AppShell({this.initialInvite});

  final DeviceInviteUri? initialInvite;

  @override
  ConsumerState<_AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<_AppShell> {
  bool _consumedInitialInvite = false;

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(vaultControllerProvider).status;

    // A join link only makes sense against a device that isn't already
    // part of a vault — joinExistingVault regenerates this browser's
    // device identity, which would strand whatever's already set up.
    // Consumed once (the guard flag), the first time status settles into
    // needsCreation, rather than on every rebuild.
    final invite = widget.initialInvite;
    if (invite != null && !_consumedInitialInvite && status == VaultStatus.needsCreation) {
      _consumedInitialInvite = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => JoinVaultScreen(initialInvite: invite)),
        );
      });
    }

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
