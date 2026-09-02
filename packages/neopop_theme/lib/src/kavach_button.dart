import 'package:flutter/material.dart';
import 'package:neopop/neopop.dart';

import 'kavach_colors.dart';

/// Kavach's standard pressable button: a thin wrapper over [NeoPopButton]
/// with Kavach's color tokens and typography, used across the unlock
/// screen, vault list actions, generator regenerate/copy, and device
/// approval controls (plan §8).
class KavachButton extends StatelessWidget {
  const KavachButton({
    super.key,
    required this.label,
    required this.onTap,
    this.color = KavachColors.primary,
    this.parentColor = KavachColors.background,
    this.textColor = Colors.white,
    this.enabled = true,
    this.icon,
    this.outlined = false,
  });

  final String label;
  final VoidCallback? onTap;
  final Color color;
  final Color parentColor;

  /// Defaults to white, matching the default black CTA fill. Pass
  /// [KavachColors.textPrimary] when using a light [color] (e.g. a
  /// secondary/surface-colored button) so the label stays legible.
  final Color textColor;
  final bool enabled;
  final IconData? icon;

  /// Adds a hairline [KavachColors.border] outline, matching CRED's white
  /// secondary/pill buttons. Set this when [color] is light (e.g.
  /// [KavachColors.surface]) so the button doesn't disappear against a
  /// white background.
  final bool outlined;

  @override
  Widget build(BuildContext context) {
    return NeoPopButton(
      color: color,
      parentColor: parentColor,
      enabled: enabled && onTap != null,
      onTapUp: onTap,
      buttonPosition: Position.fullBottom,
      border: outlined ? Border.all(color: KavachColors.border) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 18, color: textColor),
              const SizedBox(width: 8),
            ],
            Text(
              label,
              style: TextStyle(
                color: textColor,
                fontWeight: FontWeight.w700,
                fontSize: 16,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
