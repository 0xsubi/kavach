import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:neopop_theme/neopop_theme.dart';

import '../state/vault_controller.dart';

/// Shown while this device has registered against a vault's GitHub repo
/// (via [JoinVaultScreen]) but hasn't been approved by another device yet
/// (plan §5). No polling loop — the user taps "Check now" once an
/// approver has actually approved them, keeping this consistent with the
/// rest of the app's manual/on-demand sync model.
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
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.hourglass_top_outlined, color: KavachColors.primary, size: 48),
                  const SizedBox(height: 16),
                  const Text(
                    'waiting for approval',
                    style: TextStyle(
                      color: KavachColors.textPrimary,
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'open kavach on one of your other, already-unlocked devices, go to '
                    'settings → devices, and approve this device.',
                    style: TextStyle(color: KavachColors.textSecondary, fontSize: 14),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  KavachButton(
                    label: _checking ? 'checking…' : 'check now',
                    onTap: _checking ? null : _checkNow,
                  ),
                  if (_notYetApproved) ...[
                    const SizedBox(height: 16),
                    const Text(
                      'not approved yet.',
                      style: TextStyle(color: KavachColors.textSecondary, fontSize: 13),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
