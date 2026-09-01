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
  final _owner = TextEditingController();
  final _repo = TextEditingController();
  final _token = TextEditingController();
  bool _loadingExisting = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadExisting();
  }

  Future<void> _loadExisting() async {
    final target = await ref.read(vaultControllerProvider.notifier).gitHubTarget();
    if (target != null) {
      _owner.text = target.owner;
      _repo.text = target.repo;
    }
    if (mounted) setState(() => _loadingExisting = false);
  }

  @override
  void dispose() {
    _owner.dispose();
    _repo.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _saveAndSync() async {
    if (_owner.text.trim().isEmpty || _repo.text.trim().isEmpty || _token.text.trim().isEmpty) {
      return;
    }
    setState(() => _saving = true);
    final notifier = ref.read(vaultControllerProvider.notifier);
    await notifier.configureGitHub(
      owner: _owner.text.trim(),
      repo: _repo.text.trim(),
      token: _token.text.trim(),
    );
    await notifier.syncNow();
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
        title: const Text('GitHub sync', style: TextStyle(color: KavachColors.textPrimary)),
      ),
      body: SafeArea(
        child: _loadingExisting
            ? const Center(child: CircularProgressIndicator(color: KavachColors.accent))
            : SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Your vault is stored, client-side encrypted, in a private GitHub repo '
                      'you control. Kavach never sends plaintext to GitHub.',
                      style: TextStyle(color: KavachColors.textSecondary, fontSize: 13),
                    ),
                    const SizedBox(height: 24),
                    KavachCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _field('Repo owner', _owner, hint: 'e.g. sudhabindu1'),
                          const SizedBox(height: 16),
                          _field('Repo name', _repo, hint: 'e.g. kavach-vault'),
                          const SizedBox(height: 16),
                          _field(
                            'Personal access token',
                            _token,
                            hint: 'fine-grained PAT with contents:write on this repo',
                            obscure: true,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    KavachButton(
                      label: _saving ? 'Syncing…' : 'Save & sync now',
                      onTap: _saving ? null : _saveAndSync,
                    ),
                    if (state.syncError != null) ...[
                      const SizedBox(height: 16),
                      Text(state.syncError!, style: const TextStyle(color: KavachColors.danger)),
                    ],
                    if (state.lastSyncReport != null) ...[
                      const SizedBox(height: 16),
                      Text(
                        'Last sync: ${state.lastSyncReport!.pushedItemIds.length} pushed, '
                        '${state.lastSyncReport!.pulledItemIds.length} pulled, '
                        '${state.lastSyncReport!.conflictCopies.length} conflict(s).',
                        style: const TextStyle(color: KavachColors.textSecondary, fontSize: 13),
                      ),
                    ],
                    const SizedBox(height: 12),
                    KavachButton(
                      label: 'Devices',
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
