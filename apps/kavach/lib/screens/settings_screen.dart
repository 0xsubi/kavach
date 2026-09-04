import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neopop_theme/neopop_theme.dart';

import '../state/vault_controller.dart';
import 'devices_screen.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _baseUrl = TextEditingController();
  final _adminToken = TextEditingController();
  bool _loadingExisting = true;
  bool _saving = false;
  bool _alreadyConfigured = false;

  @override
  void initState() {
    super.initState();
    _loadExisting();
  }

  Future<void> _loadExisting() async {
    final target = await ref.read(vaultControllerProvider.notifier).storageTarget();
    if (target != null) {
      _baseUrl.text = target.baseUrl;
      _alreadyConfigured = true;
    }
    if (mounted) setState(() => _loadingExisting = false);
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _adminToken.dispose();
    super.dispose();
  }

  Future<void> _saveAndSync() async {
    if (_baseUrl.text.trim().isEmpty || _adminToken.text.trim().isEmpty) return;
    setState(() => _saving = true);
    final notifier = ref.read(vaultControllerProvider.notifier);
    await notifier.setupNewVaultStorage(baseUrl: _baseUrl.text.trim(), adminToken: _adminToken.text.trim());
    await notifier.syncNow();
    if (mounted) setState(() => _saving = false);
  }

  Future<void> _syncOnly() async {
    setState(() => _saving = true);
    await ref.read(vaultControllerProvider.notifier).syncNow();
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(vaultControllerProvider);

    return Scaffold(
      backgroundColor: KavachColors.background,
      appBar: AppBar(
        backgroundColor: KavachColors.background,
        iconTheme: const IconThemeData(color: KavachColors.textPrimary),
        title: const Text('kavach-storage sync', style: TextStyle(color: KavachColors.textPrimary)),
      ),
      body: SafeArea(
        child: _loadingExisting
            ? const Center(child: CircularProgressIndicator(color: KavachColors.accent))
            : SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      _alreadyConfigured
                          ? 'your vault is stored, client-side encrypted, on the kavach-storage '
                              'server below. kavach never sends plaintext to it.'
                          : 'create a brand-new vault on a kavach-storage server you (or whoever '
                              'hosts it) control. you\'ll need that server\'s admin token — this '
                              'device becomes the vault\'s first, auto-approved device. kavach '
                              'never sends plaintext to it.',
                      style: const TextStyle(color: KavachColors.textSecondary, fontSize: 13),
                    ),
                    const SizedBox(height: 24),
                    KavachCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _field('server url', _baseUrl, hint: 'e.g. https://kavach-storage.example.com'),
                          if (!_alreadyConfigured) ...[
                            const SizedBox(height: 16),
                            _field('admin token', _adminToken, hint: 'the server operator\'s provisioning token', obscure: true),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    KavachButton(
                      label: _saving
                          ? 'syncing…'
                          : (_alreadyConfigured ? 'sync now' : 'create vault & sync'),
                      onTap: _saving ? null : (_alreadyConfigured ? _syncOnly : _saveAndSync),
                    ),
                    if (state.syncError != null) ...[
                      const SizedBox(height: 16),
                      Text(state.syncError!, style: const TextStyle(color: KavachColors.danger)),
                    ],
                    if (state.lastSyncReport != null) ...[
                      const SizedBox(height: 16),
                      Text(
                        'last sync: ${state.lastSyncReport!.pushedItemIds.length} pushed, '
                        '${state.lastSyncReport!.pulledItemIds.length} pulled, '
                        '${state.lastSyncReport!.conflictCopies.length} conflict(s).',
                        style: const TextStyle(color: KavachColors.textSecondary, fontSize: 13),
                      ),
                    ],
                    const SizedBox(height: 12),
                    KavachButton(
                      label: 'devices',
                      icon: Icons.devices_outlined,
                      color: KavachColors.surface,
                      textColor: KavachColors.textPrimary,
                      outlined: true,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const DevicesScreen()),
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _field(String label, TextEditingController controller, {String? hint, bool obscure = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KavachSectionLabel(label),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          obscureText: obscure,
          style: const TextStyle(color: KavachColors.textPrimary),
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            hintText: hint,
            hintStyle: const TextStyle(color: KavachColors.textSecondary),
          ),
        ),
      ],
    );
  }
}
