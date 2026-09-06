import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kavach_core/kavach_core.dart';
import 'package:neopop_theme/neopop_theme.dart';

import '../state/vault_controller.dart';

/// Registers this device against an existing vault and waits for an
/// already-approved device to approve it (plan §5 "new device
/// onboarding"). No master password is entered here — only the approving
/// device needs one, to unlock and re-wrap the vault key.
class JoinVaultScreen extends ConsumerStatefulWidget {
  const JoinVaultScreen({super.key, this.initialInvite});

  /// Pre-fills the form when the user got here by scanning the inviting
  /// device's QR code (see [DeviceInviteUri]) rather than by typing.
  final DeviceInviteUri? initialInvite;

  @override
  ConsumerState<JoinVaultScreen> createState() => _JoinVaultScreenState();
}

class _JoinVaultScreenState extends ConsumerState<JoinVaultScreen> {
  late final TextEditingController _baseUrl;
  late final TextEditingController _vaultId;
  late final TextEditingController _inviteToken;
  late bool _prefilled;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final invite = widget.initialInvite;
    _baseUrl = TextEditingController(text: invite?.baseUrl ?? '');
    _vaultId = TextEditingController(text: invite?.vaultId ?? '');
    _inviteToken = TextEditingController(text: invite?.inviteToken ?? '');
    _prefilled = invite != null;
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _vaultId.dispose();
    _inviteToken.dispose();
    super.dispose();
  }

  /// Fallback for devices that can't scan — and the only option in the
  /// browser extension, which has no camera. Accepts the same
  /// `kavach://join?…` link the invite dialog's "copy link" button emits.
  Future<void> _pasteInviteLink() async {
    final messenger = ScaffoldMessenger.of(context);
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final invite = DeviceInviteUri.tryParseString(data?.text ?? '');
    if (invite == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('clipboard has no kavach invite link')),
      );
      return;
    }
    setState(() {
      _baseUrl.text = invite.baseUrl;
      _vaultId.text = invite.vaultId;
      _inviteToken.text = invite.inviteToken;
      _prefilled = true;
    });
  }

  Future<void> _submit() async {
    if (_baseUrl.text.trim().isEmpty || _vaultId.text.trim().isEmpty || _inviteToken.text.trim().isEmpty) {
      return;
    }
    setState(() => _busy = true);
    final notifier = ref.read(vaultControllerProvider.notifier);
    await notifier.joinExistingVault(
      baseUrl: _baseUrl.text.trim(),
      vaultId: _vaultId.text.trim(),
      inviteToken: _inviteToken.text.trim(),
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
        actions: [
          IconButton(
            icon: const Icon(Icons.content_paste_outlined),
            tooltip: 'paste invite link',
            onPressed: _pasteInviteLink,
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _prefilled
                    ? 'these came from the invite you scanned. check the server url '
                        'looks right before continuing — the inviting device still '
                        'has to approve this one afterwards.'
                    : 'get an invite from a device that already has access — open its '
                        'devices screen and tap "invite a device". scan the QR it '
                        'shows, or enter the values below by hand.',
                style: const TextStyle(color: KavachColors.textSecondary, fontSize: 13),
              ),
              const SizedBox(height: 24),
              KavachCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _field('server url', _baseUrl, hint: 'e.g. https://kavach-storage.example.com'),
                    const SizedBox(height: 16),
                    _field('vault id', _vaultId, hint: 'shown on the inviting device'),
                    const SizedBox(height: 16),
                    _field('invite token', _inviteToken, hint: 'one-time, expires in 15 minutes', obscure: true),
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
