import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kavach_core/kavach_core.dart';
import 'package:neopop_theme/neopop_theme.dart';

import '../data/vault_repository.dart';
import '../state/vault_controller.dart';
import 'generator_screen.dart';
import 'item_editor_screen.dart';
import 'settings_screen.dart';

class VaultListScreen extends ConsumerStatefulWidget {
  const VaultListScreen({super.key});

  @override
  ConsumerState<VaultListScreen> createState() => _VaultListScreenState();
}

class _VaultListScreenState extends ConsumerState<VaultListScreen> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() => setState(() => _query = _searchController.text.toLowerCase()));
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(vaultControllerProvider);

    ref.listen(vaultControllerProvider, (previous, next) {
      final err = next.syncError;
      if (err != null && err != previous?.syncError) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('sync failed: $err')));
      }
    });

    final filtered = _query.isEmpty
        ? state.items
        : state.items
            .where((i) => i.displayName.toLowerCase().contains(_query) || i.displaySubtitle.toLowerCase().contains(_query))
            .toList();

    return Scaffold(
      backgroundColor: KavachColors.background,
      appBar: AppBar(
        backgroundColor: KavachColors.background,
        title: const Text('kavach', style: TextStyle(color: KavachColors.primary, fontSize: 18)),
        iconTheme: const IconThemeData(color: KavachColors.textPrimary),
        actions: [
          IconButton(
            icon: state.isSyncing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: KavachColors.accent),
                  )
                : const Icon(Icons.sync, size: 20),
            tooltip: 'sync now',
            onPressed: state.isSyncing ? null : () => ref.read(vaultControllerProvider.notifier).syncNow(),
          ),
          IconButton(
            icon: const Icon(Icons.casino_outlined, size: 20),
            tooltip: 'password generator',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const GeneratorScreen())),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined, size: 20),
            tooltip: 'kavach-storage sync settings',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
          IconButton(
            icon: const Icon(Icons.lock_outline, size: 20),
            tooltip: 'lock vault',
            onPressed: () => ref.read(vaultControllerProvider.notifier).lock(),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: TextField(
                controller: _searchController,
                style: const TextStyle(color: KavachColors.textPrimary, fontSize: 13),
                decoration: const InputDecoration(
                  isDense: true,
                  prefixIcon: Icon(Icons.search, size: 18),
                  hintText: 'search',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            Expanded(
              child: state.items.isEmpty
                  ? const Center(
                      child: Text(
                        'no items yet.\ntap + to add your first password.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: KavachColors.textSecondary, fontSize: 12),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                      itemCount: filtered.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) => _VaultItemTile(item: filtered[index]),
                    ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: KavachColors.primary,
        foregroundColor: KavachColors.background,
        onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ItemEditorScreen())),
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
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ItemEditorScreen(existing: item))),
      child: KavachCard(
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: KavachColors.surface,
                border: Border.all(color: KavachColors.border),
              ),
              child: Text(
                item.displayName.isNotEmpty ? item.displayName[0].toUpperCase() : '?',
                style: const TextStyle(color: KavachColors.textPrimary, fontWeight: FontWeight.w700, fontSize: 13),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.displayName,
                    style: const TextStyle(color: KavachColors.textPrimary, fontWeight: FontWeight.w600, fontSize: 14),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    item.displaySubtitle,
                    style: const TextStyle(color: KavachColors.textSecondary, fontSize: 11),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: KavachColors.textSecondary, size: 18),
          ],
        ),
      ),
    );
  }
}
