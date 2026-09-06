import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neopop_theme/neopop_theme.dart';

import '../state/vault_controller.dart';
import 'join_vault_screen.dart';

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
      setState(() => _error = 'master password must be at least 8 characters.');
      return;
    }
    if (password != _confirmController.text) {
      setState(() => _error = 'passwords do not match.');
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
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'kavach',
                style: TextStyle(color: KavachColors.primary, fontSize: 28, fontWeight: FontWeight.w700),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              const Text(
                'create your vault',
                style: TextStyle(color: KavachColors.textSecondary, fontSize: 13),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              KavachCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const KavachSectionLabel('master password'),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _passwordController,
                      obscureText: true,
                      style: const TextStyle(color: KavachColors.textPrimary),
                      decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
                    ),
                    const SizedBox(height: 12),
                    const KavachSectionLabel('confirm password'),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _confirmController,
                      obscureText: true,
                      style: const TextStyle(color: KavachColors.textPrimary),
                      decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
                      onSubmitted: (_) => _submit(),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 8),
                      Text(_error!, style: const TextStyle(color: KavachColors.danger, fontSize: 12)),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
              KavachButton(label: _busy ? 'creating…' : 'create vault', onTap: _busy ? null : _submit),
              const SizedBox(height: 12),
              Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const JoinVaultScreen()),
                  ),
                  child: const Text(
                    "already have a vault? join with another device's approval",
                    style: TextStyle(color: KavachColors.accent, fontSize: 12),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
