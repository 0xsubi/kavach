import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neopop_theme/neopop_theme.dart';

import '../state/vault_controller.dart';

class UnlockScreen extends ConsumerStatefulWidget {
  const UnlockScreen({super.key});

  @override
  ConsumerState<UnlockScreen> createState() => _UnlockScreenState();
}

class _UnlockScreenState extends ConsumerState<UnlockScreen> {
  final _masterPasswordController = TextEditingController();
  bool _useMasterPassword = false;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _tryQuickUnlock());
  }

  @override
  void dispose() {
    _masterPasswordController.dispose();
    super.dispose();
  }

  Future<void> _tryQuickUnlock() async {
    setState(() => _busy = true);
    final ok = await ref.read(vaultControllerProvider.notifier).unlock();
    setState(() {
      _busy = false;
      if (!ok) _useMasterPassword = true;
    });
  }

  Future<void> _submitMasterPassword() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await ref
        .read(vaultControllerProvider.notifier)
        .unlockWithMasterPassword(_masterPasswordController.text);
    setState(() {
      _busy = false;
      if (!ok) _error = 'Incorrect master password.';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KavachColors.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.lock_outline, color: KavachColors.primary, size: 48),
                  const SizedBox(height: 16),
                  const Text(
                    'Vault locked',
                    style: TextStyle(
                      color: KavachColors.textPrimary,
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  if (_useMasterPassword) ...[
                    KavachCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const KavachSectionLabel('Master password'),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _masterPasswordController,
                            obscureText: true,
                            style: const TextStyle(color: KavachColors.textPrimary),
                            decoration: const InputDecoration(border: OutlineInputBorder()),
                            onSubmitted: (_) => _submitMasterPassword(),
                          ),
                          if (_error != null) ...[
                            const SizedBox(height: 12),
                            Text(_error!, style: const TextStyle(color: KavachColors.danger)),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    KavachButton(
                      label: _busy ? 'Unlocking…' : 'Unlock',
                      onTap: _busy ? null : _submitMasterPassword,
                    ),
                  ] else
                    const CircularProgressIndicator(color: KavachColors.accent),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
