import 'package:flutter/material.dart';

import 'kavach_colors.dart';

/// An uppercase, letter-spaced, muted-gray caption, matching CRED's section
/// headers ("FOR YOU", "MONEY MATTERS") and field captions (plan §8).
class KavachSectionLabel extends StatelessWidget {
  const KavachSectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: const TextStyle(
        color: KavachColors.textSecondary,
        fontSize: 12,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.6,
      ),
    );
  }
}
