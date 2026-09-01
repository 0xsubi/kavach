import 'package:flutter/material.dart';
import 'package:neopop/neopop.dart';

import 'kavach_colors.dart';

/// Kavach's standard content card: a thin wrapper over [NeoPopCard] used for
/// vault item rows and the item-detail sheet (plan §8).
class KavachCard extends StatelessWidget {
  const KavachCard({
    super.key,
    required this.child,
    this.color = KavachColors.surface,
    this.padding = const EdgeInsets.all(16),
  });

  final Widget child;
  final Color color;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return NeoPopCard(
      color: color,
      borderColor: KavachColors.border,
      child: Padding(padding: padding, child: child),
    );
  }
}
