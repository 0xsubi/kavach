import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neopop_theme/neopop_theme.dart';

import '../state/vault_controller.dart';

/// Registers this device against an existing vault's GitHub repo and waits
/// for an already-approved device to approve it (plan §5 "new device
/// onboarding"). No master password is entered here — only the approving
/// device needs one, to unlock and re-wrap the vault key.
class JoinVaultScreen extends ConsumerStatefulWidget {
  const JoinVaultScreen({super.key});

  @override
  ConsumerState<JoinVaultScreen> createState() => _JoinVaultScreenState();
}

class _JoinVaultScreenState extends ConsumerState<JoinVaultScreen> {
  final _owner = TextEditingController();
  final _repo = TextEditingController();
  final _token = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _owner.dispose();
    _repo.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_owner.text.trim().isEmpty || _repo.text.trim().isEmpty || _token.text.trim().isEmpty) {
      return;
    }
    setState(() => _busy = true);
    final notifier = ref.read(vaultControllerProvider.notifier);
    await notifier.joinExistingVault(
      owner: _owner.text.trim(),
      repo: _repo.text.trim(),
      token: _token.text.trim(),
    );
    if (!mounted) return;
    // This screen was pushed via Navigator.push on top of the app shell, so
    // the shell swapping its underlying content to PendingApprovalScreen
    // doesn't make that screen visible on its own — the pushed route stays
    // on top until it's explicitly popped.
    if (ref.read(vaultControllerProvider).error == null) {
      Navigator.of(context).pop();
    } else {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final error = ref.watch(vaultControllerProvider).error;

    return Scaffold(
      backgroundColor: KavachColors.background,
      appBar: AppBar(
        backgroundColor: KavachColors.background,
        iconTheme: const IconThemeData(color: KavachColors.textPrimary),
        title: const Text('join a vault', style: TextStyle(color: KavachColors.textPrimary)),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'enter the same private GitHub repo another one of your devices already '
                'uses. that device will need to approve you before this one can unlock.',
                style: TextStyle(color: KavachColors.textSecondary, fontSize: 13),
              ),
              const SizedBox(height: 24),
              KavachCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _field('repo owner', _owner, hint: 'e.g. your-username'),
                    const SizedBox(height: 16),
                    _field('repo name', _repo, hint: 'e.g. kavach-vault'),
                    const SizedBox(height: 16),
                    _field(
                      'personal access token',
                      _token,
                      hint: 'fine-grained pat with contents:write on this repo',
                      obscure: true,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              KavachButton(
                label: _busy ? 'requesting…' : 'request to join',
                onTap: _busy ? null : _submit,
              ),
              if (error != null) ...[
                const SizedBox(height: 16),
                Text(error, style: const TextStyle(color: KavachColors.danger)),
              ],
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
