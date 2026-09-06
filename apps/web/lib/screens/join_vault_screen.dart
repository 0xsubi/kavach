import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kavach_core/kavach_core.dart';
import 'package:neopop_theme/neopop_theme.dart';

import '../state/vault_controller.dart';

class JoinVaultScreen extends ConsumerStatefulWidget {
  const JoinVaultScreen({super.key, this.initialInvite});

  /// Pre-fills the form when the browser landed here via a
  /// `/join?v=1&url=…` link — the web equivalent of the native apps'
  /// `kavach://join` deep link, opened by scanning the inviting device's
  /// QR code with a phone camera that then hands off to this tab. See
  /// [DeviceInviteUri.tryParseQueryParameters].
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

  /// The extension has no camera, so pasting the `kavach://join?…` link
  /// that the inviting device's "copy link" button emits is the stand-in
  /// for scanning its QR code.
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
    if (_baseUrl.text.trim().isEmpty || _vaultId.text.trim().isEmpty || _inviteToken.text.trim().isEmpty) return;
    setState(() => _busy = true);
    final notifier = ref.read(vaultControllerProvider.notifier);
    await notifier.joinExistingVault(
      baseUrl: _baseUrl.text.trim(),
      vaultId: _vaultId.text.trim(),
      inviteToken: _inviteToken.text.trim(),
    );
    if (!mounted) return;
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
        title: const Text('join a vault', style: TextStyle(color: KavachColors.textPrimary, fontSize: 16)),
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
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _prefilled
                    ? 'these came from the invite link you opened. check the server '
                        'url looks right before continuing — the inviting device still '
                        'has to approve this one afterwards.'
                    : 'get an invite from a device that already has access (its devices '
                        'screen → "invite a device"). tap "copy link" there and paste it '
                        'with the button above, or enter the values by hand.',
                style: const TextStyle(color: KavachColors.textSecondary, fontSize: 12),
              ),
              const SizedBox(height: 16),
              KavachCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _field('server url', _baseUrl, hint: 'e.g. https://kavach-storage.example.com'),
                    const SizedBox(height: 10),
                    _field('vault id', _vaultId, hint: 'shown on the inviting device'),
                    const SizedBox(height: 10),
                    _field('invite token', _inviteToken, hint: 'one-time, expires in 15 minutes', obscure: true),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              KavachButton(label: _busy ? 'requesting…' : 'request to join', onTap: _busy ? null : _submit),
              if (error != null) ...[
                const SizedBox(height: 12),
                Text(error, style: const TextStyle(color: KavachColors.danger, fontSize: 12)),
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
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          obscureText: obscure,
          style: const TextStyle(color: KavachColors.textPrimary),
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            isDense: true,
            hintText: hint,
            hintStyle: const TextStyle(color: KavachColors.textSecondary),
          ),
        ),
      ],
    );
  }
}
