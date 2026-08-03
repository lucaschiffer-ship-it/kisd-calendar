import 'dart:ui';

import 'package:flutter/material.dart';

import '../config/app_theme.dart' as tokens;
import '../services/page_actions.dart';
import '../services/theme_service.dart';
import '../theme/tokens.dart';

/// The shared glass header surface for pager pages.
///
/// Lives inside each page (so header content keeps its page-local state), but
/// counter-translates against the pager slot's offset so it stays pinned on
/// screen while the page bodies slide. During a page switch the surface height
/// interpolates between the outgoing and incoming page's current heights, and
/// the content does a staggered cross-fade: outgoing content is gone by the
/// halfway point, incoming content appears after it — at the midpoint only the
/// bare glass surface is visible.
///
/// Exactly one page (the one nearest the pager position) paints its surface at
/// any time; the neighbour's content opacity is provably 0 at the handoff
/// point, and both surfaces are pixel-identical there, so the swap is
/// invisible. HomeScreen paints the owner's slot last so this surface blurs
/// both sliding bodies.
///
/// The element structure never changes between owner/non-owner or rest/
/// transition — only [Offstage.offstage] and plain values vary — so content
/// state (text fields, scroll positions, GlobalKeys) survives transitions.
class MorphingGlassHeader extends StatelessWidget {
  const MorphingGlassHeader({
    super.key,
    required this.handle,
    required this.height,
    required this.child,
  });

  final PageHeaderHandle handle;

  /// The page's current header height, computed live by the page. Content is
  /// laid out at its natural height and clipped at the morphing surface
  /// height.
  final double height;

  /// Header content only — no background, no blur.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Plain write, never notifies — safe during build.
    handle.reportHeight(height);
    return ValueListenableBuilder<double>(
      valueListenable: handle.controller.pagePos,
      builder: (context, pos, _) {
        final n = handle.controller.pageCount;
        // Signed shortest circular distance, matching the pager's slot math.
        var d = (handle.index - pos) % n;
        if (d > n / 2) d -= n;
        final owner = handle.index == pos.round() % n;
        // Staggered cross-fade: gone by |d| = 0.5, so at most one page's
        // content is ever visible (adjacent |d| values sum to 1).
        final opacity = (1 - 2 * d.abs()).clamp(0.0, 1.0).toDouble();

        double surfaceH;
        if (d == 0) {
          surfaceH = height;
        } else {
          // Lerp between the two pages the position currently sits between;
          // floor/ceil mod n handles the circular wrap seam.
          final heights = handle.controller.heights;
          final iA = pos.floor() % n;
          final iB = (iA + 1) % n;
          surfaceH = lerpDouble(heights[iA], heights[iB], pos - pos.floorToDouble())!;
        }

        final glass = ThemeService.instance.glassEnabled.value;
        final borderColor = ThemeService.instance.currentColor.value == 'dark'
            ? const Color(0x1AFFFFFF)
            : tokens.AppThemeTokens.cardBorder;

        final surface = Container(
          decoration: BoxDecoration(
            color: glass
                ? AppColorScheme.current.glassHeaderTint
                : tokens.AppThemeTokens.backgroundColor,
            border: Border(bottom: BorderSide(color: borderColor, width: 0.5)),
          ),
          child: SizedBox(
            height: surfaceH,
            width: double.infinity,
            child: Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                // No height: content keeps its natural height, top-aligned,
                // clipped at surfaceH while the surface morphs.
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: Opacity(opacity: opacity, child: child),
                ),
              ],
            ),
          ),
        );

        // ClipRect sits inside the Transform so the blur samples the pinned
        // screen rect, not the sliding slot rect.
        final body = glass
            ? ClipRect(
                child: BackdropFilter(
                  filter: ImageFilter.blur(
                    sigmaX: AppGlass.headerBlur,
                    sigmaY: AppGlass.headerBlur,
                  ),
                  child: surface,
                ),
              )
            : surface;

        return Offstage(
          offstage: !owner,
          child: Transform.translate(
            offset: Offset(-d * MediaQuery.sizeOf(context).width, 0),
            child: body,
          ),
        );
      },
    );
  }
}
