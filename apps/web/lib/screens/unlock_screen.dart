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
  String? _error;
  bool _busy = false;
  bool _triedQuickUnlock = false;

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
    await ref.read(vaultControllerProvider.notifier).tryQuickUnlock();
    if (mounted) setState(() { _busy = false; _triedQuickUnlock = true; });
  }

  Future<void> _submitMasterPassword() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await ref.read(vaultControllerProvider.notifier).unlockWithMasterPassword(_masterPasswordController.text);
    if (mounted) {
      setState(() {
        _busy = false;
        if (!ok) _error = 'incorrect master password.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_triedQuickUnlock) {
      return const Scaffold(
        backgroundColor: KavachColors.background,
        body: Center(child: CircularProgressIndicator(color: KavachColors.accent)),
      );
    }
    return Scaffold(
      backgroundColor: KavachColors.background,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.lock_outline, color: KavachColors.primary, size: 36),
              const SizedBox(height: 8),
              const Text(
                'vault locked',
                style: TextStyle(color: KavachColors.textPrimary, fontSize: 18, fontWeight: FontWeight.w700),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              KavachCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const KavachSectionLabel('master password'),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _masterPasswordController,
                      obscureText: true,
                      autofocus: true,
                      style: const TextStyle(color: KavachColors.textPrimary),
                      decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
                      onSubmitted: (_) => _submitMasterPassword(),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 8),
                      Text(_error!, style: const TextStyle(color: KavachColors.danger, fontSize: 12)),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
              KavachButton(label: _busy ? 'unlocking…' : 'unlock', onTap: _busy ? null : _submitMasterPassword),
            ],
          ),
        ),
      ),
    );
  }
}
