import 'package:kavach/data/vault_repository.dart';
import 'package:kavach/main.dart';
import 'package:kavach/state/vault_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kavach_core_storage_native/kavach_core_storage_native.dart';
import 'package:sodium_libs/sodium_libs_sumo.dart';

/// Reproduces the manually-reported "stuck on create vault screen" bug by
/// driving the exact same create-vault flow as app_test.dart, but against
/// the REAL [SecureKeyStoreNative] (macOS Keychain) and real
/// [openVaultDatabase] instead of in-memory fakes — i.e. exactly what
/// `main.dart` wires up.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('create vault against real Keychain + sqlite storage', (tester) async {
    final sodium = await SodiumSumoInit.init();
    final database = await openVaultDatabase(fileName: 'kavach_vault_smoke_test.sqlite');
    final secureStore = SecureKeyStoreNative();
    await secureStore.deleteAll();

    final repository = VaultRepository(
      secureStore: secureStore,
      cache: LocalVaultCacheNative(database),
      sodium: sodium,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [vaultRepositoryProvider.overrideWithValue(repository)],
        child: const KavachApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('create your vault'), findsOneWidget);

    await tester.enterText(find.byType(TextField).at(0), 'correct horse battery staple');
    await tester.enterText(find.byType(TextField).at(1), 'correct horse battery staple');
    await tester.ensureVisible(find.text('create vault'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('create vault'));

    // Give createVault() real wall-clock time (Argon2id + real Keychain
    // I/O), then pump a bunch of frames instead of pumpAndSettle(), so a
    // hang shows up as a clear timeout/expect failure instead of the test
    // runner waiting forever on an infinite animation.
    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }

    expect(find.text('create your vault'), findsNothing, reason: 'still stuck on create-vault screen');
    expect(find.text('no items yet.\ntap + to add your first password.'), findsOneWidget);

    await secureStore.deleteAll();
  });
}
