import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kavach_core/kavach_core.dart';
import 'package:neopop_theme/neopop_theme.dart';

class GeneratorScreen extends StatefulWidget {
  const GeneratorScreen({super.key, this.selectMode = false});

  /// When true, "Use this password" pops the screen with the generated
  /// value instead of just copying it — used when opened from the item
  /// editor's generator shortcut.
  final bool selectMode;

  @override
  State<GeneratorScreen> createState() => _GeneratorScreenState();
}

class _GeneratorScreenState extends State<GeneratorScreen> {
  static const _generator = PasswordGenerator();

  double _length = 20;
  bool _uppercase = true;
  bool _lowercase = true;
  bool _digits = true;
  bool _symbols = true;
  bool _excludeAmbiguous = false;
  late String _password;

  @override
  void initState() {
    super.initState();
    _regenerate();
  }

  PasswordPolicy get _policy => PasswordPolicy(
        length: _length.round(),
        useUppercase: _uppercase,
        useLowercase: _lowercase,
        useDigits: _digits,
        useSymbols: _symbols,
        excludeAmbiguous: _excludeAmbiguous,
      );

  void _regenerate() {
    setState(() {
      try {
        _password = _generator.generatePassword(_policy);
      } on ArgumentError {
        _password = '';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final entropy = PasswordGenerator.estimateEntropyBits(_policy);
    return Scaffold(
      backgroundColor: KavachColors.background,
      appBar: AppBar(
        backgroundColor: KavachColors.background,
        title: const Text('Generator', style: TextStyle(color: KavachColors.textPrimary)),
        iconTheme: const IconThemeData(color: KavachColors.textPrimary),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              KavachCard(
                child: SelectableText(
                  _password.isEmpty ? '—' : _password,
                  style: const TextStyle(
                    color: KavachColors.accent,
                    fontSize: 22,
                    fontFamily: KavachFonts.mono,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${entropy.round()} bits of entropy',
                style: const TextStyle(color: KavachColors.textSecondary, fontSize: 12),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  const Text('Length', style: TextStyle(color: KavachColors.textPrimary)),
                  Expanded(
                    child: Slider(
                      value: _length,
                      min: 8,
                      max: 64,
                      divisions: 56,
                      activeColor: KavachColors.accent,
                      label: _length.round().toString(),
                      onChanged: (v) {
                        setState(() => _length = v);
                        _regenerate();
                      },
                    ),
                  ),
                  SizedBox(
                    width: 32,
                    child: Text(
                      _length.round().toString(),
                      style: const TextStyle(color: KavachColors.textPrimary),
                    ),
                  ),
                ],
              ),
              _togglRow('Uppercase (A-Z)', _uppercase, (v) {
                setState(() => _uppercase = v);
                _regenerate();
              }),
              _togglRow('Lowercase (a-z)', _lowercase, (v) {
                setState(() => _lowercase = v);
                _regenerate();
              }),
              _togglRow('Digits (0-9)', _digits, (v) {
                setState(() => _digits = v);
                _regenerate();
              }),
              _togglRow('Symbols (!@#\$…)', _symbols, (v) {
                setState(() => _symbols = v);
                _regenerate();
              }),
              _togglRow('Exclude ambiguous (0 O l 1 I)', _excludeAmbiguous, (v) {
                setState(() => _excludeAmbiguous = v);
                _regenerate();
              }),
              const SizedBox(height: 24),
              KavachButton(
                label: 'Regenerate',
                icon: Icons.refresh,
                onTap: _regenerate,
                color: KavachColors.surface,
                textColor: KavachColors.textPrimary,
                outlined: true,
              ),
              const SizedBox(height: 12),
              KavachButton(
                label: 'Copy to clipboard',
                icon: Icons.copy_outlined,
                onTap: _password.isEmpty
                    ? null
                    : () {
                        Clipboard.setData(ClipboardData(text: _password));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Copied to clipboard')),
                        );
                      },
              ),
              if (widget.selectMode) ...[
                const SizedBox(height: 12),
                KavachButton(
                  label: 'Use this password',
                  onTap: _password.isEmpty ? null : () => Navigator.of(context).pop(_password),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _togglRow(String label, bool value, ValueChanged<bool> onChanged) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      activeThumbColor: KavachColors.accent,
      title: Text(label, style: const TextStyle(color: KavachColors.textPrimary)),
      value: value,
      onChanged: onChanged,
    );
  }
}
