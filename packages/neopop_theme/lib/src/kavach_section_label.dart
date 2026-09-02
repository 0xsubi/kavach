import 'package:flutter/material.dart';

import 'kavach_colors.dart';

/// A letter-spaced, muted-gray caption, matching CRED's section headers and
/// field captions (plan §8). Renders whatever case [text] is passed in —
/// Kavach's UI copy is all lower case (plan §10 design note), so callers
/// should pass lower-case text rather than relying on this widget to
/// transform it.
class KavachSectionLabel extends StatelessWidget {
  const KavachSectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: KavachColors.textSecondary,
        fontSize: 12,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.6,
      ),
    );
  }
}
