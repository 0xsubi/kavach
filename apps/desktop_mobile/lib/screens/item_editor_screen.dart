import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kavach_core/kavach_core.dart';
import 'package:neopop_theme/neopop_theme.dart';

import '../state/vault_controller.dart';
import 'generator_screen.dart';

class ItemEditorScreen extends ConsumerStatefulWidget {
  const ItemEditorScreen({super.key, this.existing});

  final VaultItem? existing;

  @override
  ConsumerState<ItemEditorScreen> createState() => _ItemEditorScreenState();
}

class _ItemEditorScreenState extends ConsumerState<ItemEditorScreen> {
  late final TextEditingController _name;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _uri;
  late final TextEditingController _notes;
  bool _obscure = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final data = widget.existing?.data;
    final password = data is PasswordItemData ? data : null;
    _name = TextEditingController(text: password?.name ?? '');
    _username = TextEditingController(text: password?.username ?? '');
    _password = TextEditingController(text: password?.password ?? '');
    _uri = TextEditingController(text: password?.uris.isNotEmpty == true ? password!.uris.first : '');
    _notes = TextEditingController(text: password?.notes ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _username.dispose();
    _password.dispose();
    _uri.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) return;
    setState(() => _busy = true);
    await ref.read(vaultControllerProvider.notifier).savePasswordItem(
          id: widget.existing?.id,
          name: _name.text.trim(),
          username: _username.text.trim(),
          password: _password.text,
          uris: _uri.text.trim().isEmpty ? const [] : [_uri.text.trim()],
          notes: _notes.text,
        );
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final existing = widget.existing;
    if (existing == null) return;
    await ref.read(vaultControllerProvider.notifier).deleteItem(existing);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _openGenerator() async {
    final generated = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const GeneratorScreen(selectMode: true)),
    );
    if (generated != null) {
      _password.text = generated;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.existing != null;
    return Scaffold(
      backgroundColor: KavachColors.background,
      appBar: AppBar(
        backgroundColor: KavachColors.background,
        iconTheme: const IconThemeData(color: KavachColors.textPrimary),
        title: Text(
          isEditing ? 'Edit item' : 'New item',
          style: const TextStyle(color: KavachColors.textPrimary),
        ),
        actions: [
          if (isEditing)
            IconButton(
              icon: const Icon(Icons.delete_outline, color: KavachColors.danger),
              onPressed: _delete,
            ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              KavachCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _field('Name', _name),
                    const SizedBox(height: 16),
                    _field('Username / email', _username),
                    const SizedBox(height: 16),
                    _label('Password'),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _password,
                      obscureText: _obscure,
                      style: const TextStyle(color: KavachColors.textPrimary, fontFamily: KavachFonts.mono),
                      decoration: InputDecoration(
                        border: const OutlineInputBorder(),
                        suffixIcon: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: Icon(
                                _obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                                color: KavachColors.textSecondary,
                              ),
                              onPressed: () => setState(() => _obscure = !_obscure),
                            ),
                            IconButton(
                              icon: const Icon(Icons.copy_outlined, color: KavachColors.textSecondary),
                              onPressed: () {
                                Clipboard.setData(ClipboardData(text: _password.text));
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Copied to clipboard')),
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: _openGenerator,
                        icon: const Icon(Icons.casino_outlined, size: 18, color: KavachColors.accent),
                        label: const Text('Generate', style: TextStyle(color: KavachColors.accent)),
                      ),
                    ),
                    const SizedBox(height: 8),
                    _field('Website / URI', _uri),
                    const SizedBox(height: 16),
                    _label('Notes'),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _notes,
                      maxLines: 3,
                      style: const TextStyle(color: KavachColors.textPrimary),
                      decoration: const InputDecoration(border: OutlineInputBorder()),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              KavachButton(
                label: _busy ? 'Saving…' : 'Save',
                onTap: _busy ? null : _save,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _label(String text) => KavachSectionLabel(text);

  Widget _field(String label, TextEditingController controller) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _label(label),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          style: const TextStyle(color: KavachColors.textPrimary),
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
      ],
    );
  }
}
