import 'package:desktop_mobile/data/vault_repository.dart';
import 'package:desktop_mobile/main.dart';
import 'package:desktop_mobile/state/vault_controller.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kavach_core/kavach_core.dart';
import 'package:kavach_core_storage_native/kavach_core_storage_native.dart';
import 'package:sodium_libs/sodium_libs_sumo.dart';

/// In-memory [SecureKeyStore] so this test never touches the real OS
/// Keychain/Keystore.
class _FakeSecureKeyStore implements SecureKeyStore {
  final Map<String, String> _values = {};

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> delete(String key) async => _values.remove(key);

  @override
  Future<void> deleteAll() async => _values.clear();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('create vault, add a password item, lock and unlock', (tester) async {
    final sodium = await SodiumSumoInit.init();
    final database = VaultDatabase(NativeDatabase.memory());
    final repository = VaultRepository(
      secureStore: _FakeSecureKeyStore(),
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

    expect(find.text('Create your vault'), findsOneWidget);

    await tester.enterText(find.byType(TextField).at(0), 'correct horse battery staple');
    await tester.enterText(find.byType(TextField).at(1), 'correct horse battery staple');
    await tester.ensureVisible(find.text('Create vault'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create vault'));
    await tester.pumpAndSettle();

    expect(find.text('No items yet.\nTap + to add your first password.'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    expect(find.text('New item'), findsOneWidget);

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'GitHub');
    await tester.enterText(fields.at(1), 'sudhabindu1@gmail.com');
    await tester.enterText(fields.at(2), 's3cr3t-p@ssw0rd');
    await tester.ensureVisible(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('New item'), findsNothing);
    expect(find.text('GitHub'), findsOneWidget);
    expect(find.text('sudhabindu1@gmail.com'), findsOneWidget);

    // Locking clears the in-memory vault key; since no biometric/PIN gate is
    // wired up yet (deferred to the native-polish phase, plan §10), the
    // unlock screen immediately quick-unlocks again using the still-present
    // cached key. This round trip exercises repository lock()/unlock() and
    // confirms the item survives it.
    await tester.tap(find.byIcon(Icons.lock_outline));
    await tester.pumpAndSettle();
    expect(find.text('GitHub'), findsOneWidget);
  });
}
