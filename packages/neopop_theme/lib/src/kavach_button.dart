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
    this.enabled = true,
    this.icon,
  });

  final String label;
  final VoidCallback? onTap;
  final Color color;
  final Color parentColor;
  final bool enabled;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return NeoPopButton(
      color: color,
      parentColor: parentColor,
      enabled: enabled && onTap != null,
      onTapUp: onTap,
      buttonPosition: Position.fullBottom,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 18, color: KavachColors.background),
              const SizedBox(width: 8),
            ],
            Text(
              label,
              style: const TextStyle(
                color: KavachColors.background,
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
