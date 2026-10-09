import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../config/app_theme.dart' as tokens;
import '../theme/app_theme.dart';

/// The course like/favourite heart. One SVG for both states — only the tint
/// changes: orange when liked, the secondary text grey when not. [color]
/// overrides both, for places with their own tint (the ♥ filter tab).
class LikeIcon extends StatelessWidget {
  const LikeIcon({super.key, required this.liked, this.size = 24, this.color});

  final bool liked;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final color = this.color ??
        (liked
            ? AppColors.heartActive
            : tokens.AppThemeTokens.secondaryTextColor);
    return SvgPicture.asset(
      'assets/icons/like.svg',
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
    );
  }
}
