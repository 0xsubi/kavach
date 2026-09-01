import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kavach_core/kavach_core.dart';
import 'package:neopop_theme/neopop_theme.dart';

import '../data/vault_repository.dart';
import '../state/vault_controller.dart';
import 'generator_screen.dart';
import 'item_editor_screen.dart';
import 'settings_screen.dart';

class VaultListScreen extends ConsumerWidget {
  const VaultListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(vaultControllerProvider);

    ref.listen(vaultControllerProvider, (previous, next) {
      final err = next.syncError;
      if (err != null && err != previous?.syncError) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Sync failed: $err')));
      }
    });

    return Scaffold(
      backgroundColor: KavachColors.background,
      appBar: AppBar(
        backgroundColor: KavachColors.background,
        title: const Text('Kavach', style: TextStyle(color: KavachColors.primary)),
        iconTheme: const IconThemeData(color: KavachColors.textPrimary),
        actions: [
          IconButton(
            icon: state.isSyncing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: KavachColors.accent),
                  )
                : const Icon(Icons.sync),
            tooltip: 'Sync now',
            onPressed: state.isSyncing
                ? null
                : () => ref.read(vaultControllerProvider.notifier).syncNow(),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'GitHub sync settings',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.casino_outlined),
            tooltip: 'Password generator',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const GeneratorScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.lock_outline),
            tooltip: 'Lock vault',
            onPressed: () => ref.read(vaultControllerProvider.notifier).lock(),
          ),
        ],
      ),
      body: SafeArea(
        child: state.items.isEmpty
            ? const Center(
                child: Text(
                  'No items yet.\nTap + to add your first password.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: KavachColors.textSecondary),
                ),
              )
            : ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: state.items.length,
                separatorBuilder: (_, _) => const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final item = state.items[index];
                  return _VaultItemTile(item: item);
                },
              ),
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: KavachColors.primary,
        foregroundColor: KavachColors.background,
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const ItemEditorScreen()),
        ),
        child: const Icon(Icons.add),
      ),
    );
  }
}

class _VaultItemTile extends StatelessWidget {
  const _VaultItemTile({required this.item});

  final VaultItem item;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ItemEditorScreen(existing: item)),
      ),
      child: KavachCard(
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: KavachColors.surface,
                border: Border.all(color: KavachColors.border),
              ),
              child: Text(
                item.displayName.isNotEmpty ? item.displayName[0].toUpperCase() : '?',
                style: const TextStyle(color: KavachColors.textPrimary, fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.displayName,
                    style: const TextStyle(
                      color: KavachColors.textPrimary,
                      fontWeight: FontWeight.w600,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    item.displaySubtitle,
                    style: const TextStyle(color: KavachColors.textSecondary, fontSize: 13),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: KavachColors.textSecondary),
          ],
        ),
      ),
    );
  }
}
