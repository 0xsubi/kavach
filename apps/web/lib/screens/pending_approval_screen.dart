import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neopop_theme/neopop_theme.dart';

import '../state/vault_controller.dart';

class PendingApprovalScreen extends ConsumerStatefulWidget {
  const PendingApprovalScreen({super.key});

  @override
  ConsumerState<PendingApprovalScreen> createState() => _PendingApprovalScreenState();
}

class _PendingApprovalScreenState extends ConsumerState<PendingApprovalScreen> {
  bool _checking = false;
  bool _notYetApproved = false;

  Future<void> _checkNow() async {
    setState(() {
      _checking = true;
      _notYetApproved = false;
    });
    final approved = await ref.read(vaultControllerProvider.notifier).checkJoinApproval();
    if (mounted) {
      setState(() {
        _checking = false;
        _notYetApproved = !approved;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KavachColors.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.hourglass_top_outlined, color: KavachColors.primary, size: 40),
                const SizedBox(height: 12),
                const Text(
                  'waiting for approval',
                  style: TextStyle(color: KavachColors.textPrimary, fontSize: 18, fontWeight: FontWeight.w700),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                const Text(
                  'open kavach on one of your other, already-unlocked devices and approve this device.',
                  style: TextStyle(color: KavachColors.textSecondary, fontSize: 12),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                KavachButton(label: _checking ? 'checking…' : 'check now', onTap: _checking ? null : _checkNow),
                if (_notYetApproved) ...[
                  const SizedBox(height: 12),
                  const Text(
                    'not approved yet.',
                    style: TextStyle(color: KavachColors.textSecondary, fontSize: 12),
                    textAlign: TextAlign.center,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
