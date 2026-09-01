import 'package:flutter/material.dart';

import 'kavach_colors.dart';

/// A hairline-bordered circular icon button, matching CRED's "For you" /
/// "Money matters" icon-grid pattern (plan §8): a white circle with a thin
/// gray border around a dark line icon, with an optional small black pill
/// badge (like CRED's "EXPLORE" tag) overlapping the bottom edge.
class KavachIconCircle extends StatelessWidget {
  const KavachIconCircle({
    super.key,
    required this.icon,
    this.onTap,
    this.size = 56,
    this.iconSize = 22,
    this.badgeLabel,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final double size;
  final double iconSize;
  final String? badgeLabel;

  @override
  Widget build(BuildContext context) {
    final circle = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: KavachColors.surface,
        border: Border.all(color: KavachColors.border),
      ),
      child: Icon(icon, size: iconSize, color: KavachColors.textPrimary),
    );

    final badge = badgeLabel;
    final content = badge == null
        ? circle
        : Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              circle,
              Positioned(
                bottom: -6,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: KavachColors.primary,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    badge.toUpperCase(),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                    ),
                  ),
                ),
              ),
            ],
          );

    if (onTap == null) return content;
    return GestureDetector(
      onTap: onTap,
      child: content,
    );
  }
}
