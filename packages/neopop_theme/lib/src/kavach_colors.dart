import 'package:flutter/material.dart';

/// Kavach's color tokens. A single source of truth so every screen —
/// native apps and the browser-extension popup alike — pulls from the same
/// palette instead of hardcoding NeoPop colors per screen (plan §8).
class KavachColors {
  const KavachColors._();

  static const Color background = Color(0xFF0B0D10);
  static const Color surface = Color(0xFF14171C);
  static const Color primary = Color(0xFF5AF0A0);
  static const Color primaryPressed = Color(0xFF3FCB84);
  static const Color danger = Color(0xFFFF5C5C);
  static const Color textPrimary = Color(0xFFF4F6F8);
  static const Color textSecondary = Color(0xFF9AA3AD);
  static const Color border = Color(0xFF2A2E35);
}
