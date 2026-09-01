import 'package:flutter/material.dart';

/// Kavach's color tokens. A single source of truth so every screen —
/// native apps and the browser-extension popup alike — pulls from the same
/// palette instead of hardcoding NeoPop colors per screen (plan §8).
///
/// Matches CRED's own light, white-background NeoPop styling: black CTA
/// buttons, hairline-bordered white cards/circles, muted-gray captions, and
/// a mint-green accent reserved for highlights (generated passwords,
/// toggles, success states) rather than everyday buttons.
class KavachColors {
  const KavachColors._();

  static const Color background = Color(0xFFFFFFFF);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color primary = Color(0xFF0A0A0A);
  static const Color primaryPressed = Color(0xFF000000);
  static const Color accent = Color(0xFF00D68F);
  static const Color danger = Color(0xFFE5484D);
  static const Color textPrimary = Color(0xFF0F1115);
  static const Color textSecondary = Color(0xFF8A8F98);
  static const Color border = Color(0xFFE3E5E8);
}
