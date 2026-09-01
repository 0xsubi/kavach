import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neopop_theme/neopop_theme.dart';

import '../state/vault_controller.dart';

class CreateVaultScreen extends ConsumerStatefulWidget {
  const CreateVaultScreen({super.key});

  @override
  ConsumerState<CreateVaultScreen> createState() => _CreateVaultScreenState();
}

class _CreateVaultScreenState extends ConsumerState<CreateVaultScreen> {
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final password = _passwordController.text;
    if (password.length < 8) {
      setState(() => _error = 'Master password must be at least 8 characters.');
      return;
    }
    if (password != _confirmController.text) {
      setState(() => _error = 'Passwords do not match.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    await ref.read(vaultControllerProvider.notifier).createVault(password);
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
                  const Text(
                    'Kavach',
                    style: TextStyle(
                      color: KavachColors.primary,
                      fontSize: 40,
                      fontWeight: FontWeight.w800,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Create your vault',
                    style: TextStyle(color: KavachColors.textSecondary, fontSize: 16),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),
                  KavachCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          'Master password',
                          style: TextStyle(color: KavachColors.textSecondary, fontSize: 13),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _passwordController,
                          obscureText: true,
                          style: const TextStyle(color: KavachColors.textPrimary),
                          decoration: const InputDecoration(border: OutlineInputBorder()),
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          'Confirm password',
                          style: TextStyle(color: KavachColors.textSecondary, fontSize: 13),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _confirmController,
                          obscureText: true,
                          style: const TextStyle(color: KavachColors.textPrimary),
                          decoration: const InputDecoration(border: OutlineInputBorder()),
                          onSubmitted: (_) => _submit(),
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
                    label: _busy ? 'Creating…' : 'Create vault',
                    onTap: _busy ? null : _submit,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'This master password is the only way to recover your vault if every '
                    'device is lost. Write it down somewhere safe.',
                    style: TextStyle(color: KavachColors.textSecondary, fontSize: 12),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
