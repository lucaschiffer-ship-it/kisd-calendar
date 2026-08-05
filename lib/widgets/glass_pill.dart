import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../services/theme_service.dart';
import '../theme/tokens.dart';

/// A floating capsule that uses the same material as [MorphingGlassHeader], so
/// the bottom cluster, the page headers and the page-specific floating buttons
/// all read as one system.
///
/// Deliberately not `AppThemeTokens.glassContainer`: that helper's defaults are
/// the *card* material (blur 20, white @ 12 %), and it only ever draws a
/// bottom-less border. A floating pill needs the header's blur and tint plus a
/// border on all four sides.
class GlassPill extends StatelessWidget {
  const GlassPill({super.key, this.radius, required this.child});

  /// Corner radius. Defaults to the bottom cluster's shape, which follows the
  /// "Rounded bars" setting — pass a value only to opt out of that.
  final double? radius;
  final Widget child;

  /// The shape every surface in the bottom cluster shares.
  static double defaultRadius() =>
      ThemeService.instance.roundedBars.value ? AppRadius.pill : AppRadius.chip;

  // Self-listening: call sites are scattered across pages that each subscribe
  // to a different subset of the theme notifiers, so the pill subscribes to all
  // three it reads rather than relying on an ancestor to rebuild it.
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        ThemeService.instance.currentColor,
        ThemeService.instance.glassEnabled,
        ThemeService.instance.roundedBars,
      ]),
      builder: (context, _) => _buildSurface(),
    );
  }

  Widget _buildSurface() {
    final s = AppColorScheme.current;
    final glass = ThemeService.instance.glassEnabled.value;
    final br = BorderRadius.circular(radius ?? defaultRadius());
    final borderColor = ThemeService.instance.currentColor.value == 'dark'
        ? AppGlass.dividerColor
        : s.cardBorder;

    final surface = Container(
      decoration: BoxDecoration(
        // Off-glass this needs to be a raised surface, not navBarBg: the old
        // full-width bar could sit at pure black because a top divider split it
        // from the content, but a floating pill on a black page would vanish.
        color: glass ? s.glassHeaderTint : s.surface,
        borderRadius: br,
        border: Border.all(color: borderColor, width: 0.5),
      ),
      child: child,
    );

    if (!glass) {
      // Lifts the pill off the page in light mode; in dark the hairline border
      // does that work, since a black shadow on black reads as nothing.
      return DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: br,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.3),
              blurRadius: 12,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: surface,
      );
    }

    return ClipRRect(
      borderRadius: br,
      child: BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: AppGlass.headerBlur,
          sigmaY: AppGlass.headerBlur,
        ),
        child: surface,
      ),
    );
  }
}
